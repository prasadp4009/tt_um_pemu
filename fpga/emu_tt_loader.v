// emu_tt_loader.v -- FPGA host-loader replicating test/test.py on real hardware.
//
// Drives tt_um_pemu's 2-wire host port EXACTLY like the TT template sim:
//   reset, hp_tx idles high
//   0x00 autobaud sync; RD_STATUS in PROG (expect 0x10)
//   LOAD_IMEM SPI image (71 words) in 2 chunked frames (60+11), ACK each
//   VERIFY_IMEM readback, byte-exact vs image
//     (0x00 resync between VERIFY chunks is MANDATORY: the 240-byte reply
//      idles the chip's RX line >65535 clocks, re-arming autobaud;
//      the 44-byte reply does NOT re-arm, so GO follows it directly --
//      an extra 0x00 there would be parsed as cmd=0x00 and corrupt framing)
//   GO, RD_STATUS = PE_RUNNING (0x80 set, 0x40 clear)
//   drain TX FIFO (idle markers)
//   WR_RXFIFO single-word HALT command (0x00FF); RD_STATUS = PE_HALTED
//     (0x40 set, 0x80 clear)
//   drain TX FIFO
//   WR_RXFIFO TRANSFER command {0x0001,0x0002,0x00A5,0x003C} while halted
//   GO (wake PE); capture the CS# pulse on uio pins:
//     expect exactly 16 SCLK rising edges, MOSI = 0xA5,0x3C MSB-first
//     (pin wait <= 20000 clocks like test.py, so no autobaud re-arm)
//   RD_TXFIFO: every word in {0x0000,0xFFFF}; 3 consecutive 0x0000 present
//
// UART: 10-bit frames (start + 8b LSB-first + stop), T=100 core clocks/bit,
// idle high, bit edges on posedge boundaries -- identical to emu_loader and
// test/tb_top.v. Responses sampled at 1.5T, 2.5T, ... after the falling edge.
//
// Results: 15 milestones + fail_code + tt_pass + done + CRC-style signature
// to VIO. inject_fault (latched at run start) inverts the post-HALT RD_STATUS
// expectation to PE_RUNNING: the vacuity (negative-control) run.
// Observation registers dbg0/dbg1/dbg2 -> vio_dbg for exact-vector readout.
//
// Frame map (matches test.py wire bytes exactly):
//   RD_STATUS : 08 00                       -> ACK + status byte
//   LOAD_IMEM : 01 LEN ahi alo <4n bytes>    -> ACK
//   VERIFY    : 02 03 ahi alo n             -> ACK + 4n bytes
//   GO        : 09 00                       -> ACK
//   WR_RXFIFO : 05 LEN <data>               -> ACK
//   RD_TXFIFO : 06 01 20                    -> ACK + count + count bytes
//   0x00      : NOP (also the autobaud sync when sync_armed)
//
// FPGA-EMULATION-ONLY. Not for ASIC synthesis.
//
// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module emu_tt_loader (
    input  wire        clk,          // test clock
    input  wire        rst_n,        // async-assert, sync-deassert, active low
    // DUT host port
    output reg         hp_rx,        // -> DUT ui_in[0], idle high
    input  wire        hp_tx,        // <- DUT uo_out[0]
    input  wire [7:0]  uio_out,      // <- DUT uio_out (pin recorder)
    input  wire [7:0]  uio_oe,       // <- DUT uio_oe
    output wire        phase_reset,  // DUT reset during T_RST
    // control (already synchronized into clk domain by emu_tt_top)
    input  wire        start_test,   // level; rising edge starts a run
    input  wire        inject_fault, // latched at run start; vacuity hook
    // results
    output reg  [15:0] milestones,
    output reg  [7:0]  fail_code,
    output reg         tt_pass,
    output reg         done,
    output reg  [31:0] signature,
    output wire [7:0]  st,           // FSM state (ILA)
    output wire        tx_busy_o,
    output wire        rx_valid_o,
    // observation registers (to vio_dbg)
    output reg  [31:0] dbg0,         // {8'b0, st_halt, st_run, st_prog}
    output reg  [31:0] dbg1,         // {saw_pulse, spi_ok, 6'b0, edge_cnt, mosi[15:0]}
    output reg  [31:0] dbg2          // {txf_n, txf_zeros, txf_bad, three_zero, 14'b0}
);

    localparam T = 100;  // UART bit period in core clocks
    localparam [17:0] RX_TIMEOUT  = 18'd100000;
    localparam [17:0] REC_TIMEOUT = 18'd20000;  // matches test.py wait_done(20000)

    // ---------------- SPI image ROM (71 words) ----------------
    // NOTE: case-based ROM (not array+initial) because Vivado init
    // extraction for LUTRAM proved unreliable (DCP: all-zero INIT).
    // Case statement synthesizes to LUT equations; cannot be dropped.
    // Generated from fpga/spi_fpga.hex.
    // Firmware image descriptor: total 32-bit words in the img_word
    // case ROM. Rewritten per protocol by fpga/gen_fw_rom.py
    // (do not hand-edit the value).
    localparam [7:0] IMG_WORDS = 8'd132;
    function [31:0] img_word(input [7:0] w);
        case (w)
            8'd0 : img_word = 32'h101fe000;
            8'd1 : img_word = 32'h0c1fe000;
            8'd2 : img_word = 32'h00802000;
            8'd3 : img_word = 32'h081e0000;
            8'd4 : img_word = 32'h28018000;
            8'd5 : img_word = 32'h14000000;
            8'd6 : img_word = 32'h0c100000;
            8'd7 : img_word = 32'h10100000;
            8'd8 : img_word = 32'h00100000;
            8'd9 : img_word = 32'h4c00b600;
            8'd10 : img_word = 32'h4c009000;
            8'd11 : img_word = 32'h300e0000;
            8'd12 : img_word = 32'h28000000;
            8'd13 : img_word = 32'h3c001e00;
            8'd14 : img_word = 32'h480e0000;
            8'd15 : img_word = 32'h4c023100;
            8'd16 : img_word = 32'h3c001e00;
            8'd17 : img_word = 32'h480e0000;
            8'd18 : img_word = 32'h4c044100;
            8'd19 : img_word = 32'h3c001e00;
            8'd20 : img_word = 32'h480e0000;
            8'd21 : img_word = 32'h4c05a100;
            8'd22 : img_word = 32'h3c001e00;
            8'd23 : img_word = 32'h480e0000;
            8'd24 : img_word = 32'h4c072100;
            8'd25 : img_word = 32'h280001fc;
            8'd26 : img_word = 32'h3c001e00;
            8'd27 : img_word = 32'h480e0000;
            8'd28 : img_word = 32'h4c022100;
            8'd29 : img_word = 32'h2801fffc;
            8'd30 : img_word = 32'h3c001e00;
            8'd31 : img_word = 32'h2c000000;
            8'd32 : img_word = 32'h5c020000;
            8'd33 : img_word = 32'h4c009000;
            8'd34 : img_word = 32'h58000000;
            8'd35 : img_word = 32'h5402d000;
            8'd36 : img_word = 32'h4801e000;
            8'd37 : img_word = 32'h4c02a100;
            8'd38 : img_word = 32'h28000000;
            8'd39 : img_word = 32'h2c000000;
            8'd40 : img_word = 32'h5c020000;
            8'd41 : img_word = 32'h4c009000;
            8'd42 : img_word = 32'h2c1e0000;
            8'd43 : img_word = 32'h5c000000;
            8'd44 : img_word = 32'h4c009000;
            8'd45 : img_word = 32'h00000000;
            8'd46 : img_word = 32'h181f3f00;
            8'd47 : img_word = 32'h181f3f00;
            8'd48 : img_word = 32'h181f3f00;
            8'd49 : img_word = 32'h00100000;
            8'd50 : img_word = 32'h1c1e0800;
            8'd51 : img_word = 32'h1c1c2800;
            8'd52 : img_word = 32'h4c042500;
            8'd53 : img_word = 32'h280c0008;
            8'd54 : img_word = 32'h34000000;
            8'd55 : img_word = 32'h38000000;
            8'd56 : img_word = 32'h1c1e2800;
            8'd57 : img_word = 32'h4c03b500;
            8'd58 : img_word = 32'h4c03d000;
            8'd59 : img_word = 32'h500c3600;
            8'd60 : img_word = 32'h4c042000;
            8'd61 : img_word = 32'h181fff00;
            8'd62 : img_word = 32'h181fff00;
            8'd63 : img_word = 32'h28000000;
            8'd64 : img_word = 32'h3c001e00;
            8'd65 : img_word = 32'h54000800;
            8'd66 : img_word = 32'h28000000;
            8'd67 : img_word = 32'h54000800;
            8'd68 : img_word = 32'h4c046600;
            8'd69 : img_word = 32'h4c044000;
            8'd70 : img_word = 32'h30040000;
            8'd71 : img_word = 32'h5404c000;
            8'd72 : img_word = 32'h28000000;
            8'd73 : img_word = 32'h2c000000;
            8'd74 : img_word = 32'h5c000000;
            8'd75 : img_word = 32'h4c009000;
            8'd76 : img_word = 32'h28020010;
            8'd77 : img_word = 32'h44045f00;
            8'd78 : img_word = 32'h4c054300;
            8'd79 : img_word = 32'h00000000;
            8'd80 : img_word = 32'h180be800;
            8'd81 : img_word = 32'h00100000;
            8'd82 : img_word = 32'h1801bc00;
            8'd83 : img_word = 32'h4c058000;
            8'd84 : img_word = 32'h00000000;
            8'd85 : img_word = 32'h18012a00;
            8'd86 : img_word = 32'h00100000;
            8'd87 : img_word = 32'h180c7b00;
            8'd88 : img_word = 32'h50024d00;
            8'd89 : img_word = 32'h54000800;
            8'd90 : img_word = 32'h5405e000;
            8'd91 : img_word = 32'h2c040000;
            8'd92 : img_word = 32'h5c000000;
            8'd93 : img_word = 32'h4c009000;
            8'd94 : img_word = 32'h28020010;
            8'd95 : img_word = 32'h28040000;
            8'd96 : img_word = 32'h28080100;
            8'd97 : img_word = 32'h2800000c;
            8'd98 : img_word = 32'h3c001e00;
            8'd99 : img_word = 32'h00000000;
            8'd100 : img_word = 32'h18012a00;
            8'd101 : img_word = 32'h00100000;
            8'd102 : img_word = 32'h1801c300;
            8'd103 : img_word = 32'h08060000;
            8'd104 : img_word = 32'h44066100;
            8'd105 : img_word = 32'h44045f00;
            8'd106 : img_word = 32'h4807e000;
            8'd107 : img_word = 32'h4c06e200;
            8'd108 : img_word = 32'h40044880;
            8'd109 : img_word = 32'h4c06f000;
            8'd110 : img_word = 32'h18000100;
            8'd111 : img_word = 32'h180ab200;
            8'd112 : img_word = 32'h50026300;
            8'd113 : img_word = 32'h54000800;
            8'd114 : img_word = 32'h5402d000;
            8'd115 : img_word = 32'h4801e000;
            8'd116 : img_word = 32'h4c079100;
            8'd117 : img_word = 32'h28000000;
            8'd118 : img_word = 32'h2c000000;
            8'd119 : img_word = 32'h5c020000;
            8'd120 : img_word = 32'h4c009000;
            8'd121 : img_word = 32'h28040198;
            8'd122 : img_word = 32'h5404c000;
            8'd123 : img_word = 32'h2804017c;
            8'd124 : img_word = 32'h5404c000;
            8'd125 : img_word = 32'h280c0010;
            8'd126 : img_word = 32'h3c0cde00;
            8'd127 : img_word = 32'h5405e000;
            8'd128 : img_word = 32'h2c040000;
            8'd129 : img_word = 32'h500c7f00;
            8'd130 : img_word = 32'h5c000000;
            8'd131 : img_word = 32'h4c009000;
            default: img_word = 32'h00000000;
        endcase
    endfunction


    function [7:0] img_byte(input [7:0] w, input [1:0] s);
        reg [31:0] word;
        begin
            word = img_word(w);
            img_byte = (s == 2'd0) ? word[31:24] :
                       (s == 2'd1) ? word[23:16] :
                       (s == 2'd2) ? word[15:8] : word[7:0];
        end
    endfunction

    // TRANSFER command payload bytes: 00 01 | 00 02 | 00 A5 | 00 3C
    function [7:0] xf_byte(input [2:0] i);
        xf_byte = (i == 3'd0) ? 8'h00 : (i == 3'd1) ? 8'h01 :
                  (i == 3'd2) ? 8'h00 : (i == 3'd3) ? 8'h02 :
                  (i == 3'd4) ? 8'h00 : (i == 3'd5) ? 8'hA5 :
                  (i == 3'd6) ? 8'h00 : 8'h3C;
    endfunction

    // ---------------- FSM states ----------------
    localparam [7:0]
        S_IDLE   = 8'h00,
        T_RST    = 8'h01, T_RSTREL = 8'h02, T_CHKIDLE = 8'h03,
        T_SYNC   = 8'h04,
        T_ST_TX  = 8'h05, T_ST_AK = 8'h06, T_ST_RX = 8'h07,
        T_LD_TX  = 8'h08, T_LD_AK = 8'h09,
        T_VF_TX  = 8'h0A, T_VF_AK = 8'h0B, T_VF_RX = 8'h0C,
        T_RS1    = 8'h0D,
        T_RS2    = 8'h0E,   // 0x00 resync before GO (GENERIC_MODE)
        T_GO_TX  = 8'h10, T_GO_AK = 8'h11, T_GO_W = 8'h12,
        T_ST2_TX = 8'h13, T_ST2_AK = 8'h14, T_ST2_RX = 8'h15,
        T_DR1_TX = 8'h16, T_DR1_AK = 8'h17, T_DR1_CNT = 8'h18, T_DR1_RX = 8'h19,
        T_HLT_TX = 8'h1A, T_HLT_AK = 8'h1B, T_HLT_W = 8'h1C,
        T_ST3_TX = 8'h1D, T_ST3_AK = 8'h1E, T_ST3_RX = 8'h1F,
        T_DR2_TX = 8'h20, T_DR2_AK = 8'h21, T_DR2_CNT = 8'h22, T_DR2_RX = 8'h23,
        T_XF_TX  = 8'h24, T_XF_AK = 8'h25,
        T_GO2_TX = 8'h26, T_GO2_AK = 8'h27, T_REC_W = 8'h28, T_REC_AN = 8'h29,
        T_TXF_TX = 8'h2B, T_TXF_AK = 8'h2C, T_TXF_CNT = 8'h2D,
        T_TXF_RX = 8'h2E, T_TXF_EVAL = 8'h2F,
        T_OK     = 8'h30,
        T_DG_TX  = 8'h31, T_DG_AK = 8'h32, T_DG_CNT = 8'h33,
        T_DG_RX  = 8'h34, T_DG_DONE = 8'h35;

    // milestones
    localparam M_TX_IDLE = 0,  // hp_tx idles high after reset
               M_ST_PROG = 1,  // RD_STATUS in PROG == 0x10
               M_LOAD0   = 2,  // LOAD_IMEM chunk0 (60w) ACK
               M_LOAD1   = 3,  // LOAD_IMEM chunk1 (11w) ACK
               M_VF0     = 4,  // VERIFY chunk0 byte-exact
               M_VF1     = 5,  // VERIFY chunk1 byte-exact
               M_GO      = 6,  // GO ACK
               M_RUNNING = 7,  // RD_STATUS: 0x80 set, 0x40 clear
               M_DRAIN1  = 8,  // TX FIFO drained (idle markers)
               M_HALTED  = 9,  // RD_STATUS: 0x40 set, 0x80 clear
               M_DRAIN2  = 10, // TX FIFO pre-drained
               M_XFER    = 11, // WR_RXFIFO TRANSFER command ACK
               M_PULSE   = 12, // CS# pulse captured on pins
               M_SPIOK   = 13, // 16 SCLK edges, MOSI = 0xA5,0x3C
               M_TXFIFO  = 14; // TX FIFO: words in {0,0xFFFF}, 3x 0x0000 found

    reg [7:0] st_r;
    assign st = st_r;
    assign phase_reset = (st_r == T_RST);

    reg [7:0]  bcnt;        // byte counter within a TX frame
    reg [8:0]  dcnt;        // VERIFY data-byte counter
    reg [17:0] tcnt;        // wait / RX timeout counter
    reg        fault_lat;   // inject_fault latched at run start

    reg [7:0] ld_base, ld_n;   // LOAD chunk descriptor
    reg [7:0] vf_base, vf_n;   // VERIFY chunk descriptor
    reg [7:0] dr_n;            // drain count
    reg [7:0] txf_n, rxc;      // TXFIFO count / received bytes
    reg [7:0] w_hi;            // TXFIFO word high byte
    reg       byte_odd;
    reg [7:0] txf_zeros, zero_run;
    reg       three_zero, txf_bad;

    // pin recorder
    reg       rec_run;
    reg       rec_saw_low;
    reg       rec_sclk_prev, rec_sclk_valid;
    reg [7:0] rec_edge_cnt;
    reg [15:0] rec_mosi;
    reg [17:0] rec_tcnt;
    reg       rec_pulse_done, rec_timeout;

    // ---------------- signature fold ----------------
    function [31:0] sig_fold(input [31:0] s, input [7:0] b);
        sig_fold = (s << 1) ^ {24'b0, b} ^ (s[31] ? 32'h04C11DB7 : 32'b0);
    endfunction

    // ---------------- TX byte mux ----------------
    wire [7:0] ld_pcnt = bcnt - 8'd4;
    reg [7:0] txb;
    always @(*) begin
        case (st_r)
            T_SYNC, T_RS1, T_RS2:
                txb = 8'h00;
            T_ST_TX, T_ST2_TX, T_ST3_TX:
                txb = (bcnt == 8'd0) ? 8'h08 : 8'h00;
            T_LD_TX:
                txb = (bcnt == 8'd0) ? 8'h01 :
                      (bcnt == 8'd1) ? (8'd2 + (ld_n << 2)) :
                      (bcnt == 8'd2) ? 8'h00 :
                      (bcnt == 8'd3) ? ld_base :
                      img_byte(ld_base + ld_pcnt[7:2], ld_pcnt[1:0]);
            T_VF_TX:
                txb = (bcnt == 8'd0) ? 8'h02 :
                      (bcnt == 8'd1) ? 8'h03 :
                      (bcnt == 8'd2) ? 8'h00 :
                      (bcnt == 8'd3) ? vf_base : vf_n;
            T_GO_TX, T_GO2_TX:
                txb = (bcnt == 8'd0) ? 8'h09 : 8'h00;
            T_DR1_TX, T_DR2_TX, T_TXF_TX, T_DG_TX:
                txb = (bcnt == 8'd0) ? 8'h06 :
                      (bcnt == 8'd1) ? 8'h01 : 8'h20;
            T_HLT_TX:
                txb = (bcnt == 8'd0) ? 8'h05 :
                      (bcnt == 8'd1) ? 8'h02 :
                      (bcnt == 8'd2) ? 8'h00 : 8'hFF;
            T_XF_TX:
                txb = (bcnt == 8'd0) ? 8'h05 :
                      (bcnt == 8'd1) ? 8'h08 : xf_byte(bcnt[2:0] - 3'd2);
            default:
                txb = 8'h00;
        endcase
    end

    // ---------------- TX frame length mux ----------------
    reg [7:0] tx_last;
    always @(*) begin
        case (st_r)
            T_SYNC, T_RS1, T_RS2:
                tx_last = 8'd0;                        // 1 byte
            T_VF_TX:
                tx_last = 8'd4;                        // 5 bytes
            T_HLT_TX:
                tx_last = 8'd3;                        // 4 bytes
            T_XF_TX:
                tx_last = 8'd9;                        // 10 bytes
            T_LD_TX:
                tx_last = 8'd3 + (ld_n << 2);          // 4 + 4n bytes
            T_DR1_TX, T_DR2_TX, T_TXF_TX, T_DG_TX:
                tx_last = 8'd2;                        // 3 bytes: 06 01 20
            default:
                tx_last = 8'd1;                        // 2 bytes: ST / GO
        endcase
    end

    // ---------------- UART TX engine (verbatim from emu_loader) ----------------
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

    // ---------------- UART RX monitor (verbatim from emu_loader) ----------------
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

    // ---------------- start edge detect ----------------
    reg start_d;
    wire start_re = start_test && !start_d;

    task do_fail(input [7:0] code);
        begin
            fail_code <= code;
            rec_run <= 1'b0;
            done <= 1'b1;
        end
    endtask

    // generic TX-frame driver: send tx_last+1 bytes from the txb mux
    task tx_step(input [7:0] nxt);
        begin
            tx_byte <= txb;
            if (!tx_busy && !tx_launched && !tx_done) tx_start <= 1'b1;
            if (tx_done) begin
                if (bcnt == tx_last) begin
                    bcnt <= 8'd0; tcnt <= 18'd0; st_r <= nxt;
                end else bcnt <= bcnt + 8'd1;
            end
        end
    endtask

    // generic ACK wait
    task rx_ack(input [7:0] nxt, input [7:0] code);
        begin
            tcnt <= tcnt + 18'd1;
            if (rx_valid) begin
                tcnt <= 18'd0;
                if (rx_byte == 8'hA5) st_r <= nxt;
                else do_fail(code);
            end else if (tcnt == RX_TIMEOUT) do_fail(code);
        end
    endtask

    // ---------------- main FSM ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_r <= S_IDLE; bcnt <= 8'd0; tcnt <= 18'd0; dcnt <= 9'd0;
            milestones <= 16'd0; fail_code <= 8'd0;
            tt_pass <= 1'b0; done <= 1'b0;
            signature <= 32'd0; fault_lat <= 1'b0;
            dbg0 <= 32'd0; dbg1 <= 32'd0; dbg2 <= 32'd0;
            tx_byte <= 8'd0; tx_start <= 1'b0;
            start_d <= 1'b0;
            ld_base <= 8'd0; ld_n <= 8'd0; vf_base <= 8'd0; vf_n <= 8'd0;
            dr_n <= 8'd0; txf_n <= 8'd0; rxc <= 8'd0;
            w_hi <= 8'd0; byte_odd <= 1'b0;
            txf_zeros <= 8'd0; zero_run <= 8'd0;
            three_zero <= 1'b0; txf_bad <= 1'b0;
            rec_run <= 1'b0; rec_saw_low <= 1'b0;
            rec_sclk_prev <= 1'b0; rec_sclk_valid <= 1'b0;
            rec_edge_cnt <= 8'd0; rec_mosi <= 16'd0;
            rec_tcnt <= 18'd0; rec_pulse_done <= 1'b0; rec_timeout <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            start_d <= start_test;
            if (rx_valid && !done) signature <= sig_fold(signature, rx_byte);

            // ---- pin recorder: samples uio while rec_run ----
            if (rec_run && !done) begin
                rec_tcnt <= rec_tcnt + 18'd1;
                if (uio_oe[5]) begin
                    if (!uio_out[5]) begin
                        rec_saw_low <= 1'b1;
                        if (rec_sclk_valid && !rec_sclk_prev && uio_out[2]) begin
                            rec_edge_cnt <= rec_edge_cnt + 8'd1;
                            rec_mosi <= {rec_mosi[14:0], uio_out[3]};
                        end
                        rec_sclk_prev <= uio_out[2];
                        rec_sclk_valid <= 1'b1;
                    end else if (rec_saw_low) begin
                        rec_run <= 1'b0;
                        rec_pulse_done <= 1'b1;
                    end
                end
                if (rec_tcnt == REC_TIMEOUT) begin
                    rec_run <= 1'b0;
                    rec_timeout <= 1'b1;
                end
            end

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
                        tt_pass <= 1'b0; done <= 1'b0;
                        signature <= 32'd0; fault_lat <= inject_fault;
                        dbg0 <= 32'd0; dbg1 <= 32'd0; dbg2 <= 32'd0;
                        bcnt <= 8'd0; tcnt <= 18'd0; dcnt <= 9'd0;
                        rec_run <= 1'b0; rec_pulse_done <= 1'b0; rec_timeout <= 1'b0;
                        st_r <= T_RST;
                    end
                end
                // ============ reset, hp_tx idle check ============
                T_RST: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd20) begin tcnt <= 18'd0; st_r <= T_RSTREL; end
                end
                T_RSTREL: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd10) begin tcnt <= 18'd0; st_r <= T_CHKIDLE; end
                end
                T_CHKIDLE: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd5) begin
                        tcnt <= 18'd0;
                        if (hp_tx) begin
                            milestones[M_TX_IDLE] <= 1'b1;
                            st_r <= T_SYNC;
                        end else do_fail(8'h01);
                    end
                end
                // ============ autobaud sync + RD_STATUS in PROG ============
                T_SYNC:  tx_step(T_ST_TX);
                T_ST_TX: tx_step(T_ST_AK);
                T_ST_AK: rx_ack(T_ST_RX, 8'h02);
                T_ST_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        dbg0[7:0] <= rx_byte;
                        if (rx_byte == 8'h10) begin
                            milestones[M_ST_PROG] <= 1'b1;
                            ld_base <= 8'd0;
`ifdef GENERIC_MODE
                            ld_n <= (IMG_WORDS > 8'd60) ? 8'd60 : IMG_WORDS;
`else
                            ld_n <= 8'd60;
`endif
                            st_r <= T_LD_TX;
                        end else do_fail(8'h03);
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h03);
                end
                // ============ LOAD_IMEM, chunked frames (60w + tail) ============
                T_LD_TX: tx_step(T_LD_AK);
                T_LD_AK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == 8'hA5) begin
`ifdef GENERIC_MODE
                            // N-chunk LOAD: 60-word chunks + tail chunk.
                            // ld_base/ld_n still hold the just-ACKed chunk.
                            if (ld_base == 8'd0)
                                milestones[M_LOAD0] <= 1'b1;
                            if (ld_base + ld_n >= IMG_WORDS) begin
                                // final chunk loaded
                                milestones[M_LOAD1] <= 1'b1;
                                vf_base <= 8'd0;
                                vf_n <= (IMG_WORDS > 8'd60) ? 8'd60 : IMG_WORDS;
                                dcnt <= 9'd0;
                                st_r <= T_VF_TX;
                            end else begin
                                ld_n <= ((IMG_WORDS - (ld_base + ld_n)) > 8'd60)
                                        ? 8'd60 : (IMG_WORDS - (ld_base + ld_n));
                                ld_base <= ld_base + ld_n;
                                st_r <= T_LD_TX;
                            end
`else
                            if (ld_base == 8'd0) begin
                                milestones[M_LOAD0] <= 1'b1;
                                ld_base <= 8'd60; ld_n <= 8'd11;
                                st_r <= T_LD_TX;
                            end else begin
                                milestones[M_LOAD1] <= 1'b1;
                                vf_base <= 8'd0; vf_n <= 8'd60; dcnt <= 9'd0;
                                st_r <= T_VF_TX;
                            end
`endif
                        end else do_fail(ld_base == 8'd0 ? 8'h04 : 8'h05);
                    end else if (tcnt == RX_TIMEOUT) do_fail(ld_base == 8'd0 ? 8'h04 : 8'h05);
                end
                // ============ VERIFY_IMEM, byte-exact ============
                T_VF_TX: tx_step(T_VF_AK);
                T_VF_AK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == 8'hA5) begin
                            dcnt <= 9'd0;
                            st_r <= T_VF_RX;
                        end else do_fail(vf_base == 8'd0 ? 8'h06 : 8'h08);
                    end else if (tcnt == RX_TIMEOUT) do_fail(vf_base == 8'd0 ? 8'h06 : 8'h08);
                end
                T_VF_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte != img_byte(vf_base + dcnt[8:2], dcnt[1:0]))
                            do_fail(vf_base == 8'd0 ? 8'h07 : 8'h09);
                        else if ((dcnt + 9'd1) == ({1'b0, vf_n} << 2)) begin
                            dcnt <= 9'd0;
`ifdef GENERIC_MODE
                            if (vf_base == 8'd0)
                                milestones[M_VF0] <= 1'b1;
                            if (vf_base + vf_n >= IMG_WORDS) begin
                                // final chunk verified byte-exact
                                milestones[M_VF1] <= 1'b1;
                                // 0x00 resync before GO only if the final reply
                                // was long enough (>65535 clocks) to re-arm the
                                // host autobaud; otherwise 0x00 is a NOP command
                                // that would eat the GO byte as its length.
                                // vf_n*4000 > 65535  <=>  vf_n > 16
                                st_r <= (vf_n > 8'd16) ? T_RS2 : T_GO_TX;
                            end else begin
                                // mandatory 0x00 resync between VERIFY chunks:
                                // each long reply idles the chip RX line
                                vf_n <= ((IMG_WORDS - (vf_base + vf_n)) > 8'd60)
                                        ? 8'd60 : (IMG_WORDS - (vf_base + vf_n));
                                vf_base <= vf_base + vf_n;
                                st_r <= T_RS1;
                            end
`else
                            if (vf_base == 8'd0) begin
                                milestones[M_VF0] <= 1'b1;
                                // mandatory 0x00 resync: the 240-byte reply
                                // idles the chip RX line >65535 clocks
                                vf_base <= 8'd60; vf_n <= 8'd11;
                                st_r <= T_RS1;
                            end else begin
                                milestones[M_VF1] <= 1'b1;
                                st_r <= T_GO_TX;
                            end
`endif
                        end else dcnt <= dcnt + 9'd1;
                    end else if (tcnt == RX_TIMEOUT) do_fail(vf_base == 8'd0 ? 8'h07 : 8'h09);
                end
                T_RS1:    tx_step(T_VF_TX);   // 0x00 resync between VERIFY chunks
                T_RS2:    tx_step(T_GO_TX);   // 0x00 resync before GO (GENERIC_MODE)
                // ============ GO, expect PE_RUNNING ============
                T_GO_TX: tx_step(T_GO_AK);
                T_GO_AK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == 8'hA5) begin
                            milestones[M_GO] <= 1'b1;
                            st_r <= T_GO_W;
                        end else do_fail(8'h0A);
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h0A);
                end
                T_GO_W: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd50) begin tcnt <= 18'd0; st_r <= T_ST2_TX; end
                end
                T_ST2_TX: tx_step(T_ST2_AK);
                T_ST2_AK: rx_ack(T_ST2_RX, 8'h0B);
                T_ST2_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        dbg0[15:8] <= rx_byte;
                        if ((rx_byte & 8'h80) && !(rx_byte & 8'h40)) begin
                            milestones[M_RUNNING] <= 1'b1;
                            st_r <= T_DR1_TX;
                        end else do_fail(8'h0B);
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h0B);
                end
                // ============ drain TX FIFO ============
                T_DR1_TX: tx_step(T_DR1_AK);
                T_DR1_AK: rx_ack(T_DR1_CNT, 8'h0C);
                T_DR1_CNT: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == 8'd0) begin
                            milestones[M_DRAIN1] <= 1'b1;
                            st_r <= T_HLT_TX;
                        end else begin
                            dr_n <= rx_byte; rxc <= 8'd0;
                            st_r <= T_DR1_RX;
                        end
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h0C);
                end
                T_DR1_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        rxc <= rxc + 8'd1;
                        if (rxc + 8'd1 == dr_n) begin
                            milestones[M_DRAIN1] <= 1'b1;
                            st_r <= T_HLT_TX;
                        end
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h0C);
                end
                // ============ HALT via firmware command 0x00FF ============
                T_HLT_TX: tx_step(T_HLT_AK);
                T_HLT_AK: rx_ack(T_HLT_W, 8'h0D);
                T_HLT_W: begin
                    tcnt <= tcnt + 18'd1;
                    if (tcnt == 18'd200) begin tcnt <= 18'd0; st_r <= T_ST3_TX; end
                end
                T_ST3_TX: tx_step(T_ST3_AK);
                T_ST3_AK: rx_ack(T_ST3_RX, 8'h0E);
                T_ST3_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        dbg0[23:16] <= rx_byte;
                        // test.py: assert (st & 0x40) and not (st & 0x80).
                        // (0x50 here = HALTED + tx_empty bit4; exact 0x40 is wrong.)
                        // fault_lat inverts to expect RUNNING -> vacuity must fail.
                        if (fault_lat ? ((rx_byte & 8'h80) && !(rx_byte & 8'h40))
                                      : ((rx_byte & 8'h40) && !(rx_byte & 8'h80))) begin
                            milestones[M_HALTED] <= 1'b1;
`ifdef GENERIC_MODE
                            // Generic protocol proof is complete here:
                            // LOAD + byte-exact VERIFY + GO + RUNNING +
                            // TX drain + HALTED, with the folded signature.
                            // Skip the SPI-specific pin/TXFIFO checks.
                            tt_pass <= 1'b1;
                            done <= 1'b1;
                            st_r <= T_OK;
`else
                            st_r <= T_DR2_TX;
`endif
                        end else begin
                            // DIAG: HALT status mismatch. Drain TX FIFO,
                            // capture first 4 bytes in dbg1, count in
                            // dbg2[31:24], then fail 0xEE.
                            rxc <= 8'd0; txf_n <= 8'd0; dbg1 <= 32'd0;
                            st_r <= T_DG_TX;
                        end
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h0E);
                end
                // ============ pre-drain TX FIFO ============
                T_DR2_TX: tx_step(T_DR2_AK);
                T_DR2_AK: rx_ack(T_DR2_CNT, 8'h0F);
                T_DR2_CNT: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == 8'd0) begin
                            milestones[M_DRAIN2] <= 1'b1;
                            st_r <= T_XF_TX;
                        end else begin
                            dr_n <= rx_byte; rxc <= 8'd0;
                            st_r <= T_DR2_RX;
                        end
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h0F);
                end
                T_DR2_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        rxc <= rxc + 8'd1;
                        if (rxc + 8'd1 == dr_n) begin
                            milestones[M_DRAIN2] <= 1'b1;
                            st_r <= T_XF_TX;
                        end
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h0F);
                end
                // ============ WR_RXFIFO TRANSFER while halted ============
                T_XF_TX: tx_step(T_XF_AK);
                T_XF_AK: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rx_byte == 8'hA5) begin
                            milestones[M_XFER] <= 1'b1;
                            // arm pin recorder BEFORE the GO that wakes the PE
                            rec_run <= 1'b1; rec_saw_low <= 1'b0;
                            rec_sclk_prev <= 1'b0; rec_sclk_valid <= 1'b0;
                            rec_edge_cnt <= 8'd0; rec_mosi <= 16'd0;
                            rec_tcnt <= 18'd0;
                            rec_pulse_done <= 1'b0; rec_timeout <= 1'b0;
                            st_r <= T_GO2_TX;
                        end else do_fail(8'h10);
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h10);
                end
                // ============ GO (wake), capture CS# pulse ============
                T_GO2_TX: tx_step(T_GO2_AK);
                T_GO2_AK: rx_ack(T_REC_W, 8'h11);
                T_REC_W: begin
                    if (rec_pulse_done) begin
                        milestones[M_PULSE] <= 1'b1;
                        st_r <= T_REC_AN;
                    end else if (rec_timeout) begin
                        do_fail(8'h12);
                    end
                end
                T_REC_AN: begin
                    signature <= sig_fold(sig_fold(sig_fold(signature, rec_edge_cnt),
                                                   rec_mosi[15:8]), rec_mosi[7:0]);
                    if (rec_edge_cnt == 8'd16 && rec_mosi == 16'hA53C) begin
                        dbg1 <= {1'b1, 1'b1, 6'd0, rec_edge_cnt, rec_mosi};
                        milestones[M_SPIOK] <= 1'b1;
                        st_r <= T_TXF_TX;
                    end else begin
                        dbg1 <= {1'b1, 1'b0, 6'd0, rec_edge_cnt, rec_mosi};
                        do_fail(8'h13);
                    end
                end
                // ============ RD_TXFIFO results ============
                T_TXF_TX: tx_step(T_TXF_AK);
                T_TXF_AK: rx_ack(T_TXF_CNT, 8'h14);
                T_TXF_CNT: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        txf_n <= rx_byte; rxc <= 8'd0; byte_odd <= 1'b0;
                        txf_zeros <= 8'd0; zero_run <= 8'd0;
                        three_zero <= 1'b0; txf_bad <= 1'b0;
                        st_r <= (rx_byte == 8'd0) ? T_TXF_EVAL : T_TXF_RX;
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h14);
                end
                T_TXF_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (!byte_odd) begin
                            w_hi <= rx_byte; byte_odd <= 1'b1;
                        end else begin
                            if (w_hi == 8'h00 && rx_byte == 8'h00) begin
                                txf_zeros <= txf_zeros + 8'd1;
                                zero_run <= zero_run + 8'd1;
                                if (zero_run == 8'd2) three_zero <= 1'b1;
                            end else if (w_hi == 8'hFF && rx_byte == 8'hFF) begin
                                zero_run <= 8'd0;
                            end else begin
                                txf_bad <= 1'b1;
                                zero_run <= 8'd0;
                            end
                            byte_odd <= 1'b0;
                        end
                        rxc <= rxc + 8'd1;
                        if (rxc + 8'd1 == txf_n) st_r <= T_TXF_EVAL;
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'h14);
                end
                T_TXF_EVAL: begin
                    dbg2 <= {txf_n, txf_zeros, txf_bad, three_zero, 14'd0};
                    if (!txf_bad && three_zero) begin
                        milestones[M_TXFIFO] <= 1'b1;
                        tt_pass <= 1'b1;
                        done <= 1'b1;
                        st_r <= T_OK;
                    end else do_fail(8'h15);
                end
                T_DG_TX: tx_step(T_DG_AK);
                T_DG_AK: rx_ack(T_DG_CNT, 8'hEB);
                T_DG_CNT: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        txf_n <= rx_byte; rxc <= 8'd0;
                        st_r <= (rx_byte == 8'd0) ? T_DG_DONE : T_DG_RX;
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'hEC);
                end
                T_DG_RX: begin
                    tcnt <= tcnt + 18'd1;
                    if (rx_valid) begin
                        tcnt <= 18'd0;
                        if (rxc < 8'd4) dbg1 <= {dbg1[23:0], rx_byte};
                        rxc <= rxc + 8'd1;
                        if ((rxc + 8'd1 == txf_n) || (rxc + 8'd1 == 8'd8))
                            st_r <= T_DG_DONE;
                    end else if (tcnt == RX_TIMEOUT) do_fail(8'hED);
                end
                T_DG_DONE: begin
                    dbg2 <= {txf_n, 24'd0};
                    do_fail(8'hEE);
                end
                T_OK: begin
                    // hold; re-arm handled by the done branch above
                end
                default: st_r <= S_IDLE;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
