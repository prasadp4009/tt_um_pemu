// emu_loader.v -- FPGA host-loader for the TEMPO-32 (tt_um_pemu) emulation.
//
// Bit-bangs the chip's 2-wire host port EXACTLY like test/tb_top.v (the
// golden reference):
//   Phase A (fpga/halt_test.hex, 1 word): reset -> 0x00 sync -> LOAD_IMEM ->
//     GO -> RD_STATUS=0x90 -> HALT_REQ -> RD_STATUS=0x50 -> GO -> RD_STATUS=0x90
//   Phase B (fpga/top_smoke.hex, 33 words): reset -> 0x00 sync ->
//     LOAD_IMEM(33) -> VERIFY_IMEM(33, byte-compared) -> 0x00 resync -> GO ->
//     WR_RXFIFO{1,1,1,3,1,2,3} -> poll RD_STATUS until 0x40 (recording the
//     uio_out pin history meanwhile) -> pinseq 01,02,03 check ->
//     RD_STATUS=0x40 -> RD_TXFIFO (count=6, words {1,2,3})
//
// UART: 10-bit frames (start + 8b LSB-first + stop), T=100 core clocks/bit
// on hp_rx (= DUT ui_in[0]), idle high, edges on posedge boundaries so the
// chip's autobaud measures exactly 9*T on the 0x00 sync byte. The first byte
// after reset (or after >65535 idle clocks, i.e. after VERIFY's 133-byte
// reply) is 0x00, consumed by the chip as the autobaud sync (NOP).
// Responses on hp_tx (= DUT uo_out[0]) are sampled at 1.5T, 2.5T, ... after
// the falling edge, mirroring tb_top's always-on rx monitor.
//
// Milestones (fine-grained, one bit per checkpoint) and a fail code are
// reported to the VIO. inject_fault (latched at run start) flips the final
// RD_STATUS expectation 0x40 -> 0x41 for the vacuity (negative-control) run.
//
// FPGA-EMULATION-ONLY. Not for ASIC synthesis.
//
// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module emu_loader (
    input  wire        clk,          // test clock (VIO-selected frequency)
    input  wire        rst_n,        // async-assert, sync-deassert, active low
    // DUT host port
    output reg         hp_rx,        // -> DUT ui_in[0], idle high
    input  wire        hp_tx,        // <- DUT uo_out[0]
    input  wire [7:0]  uio_out,      // <- DUT uio_out (pin-history sampler)
    output wire        phase_reset,  // DUT reset during A_RST / B_RST
    // control (already synchronized into clk domain by emu_top)
    input  wire        start_test,   // level; rising edge starts a run
    input  wire        inject_fault, // latched at run start; flips one expectation
    // results
    output reg  [15:0] milestones,
    output reg  [7:0]  fail_code,
    output reg         phaseA_pass,
    output reg         phaseB_pass,
    output reg         done,
    output reg  [31:0] signature,
    output wire [7:0]  st,           // FSM state (ILA)
    output wire        tx_busy_o,
    output wire        rx_valid_o
);

    localparam T = 100;  // UART bit period in core clocks

    // ---------------- program images (ROM) ----------------
    reg [31:0] imgA [0:0];
    reg [31:0] imgB [0:32];
    reg [15:0] wr_rom [0:7];
    initial begin
        $readmemh("halt_test.hex", imgA);
        $readmemh("top_smoke.hex", imgB);
        wr_rom[0] = 16'd1; wr_rom[1] = 16'd1; wr_rom[2] = 16'd1; wr_rom[3] = 16'd3;
        wr_rom[4] = 16'd1; wr_rom[5] = 16'd2; wr_rom[6] = 16'd3; wr_rom[7] = 16'd0;
    end

    // ---------------- FSM states ----------------
    localparam [7:0]
        S_IDLE       = 8'h00,
        A_RST        = 8'h01, A_RSTREL = 8'h02,
        A_TX_SYNC    = 8'h03, A_TX_LDHDR = 8'h04, A_TX_LDDATA = 8'h05,
        A_RX_LDAK    = 8'h06,
        A_TX_GO1     = 8'h07, A_RX_GOAK1 = 8'h08, A_WAIT200 = 8'h09,
        A_TX_ST1     = 8'h0A, A_RX_STAK1 = 8'h0B, A_RX_ST1 = 8'h0C,
        A_TX_HALT    = 8'h0D, A_RX_HALTAK = 8'h0E, A_WAIT50 = 8'h0F,
        A_TX_ST2     = 8'h10, A_RX_STAK2 = 8'h11, A_RX_ST2 = 8'h12,
        A_TX_GO2     = 8'h13, A_RX_GOAK2 = 8'h14, A_WAIT100 = 8'h15,
        A_TX_ST3     = 8'h16, A_RX_STAK3 = 8'h17, A_RX_ST3 = 8'h18,
        B_RST        = 8'h19, B_RSTREL = 8'h1A,
        B_TX_SYNC    = 8'h1B, B_TX_LDHDR = 8'h1C, B_TX_LDDATA = 8'h1D,
        B_RX_LDAK    = 8'h1E,
        B_TX_VFHDR   = 8'h1F, B_RX_VFAK = 8'h20, B_RX_VFDATA = 8'h21,
        B_WAIT3000   = 8'h22, B_TX_RESYNC = 8'h23, B_WAIT2000 = 8'h24,
        B_TX_GO      = 8'h25, B_RX_GOAK = 8'h26,
        B_TX_WRHDR   = 8'h27, B_TX_WRDATA = 8'h28, B_RX_WRAK = 8'h29,
        B_POLL_ST_TX = 8'h2A, B_POLL_ST_AK = 8'h2B, B_POLL_ST_RX = 8'h2C,
        B_PINCHK     = 8'h2D,
        B_TX_STF     = 8'h2E, B_RX_STF_AK = 8'h2F, B_RX_STF = 8'h30,
        B_TX_TXF     = 8'h31, B_RX_TXF_AK = 8'h32,
        B_RX_TXF_CNT = 8'h33, B_RX_TXF_DATA = 8'h34;

    // milestones
    localparam M_A_AUTOBAUD = 0,  // Phase A LOAD_IMEM ACK (sync works)
               M_A_RUN1     = 1,  // Phase A RD_STATUS 0x90
               M_A_HALT     = 2,  // Phase A RD_STATUS 0x50
               M_A_RUN2     = 3,  // Phase A restart RD_STATUS 0x90
               M_B_LOAD     = 4,  // Phase B LOAD_IMEM(33) ACK (load_ack)
               M_B_VERIFY   = 5,  // Phase B VERIFY 33 words match (verify_match)
               M_B_GO       = 6,  // Phase B GO ACK (go_ack)
               M_B_WR       = 7,  // Phase B WR_RXFIFO ACK (wr_ack)
               M_B_HALTSEEN = 8,  // Phase B RD_STATUS poll -> 0x40 (halt_seen)
               M_B_PINSEQ   = 9,  // Phase B pin history 01,02,03 in order (pinseq_ok)
               M_B_STATUS   = 10, // Phase B final RD_STATUS 0x40 (status_ok)
               M_B_TXDATA   = 11; // Phase B RD_TXFIFO count+data (txdata_ok)

    reg [7:0] st_r;
    assign st = st_r;
    assign phase_reset = (st_r == A_RST) || (st_r == B_RST);

    reg [7:0]  bcnt;        // byte counter within a transfer
    reg [7:0]  wcnt;        // word counter within a transfer
    reg [17:0] tcnt;        // wait / inter-byte timeout counter
    reg [17:0] poll_tcnt;   // halt-poll total timeout counter
    reg        fault_lat;   // inject_fault latched at run start
    reg        pin_en;

    // pin history
    reg [7:0] pin_hist [0:15];
    reg [4:0] pin_n;
    reg [7:0] pin_last;

    integer k;

    // ---------------- signature fold ----------------
    function [31:0] sig_fold(input [31:0] s, input [7:0] b);
        sig_fold = (s << 1) ^ {24'b0, b} ^ (s[31] ? 32'h04C11DB7 : 32'b0);
    endfunction

    function [31:0] fold_pins(input [31:0] s, input [4:0] n);
        integer j;
        begin
            fold_pins = s;
            for (j = 0; j < 16; j = j + 1)
                if (j < n) fold_pins = sig_fold(fold_pins, pin_hist[j]);
        end
    endfunction

    // ---------------- UART TX engine ----------------
    // 10-bit frames, exactly T clocks/bit, edges on posedge boundaries.
    reg [9:0] tx_shr;
    reg [6:0] tx_ccnt;
    reg [3:0] tx_bidx;
    reg       tx_busy;
    reg       tx_done;       // 1-cycle pulse
    reg       tx_launched;
    reg [7:0] tx_byte;
    reg       tx_start;      // 1-cycle pulse from FSM
    assign tx_busy_o = tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_shr <= 10'h3FF; tx_ccnt <= 7'd0; tx_bidx <= 4'd0;
            tx_busy <= 1'b0; tx_done <= 1'b0; tx_launched <= 1'b0;
            hp_rx <= 1'b1;
        end else begin
            tx_done <= 1'b0;
            if (tx_start && !tx_busy) begin
                tx_shr <= {1'b1, tx_byte, 1'b0};  // stop, d7..d0, start
                tx_bidx <= 4'd0; tx_ccnt <= 7'd0; tx_busy <= 1'b1;
                tx_launched <= 1'b1;
            end else if (tx_busy) begin
                if (tx_ccnt == T - 1) begin
                    tx_ccnt <= 7'd0;
                    if (tx_bidx == 4'd9) begin
                        tx_busy <= 1'b0; tx_done <= 1'b1; tx_launched <= 1'b0;
                    end else begin
                        tx_bidx <= tx_bidx + 4'd1;
                        tx_shr <= {1'b1, tx_shr[9:1]};
                    end
                end else tx_ccnt <= tx_ccnt + 7'd1;
            end
            hp_rx <= tx_busy ? tx_shr[0] : 1'b1;
        end
    end

    // ---------------- UART RX monitor ----------------
    // Always-on edge-detect + sample at 1.5T, 2.5T, ... (tb_top style).
    reg        hp_tx_d;
    reg        rx_active;
    reg [15:0] rx_ccnt;
    reg [2:0]  rx_bidx;
    reg [7:0]  rx_shr;
    reg [7:0]  rx_byte;
    reg        rx_valid;      // 1-cycle pulse
    assign rx_valid_o = rx_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hp_tx_d <= 1'b1; rx_active <= 1'b0; rx_ccnt <= 16'd0;
            rx_bidx <= 3'd0; rx_shr <= 8'd0; rx_byte <= 8'd0; rx_valid <= 1'b0;
        end else begin
            hp_tx_d <= hp_tx;
            rx_valid <= 1'b0;
            if (!rx_active) begin
                if (hp_tx_d && !hp_tx) begin  // falling edge
                    rx_active <= 1'b1; rx_ccnt <= 16'd0; rx_bidx <= 3'd0;
                end
            end else begin
                if (rx_ccnt == (rx_bidx == 3'd0 ? 16'd149 : 16'd99)) begin
                    rx_ccnt <= 16'd0;
                    rx_shr[rx_bidx] <= hp_tx;
                    if (rx_bidx == 3'd7) begin
                        rx_active <= 1'b0;
                        rx_byte <= {hp_tx, rx_shr[6:0]};
                        rx_valid <= 1'b1;
                    end else rx_bidx <= rx_bidx + 3'd1;
                end else rx_ccnt <= rx_ccnt + 16'd1;
            end
        end
    end

    // ---------------- pin-history sampler ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pin_n <= 5'd0; pin_last <= 8'h00;
            for (k = 0; k < 16; k = k + 1) pin_hist[k] <= 8'h00;
        end else if (pin_en && (uio_out != pin_last) && (pin_n < 5'd16)) begin
            pin_hist[pin_n] <= uio_out;
            pin_last <= uio_out;
            pin_n <= pin_n + 5'd1;
        end
    end

    // pin-sequence check: 0x01, then 0x02, then 0x03, in order
    reg pseq_ok;
    integer s0, s1, s2, j;
    always @(*) begin
        s0 = -1; s1 = -1; s2 = -1;
        for (j = 0; j < 16; j = j + 1) begin
            if (j < pin_n) begin
                if (s0 < 0 && pin_hist[j] == 8'h01) s0 = j;
                else if (s0 >= 0 && s1 < 0 && pin_hist[j] == 8'h02) s1 = j;
                else if (s1 >= 0 && s2 < 0 && pin_hist[j] == 8'h03) s2 = j;
            end
        end
        pseq_ok = (s0 >= 0 && s1 > s0 && s2 > s1);
    end

    // ---------------- TX byte mux ----------------
    wire [7:0] abyte = (bcnt == 8'd0) ? imgA[0][31:24] :
                       (bcnt == 8'd1) ? imgA[0][23:16] :
                       (bcnt == 8'd2) ? imgA[0][15:8] : imgA[0][7:0];
    wire [7:0] bbyte = (bcnt == 8'd0) ? imgB[wcnt[5:0]][31:24] :
                       (bcnt == 8'd1) ? imgB[wcnt[5:0]][23:16] :
                       (bcnt == 8'd2) ? imgB[wcnt[5:0]][15:8] : imgB[wcnt[5:0]][7:0];
    reg [7:0] txb;
    always @(*) begin
        case (st_r)
            A_TX_SYNC, B_TX_SYNC, B_TX_RESYNC:
                txb = 8'h00;
            A_TX_LDHDR:
                txb = (bcnt == 8'd0) ? 8'h01 : (bcnt == 8'd1) ? 8'h06 : 8'h00;
            A_TX_LDDATA:
                txb = abyte;
            A_TX_GO1, A_TX_GO2, B_TX_GO:
                txb = (bcnt == 8'd0) ? 8'h09 : 8'h00;
            A_TX_ST1, A_TX_ST2, A_TX_ST3, B_TX_STF, B_POLL_ST_TX:
                txb = (bcnt == 8'd0) ? 8'h08 : 8'h00;
            A_TX_HALT:
                txb = (bcnt == 8'd0) ? 8'h0A : 8'h00;
            B_TX_LDHDR:
                txb = (bcnt == 8'd0) ? 8'h01 : (bcnt == 8'd1) ? 8'h86 : 8'h00;
            B_TX_LDDATA:
                txb = bbyte;
            B_TX_VFHDR:
                txb = (bcnt == 8'd0) ? 8'h02 : (bcnt == 8'd1) ? 8'h03 :
                      (bcnt == 8'd4) ? 8'h21 : 8'h00;
            B_TX_WRHDR:
                txb = (bcnt == 8'd0) ? 8'h05 : 8'h0E;
            B_TX_WRDATA:
                txb = (bcnt == 8'd0) ? 8'h00 : wr_rom[wcnt[2:0]][7:0];
            B_TX_TXF:
                txb = (bcnt == 8'd0) ? 8'h06 : (bcnt == 8'd1) ? 8'h01 : 8'hFF;
            default:
                txb = 8'h00;
        endcase
    end

    // ---------------- RX expected-byte mux ----------------
    wire [7:0] txexpb = (bcnt == 8'd0) ? 8'h00 : (bcnt == 8'd1) ? 8'h01 :
                        (bcnt == 8'd2) ? 8'h00 : (bcnt == 8'd3) ? 8'h02 :
                        (bcnt == 8'd4) ? 8'h00 : 8'h03;
    reg [7:0] rxexp;
    always @(*) begin
        case (st_r)
            A_RX_ST1, A_RX_ST3: rxexp = 8'h90;
            A_RX_ST2:           rxexp = 8'h50;
            B_RX_STF:           rxexp = fault_lat ? 8'h41 : 8'h40;  // vacuity hook
            B_RX_TXF_CNT:       rxexp = 8'h06;
            B_RX_TXF_DATA:      rxexp = txexpb;
            default:            rxexp = 8'hA5;
        endcase
    end

    // ---------------- start edge detect ----------------
    reg start_d;
    wire start_re = start_test && !start_d;

    task do_fail(input [7:0] code);
        begin
            fail_code <= code;
            done <= 1'b1;
        end
    endtask

    // ---------------- main FSM ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_r <= S_IDLE; bcnt <= 8'd0; wcnt <= 8'd0;
            tcnt <= 18'd0; poll_tcnt <= 18'd0;
            milestones <= 16'd0; fail_code <= 8'd0;
            phaseA_pass <= 1'b0; phaseB_pass <= 1'b0; done <= 1'b0;
            signature <= 32'd0; fault_lat <= 1'b0;
            pin_en <= 1'b0; tx_byte <= 8'd0; tx_start <= 1'b0;
            start_d <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            start_d <= start_test;
            if (rx_valid && !done) signature <= sig_fold(signature, rx_byte);
            if (done) begin
                if (!start_test) begin
                    st_r <= S_IDLE; done <= 1'b0;  // re-arm
                end
                // else hold results
            end else begin
                case (st_r)
                // ============ IDLE ============
                S_IDLE: begin
                    if (start_re) begin
                        milestones <= 16'd0; fail_code <= 8'd0;
                        phaseA_pass <= 1'b0; phaseB_pass <= 1'b0; done <= 1'b0;
                        signature <= 32'd0; fault_lat <= inject_fault;
                        pin_en <= 1'b0;
                        bcnt <= 8'd0; wcnt <= 8'd0; tcnt <= 18'd0; poll_tcnt <= 18'd0;
                        st_r <= A_RST;
                    end
                end
                // ============ Phase A ============
                A_RST: begin  // phase_reset asserted via phase_reset wire
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd20) begin tcnt <= 18'd0; st_r <= A_RSTREL; end
                end
                A_RSTREL: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd10) begin tcnt <= 18'd0; st_r <= A_TX_SYNC; end
                end
                A_TX_SYNC: begin  // 0x00 autobaud sync
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin bcnt <= 8'd0; st_r <= A_TX_LDHDR; end
                end
                A_TX_LDHDR: begin  // 01 06 00 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd3) begin bcnt <= 8'd0; st_r <= A_TX_LDDATA; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_TX_LDDATA: begin  // 1 word MSB-first
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd3) begin bcnt <= 8'd0; st_r <= A_RX_LDAK; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_RX_LDAK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin milestones[M_A_AUTOBAUD] <= 1'b1; st_r <= A_TX_GO1; end
                        else do_fail(8'h01);
                    end else if (tcnt == 18'd100000) do_fail(8'h01);
                end
                A_TX_GO1: begin  // 09 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= A_RX_GOAK1; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_RX_GOAK1: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin st_r <= A_WAIT200; tcnt <= 18'd0; end
                        else do_fail(8'h02);
                    end else if (tcnt == 18'd100000) do_fail(8'h02);
                end
                A_WAIT200: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd200) begin tcnt <= 18'd0; st_r <= A_TX_ST1; end
                end
                A_TX_ST1: begin  // 08 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= A_RX_STAK1; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_RX_STAK1: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin st_r <= A_RX_ST1; end
                        else do_fail(8'h03);
                    end else if (tcnt == 18'd100000) do_fail(8'h03);
                end
                A_RX_ST1: begin  // expect 0x90
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin milestones[M_A_RUN1] <= 1'b1; st_r <= A_TX_HALT; end
                        else do_fail(8'h03);
                    end else if (tcnt == 18'd100000) do_fail(8'h03);
                end
                A_TX_HALT: begin  // 0A 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= A_RX_HALTAK; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_RX_HALTAK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin st_r <= A_WAIT50; tcnt <= 18'd0; end
                        else do_fail(8'h04);
                    end else if (tcnt == 18'd100000) do_fail(8'h04);
                end
                A_WAIT50: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd50) begin tcnt <= 18'd0; st_r <= A_TX_ST2; end
                end
                A_TX_ST2: begin  // 08 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= A_RX_STAK2; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_RX_STAK2: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin st_r <= A_RX_ST2; end
                        else do_fail(8'h05);
                    end else if (tcnt == 18'd100000) do_fail(8'h05);
                end
                A_RX_ST2: begin  // expect 0x50
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin milestones[M_A_HALT] <= 1'b1; st_r <= A_TX_GO2; end
                        else do_fail(8'h05);
                    end else if (tcnt == 18'd100000) do_fail(8'h05);
                end
                A_TX_GO2: begin  // 09 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= A_RX_GOAK2; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_RX_GOAK2: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin st_r <= A_WAIT100; tcnt <= 18'd0; end
                        else do_fail(8'h06);
                    end else if (tcnt == 18'd100000) do_fail(8'h06);
                end
                A_WAIT100: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd100) begin tcnt <= 18'd0; st_r <= A_TX_ST3; end
                end
                A_TX_ST3: begin  // 08 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= A_RX_STAK3; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                A_RX_STAK3: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin st_r <= A_RX_ST3; end
                        else do_fail(8'h07);
                    end else if (tcnt == 18'd100000) do_fail(8'h07);
                end
                A_RX_ST3: begin  // expect 0x90
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin
                            milestones[M_A_RUN2] <= 1'b1; phaseA_pass <= 1'b1;
                            st_r <= B_RST; tcnt <= 18'd0;
                        end else do_fail(8'h07);
                    end else if (tcnt == 18'd100000) do_fail(8'h07);
                end
                // ============ Phase B ============
                B_RST: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd20) begin tcnt <= 18'd0; st_r <= B_RSTREL; end
                end
                B_RSTREL: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd10) begin tcnt <= 18'd0; st_r <= B_TX_SYNC; end
                end
                B_TX_SYNC: begin  // 0x00 autobaud sync
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin bcnt <= 8'd0; st_r <= B_TX_LDHDR; end
                end
                B_TX_LDHDR: begin  // 01 86 00 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd3) begin bcnt <= 8'd0; wcnt <= 8'd0; st_r <= B_TX_LDDATA; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_TX_LDDATA: begin  // 33 words MSB-first
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (wcnt == 8'd32 && bcnt == 8'd3) begin
                            bcnt <= 8'd0; wcnt <= 8'd0; st_r <= B_RX_LDAK; tcnt <= 18'd0;
                        end else if (bcnt == 8'd3) begin bcnt <= 8'd0; wcnt <= wcnt + 8'd1; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_RX_LDAK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin milestones[M_B_LOAD] <= 1'b1; st_r <= B_TX_VFHDR; end
                        else do_fail(8'h08);
                    end else if (tcnt == 18'd100000) do_fail(8'h08);
                end
                B_TX_VFHDR: begin  // 02 03 00 00 21
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd4) begin bcnt <= 8'd0; st_r <= B_RX_VFAK; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_RX_VFAK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin bcnt <= 8'd0; wcnt <= 8'd0; st_r <= B_RX_VFDATA; end
                        else do_fail(8'h09);
                    end else if (tcnt == 18'd100000) do_fail(8'h09);
                end
                B_RX_VFDATA: begin  // 132 bytes, compared against imgB
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte != bbyte) do_fail(8'h0A);
                        else if (wcnt == 8'd32 && bcnt == 8'd3) begin
                            milestones[M_B_VERIFY] <= 1'b1;
                            bcnt <= 8'd0; wcnt <= 8'd0; st_r <= B_WAIT3000; tcnt <= 18'd0;
                        end else if (bcnt == 8'd3) begin bcnt <= 8'd0; wcnt <= wcnt + 8'd1; end
                        else bcnt <= bcnt + 8'd1;
                    end else if (tcnt == 18'd100000) do_fail(8'h0A);
                end
                B_WAIT3000: begin  // let VERIFY reply idle re-arm autobaud
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd3000) begin tcnt <= 18'd0; st_r <= B_TX_RESYNC; end
                end
                B_TX_RESYNC: begin  // 0x00 sync (consumed as NOP)
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin st_r <= B_WAIT2000; tcnt <= 18'd0; end
                end
                B_WAIT2000: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd2000) begin tcnt <= 18'd0; st_r <= B_TX_GO; end
                end
                B_TX_GO: begin  // 09 00
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= B_RX_GOAK; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_RX_GOAK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin
                            milestones[M_B_GO] <= 1'b1; pin_en <= 1'b1;
                            st_r <= B_TX_WRHDR;
                        end else do_fail(8'h0B);
                    end else if (tcnt == 18'd100000) do_fail(8'h0B);
                end
                B_TX_WRHDR: begin  // 05 0E
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; wcnt <= 8'd0; st_r <= B_TX_WRDATA; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_TX_WRDATA: begin  // 7 words {1,1,1,3,1,2,3} MSB-first
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (wcnt == 8'd6 && bcnt == 8'd1) begin
                            bcnt <= 8'd0; wcnt <= 8'd0; st_r <= B_RX_WRAK; tcnt <= 18'd0;
                        end else if (bcnt == 8'd1) begin bcnt <= 8'd0; wcnt <= wcnt + 8'd1; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_RX_WRAK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin
                            milestones[M_B_WR] <= 1'b1;
                            st_r <= B_POLL_ST_TX; poll_tcnt <= 18'd0; tcnt <= 18'd0;
                        end else do_fail(8'h0C);
                    end else if (tcnt == 18'd100000) do_fail(8'h0C);
                end
                B_POLL_ST_TX: begin  // 08 00 (poll loop)
                    poll_tcnt <= poll_tcnt + 18'd1;
                    if (poll_tcnt == 18'd200000) do_fail(8'h0D);
                    else begin
                        tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                        if (tx_done) begin
                            if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= B_POLL_ST_AK; tcnt <= 18'd0; end
                            else bcnt <= bcnt + 8'd1;
                        end
                    end
                end
                B_POLL_ST_AK: begin
                    poll_tcnt <= poll_tcnt + 18'd1;
                    if (poll_tcnt == 18'd200000) do_fail(8'h0D);
                    else begin
                        tcnt <= tcnt + 18'd1;
                        if (rx_valid) begin
                            tcnt <= 18'd0;
                            if (rx_byte == rxexp) st_r <= B_POLL_ST_RX;
                            else do_fail(8'h0D);
                        end else if (tcnt == 18'd100000) do_fail(8'h0D);
                    end
                end
                B_POLL_ST_RX: begin
                    poll_tcnt <= poll_tcnt + 18'd1;
                    if (poll_tcnt == 18'd200000) do_fail(8'h0D);
                    else begin
                        tcnt <= tcnt + 18'd1;
                        if (rx_valid) begin
                            tcnt <= 18'd0;
                            if (rx_byte == 8'h40) begin
                                milestones[M_B_HALTSEEN] <= 1'b1; pin_en <= 1'b0;
                                st_r <= B_PINCHK;
                            end else st_r <= B_POLL_ST_TX;  // still running; poll again
                        end else if (tcnt == 18'd100000) do_fail(8'h0D);
                    end
                end
                B_PINCHK: begin
                    if (pseq_ok) begin
                        milestones[M_B_PINSEQ] <= 1'b1;
                        signature <= fold_pins(signature, pin_n);
                        st_r <= B_TX_STF;
                    end else do_fail(8'h0E);
                end
                B_TX_STF: begin  // 08 00 (final status)
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd1) begin bcnt <= 8'd0; st_r <= B_RX_STF_AK; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_RX_STF_AK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == 8'hA5) st_r <= B_RX_STF;
                        else do_fail(8'h0F);
                    end else if (tcnt == 18'd100000) do_fail(8'h0F);
                end
                B_RX_STF: begin  // expect 0x40 (0x41 if inject_fault)
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin milestones[M_B_STATUS] <= 1'b1; st_r <= B_TX_TXF; end
                        else do_fail(8'h0F);
                    end else if (tcnt == 18'd100000) do_fail(8'h0F);
                end
                B_TX_TXF: begin  // 06 01 FF
                    tx_byte <= txb;
                    if (!tx_busy && !tx_launched && !tx_done) begin tx_start <= 1'b1; end
                    if (tx_done) begin
                        if (bcnt == 8'd2) begin bcnt <= 8'd0; st_r <= B_RX_TXF_AK; tcnt <= 18'd0; end
                        else bcnt <= bcnt + 8'd1;
                    end
                end
                B_RX_TXF_AK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) st_r <= B_RX_TXF_CNT;
                        else do_fail(8'h10);
                    end else if (tcnt == 18'd100000) do_fail(8'h10);
                end
                B_RX_TXF_CNT: begin  // expect count=6
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == rxexp) begin bcnt <= 8'd0; st_r <= B_RX_TXF_DATA; end
                        else do_fail(8'h10);
                    end else if (tcnt == 18'd100000) do_fail(8'h10);
                end
                B_RX_TXF_DATA: begin  // 6 bytes: 00 01 00 02 00 03
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte != rxexp) do_fail(8'h11);
                        else if (bcnt == 8'd5) begin
                            milestones[M_B_TXDATA] <= 1'b1;
                            phaseB_pass <= 1'b1;
                            done <= 1'b1;
                        end else bcnt <= bcnt + 8'd1;
                    end else if (tcnt == 18'd100000) do_fail(8'h11);
                end
                default: st_r <= S_IDLE;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
