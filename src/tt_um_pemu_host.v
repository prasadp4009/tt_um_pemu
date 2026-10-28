// ============================================================================
// tt_um_pemu_host — Worker C: 2-wire host port + PE FIFOs + IMEM loader
//
// TEMPO-32 ASIC (Jane Street Protocol Emulator, IHP 130nm CMOS5L / Tiny
// Tapeout, 6x4). Implements the isa_v0.2.yaml `host_port` command set over
// a 2-wire framed serial link:
//
//   Frame: [CMD(8b)] [LEN(8b)] [DATA...] -> [ACK(8b)] [DATA...]
//
// Physical pins (see _phase6/intf_host.md): hp_rx = ui_in[0] (host->chip),
// hp_tx = uo_out[0] (chip->host). No HCLK pin fits the 2-pin budget, so the
// link is self-clocked: UART-style 10-bit frames (start + 8 data LSB-first
// + stop = 10 host bit-times/byte, matching the spec's "~10 host
// clocks/byte") with autobaud. The host MUST send 0x00 (NOP) as the first
// byte after reset or after >65535 core clocks of idle; the chip measures
// its 9-bit-time low pulse and sets Tbit = width/9 (clamped 16..4096,
// default 64).
//
// Block contents:
//   - RX/TX 16x16 FIFOs (host<->PE). Never stall the PE: TX push on full is
//     dropped, RX pull on empty returns 0 (golden model firmware/tools/sim.py).
//     TX_OVERRUN/RX_UNDERRUN stickies are set by the PE worker's PUSH/PULL
//     (T12); this block only provides tx_full/rx_empty.
//   - PROG-mode IMEM loader: LOAD_IMEM streams 32-bit words MSB-first via
//     prog_addr/prog_din/prog_wen (full-word writes, 1 cycle/word).
//     prog_mode=1 holds the PE in reset (integrator); GO clears it.
//   - Trace readout: RD_TRACE drives host_rd_en/host_rd_addr into the
//     Observer's trace SRAM and serializes the 5-byte entries MSB-first.
//   - RD_STATUS byte, event-flag capture (evt_code/evt_pulse).
//
// Known spec deviations (all documented in _phase6/intf_host.md):
//   WR_CFG/RD_CFG -> NACK_ERR (no config interface in the port list);
//   no host EVTFLAG-clear command exists in v0.2.
// [AMD-B] Worker D amendments (clear the remaining deviations above):
//   VERIFY_IMEM 0x02 implemented (PROG-only; {addr_hi,addr_lo,nwords} ->
//   ACK_OK + nwords*4 bytes MSB-first via prog_ren/prog_dout, 1 read/cycle
//   + 1 macro latency); HALT_REQ 0x0A now drives `halt_req` to the PE
//   (high until GO / PROG-entry / reset); GO 0x09 from RUN issues a 2-cycle
//   prog_mode pulse that restarts the PE at PC=0; RD_STATUS bits 5/0 now
//   report `timeout_sticky`/`config_err`; tx_empty/rx_full exported.
// ============================================================================

`default_nettype none

module tt_um_pemu_host (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ena,
    // 2-wire host port pads (PHYS: hp_rx=ui_in[0], hp_tx=uo_out[0])
    input  wire        hp_rx,
    output wire        hp_tx,
    // PE TX FIFO (PE -> host)
    input  wire [15:0] tx_data,
    input  wire        tx_push,
    output wire        tx_full,
    // PE RX FIFO (host -> PE)
    output wire [15:0] rx_data,
    input  wire        rx_pull,
    output wire        rx_empty,
    // PE events -> host event flags
    input  wire [3:0]  evt_code,
    input  wire        evt_pulse,
    // IMEM loader (PE held in reset while prog_mode=1)
    output wire        prog_mode,
    output wire [8:0]  prog_addr,
    output wire [31:0] prog_din,
    output wire        prog_wen,
    output wire        prog_ren,       // [AMD-B] VERIFY_IMEM read enable -> PE
    input  wire [31:0] prog_dout,      // [AMD-B] IMEM readback for VERIFY_IMEM
    // trace readout -> Observer
    output wire        host_rd_en,
    output wire [9:0]  host_rd_addr,
    input  wire [7:0]  host_rd_data,
    input  wire        host_rd_ack,
    // status -> host status byte
    input  wire        pe_running,
    input  wire        pe_halted,
    input  wire [7:0]  obs_ptr,
    input  wire        trace_full,
    input  wire        trace_wm,
    // [AMD-B] PE control / status
    output wire        halt_req,       // [AMD-B] -> PE: halt at next boundary
    output wire        tx_empty,       // [AMD-B] -> PE (T7) + RD_STATUS bit4
    output wire        rx_full,        // [AMD-B] -> PE (T7) + RD_STATUS bit3
    input  wire        timeout_sticky, // [AMD-B] -> RD_STATUS bit5
    input  wire        config_err      // [AMD-B] -> RD_STATUS bit0
);

    // ------------------------------------------------------------------
    // Reset: async assert, synchronized deassert (ARCHITECTURE.md 3.8)
    // ------------------------------------------------------------------
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst = ~rst_sync[1];

    // ------------------------------------------------------------------
    // hp_rx input synchronizer (host clock domain -> core)
    // ------------------------------------------------------------------
    reg rx_m0, rx_m1, rx_m1d;
    always @(posedge clk) begin
        if (rst) begin
            rx_m0 <= 1'b1; rx_m1 <= 1'b1; rx_m1d <= 1'b1;
        end else begin
            rx_m0 <= hp_rx; rx_m1 <= rx_m0; rx_m1d <= rx_m1;
        end
    end
    wire rx_fall =  rx_m1d & ~rx_m1;
    // wire rx_rise = ~rx_m1d &  rx_m1;  // (unused: normal bytes sample on timers)

    // ------------------------------------------------------------------
    // RX bit engine: autobaud + 10-bit frames (start + 8b LSB + stop)
    // ------------------------------------------------------------------
    localparam [2:0] RX_IDLE  = 3'd0,
                     RX_SYNL  = 3'd1,  // measuring autobaud sync byte low width
                     RX_START = 3'd2,  // in start bit, waiting bit0 center
                     RX_SAMP  = 3'd3,  // sampling data bits
                     RX_STOP  = 3'd4,  // sampling stop bit
                     RX_BRK   = 3'd5;  // break: line stuck low, wait for high

    reg [2:0]  rx_st;
    reg [15:0] t_bit;        // host bit period in core clocks (autobaud)
    reg [16:0] low_cnt;      // low-pulse width counter (sync measure / break)
    reg [15:0] samp_t;       // sample timer
    reg [2:0]  bit_idx;
    reg [7:0]  rx_byte;
    reg        rx_valid;     // 1-cycle pulse: rx_byte ready
    reg        sync_armed;   // next byte is the autobaud sync (0x00 NOP)
    reg [15:0] idle_cnt;     // high-idle counter for sync re-arm

    wire [15:0] w_div9 = low_cnt[15:0] / 16'd9;

    always @(posedge clk) begin
        if (rst) begin
            rx_st      <= RX_IDLE;
            t_bit      <= 16'd64;
            low_cnt    <= 17'd0;
            samp_t     <= 16'd0;
            bit_idx    <= 3'd0;
            rx_byte    <= 8'd0;
            rx_valid   <= 1'b0;
            sync_armed <= 1'b1;
            idle_cnt   <= 16'd0;
        end else begin
            rx_valid <= 1'b0;
            case (rx_st)
                RX_IDLE: begin
                    if (rx_m1) begin
                        if (idle_cnt != 16'hFFFF) idle_cnt <= idle_cnt + 16'd1;
                        else sync_armed <= 1'b1;   // long idle -> re-arm autobaud
                    end
                    if (rx_fall) begin
                        idle_cnt <= 16'd0;
                        low_cnt  <= 17'd0;
                        if (sync_armed) begin
                            rx_st <= RX_SYNL;
                        end else begin
                            samp_t <= (t_bit * 3) >> 1;  // bit0 center = 1.5*T
                            rx_st  <= RX_START;
                        end
                    end
                end
                RX_SYNL: begin
                    // Sync byte 0x00: low for start + 8 zero data bits = 9*T.
                    if (rx_m1) begin
                        if      (w_div9 < 16'd16)   t_bit <= 16'd16;
                        else if (w_div9 > 16'd4096) t_bit <= 16'd4096;
                        else                        t_bit <= w_div9;
                        sync_armed <= 1'b0;
                        rx_st      <= RX_IDLE;   // sync byte consumed as NOP
                    end else if (low_cnt == 17'h1FFFF) begin
                        t_bit      <= 16'd4096;
                        sync_armed <= 1'b0;
                        rx_st      <= RX_BRK;
                    end else begin
                        low_cnt <= low_cnt + 17'd1;
                    end
                end
                RX_START: begin
                    if (samp_t == 16'd0) begin
                        rx_byte[0] <= rx_m1;
                        bit_idx    <= 3'd1;
                        samp_t     <= t_bit;
                        rx_st      <= RX_SAMP;
                    end else begin
                        samp_t <= samp_t - 16'd1;
                    end
                end
                RX_SAMP: begin
                    if (samp_t == 16'd0) begin
                        rx_byte[bit_idx] <= rx_m1;
                        samp_t <= t_bit;
                        if (bit_idx == 3'd7) rx_st <= RX_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else begin
                        samp_t <= samp_t - 16'd1;
                    end
                end
                RX_STOP: begin
                    if (samp_t == 16'd0) begin
                        if (rx_m1) rx_valid <= 1'b1;  // else framing error: drop
                        rx_st <= RX_IDLE;
                    end else begin
                        samp_t <= samp_t - 16'd1;
                    end
                end
                RX_BRK: begin
                    if (rx_m1) rx_st <= RX_IDLE;
                end
                default: rx_st <= RX_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // TX bit engine: 10-bit frames at last measured t_bit, idle high
    // ------------------------------------------------------------------
    localparam [1:0] TX_IDLE = 2'd0, TX_SHIFT = 2'd1;
    reg [1:0]  tx_st;
    reg [9:0]  tx_sr;      // {stop, data[7:0], start}
    reg [3:0]  tx_bcnt;
    reg [15:0] tx_t;
    reg        tx_out;
    reg        tx_done;    // 1-cycle pulse at end of byte
    reg        tx_start;   // pulse from main FSM
    reg [7:0]  tx_byte;

    assign hp_tx = tx_out;

    always @(posedge clk) begin
        if (rst) begin
            tx_st   <= TX_IDLE;
            tx_out  <= 1'b1;
            tx_done <= 1'b0;
            tx_sr   <= 10'h3FF;
            tx_bcnt <= 4'd0;
            tx_t    <= 16'd0;
        end else begin
            tx_done <= 1'b0;
            case (tx_st)
                TX_IDLE: begin
                    tx_out <= 1'b1;
                    if (tx_start) begin
                        tx_sr  <= {1'b1, tx_byte, 1'b0};
                        tx_bcnt <= 4'd0;
                        tx_t   <= 16'd0;
                        tx_st  <= TX_SHIFT;
                    end
                end
                TX_SHIFT: begin
                    tx_out <= tx_sr[0];
                    if (tx_t == t_bit - 16'd1) begin
                        tx_t  <= 16'd0;
                        tx_sr <= {1'b1, tx_sr[9:1]};
                        if (tx_bcnt == 4'd9) begin
                            tx_st   <= TX_IDLE;
                            tx_done <= 1'b1;
                            tx_out  <= 1'b1;
                        end else begin
                            tx_bcnt <= tx_bcnt + 4'd1;
                        end
                    end else begin
                        tx_t <= tx_t + 16'd1;
                    end
                end
                default: tx_st <= TX_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // TX FIFO (PE -> host), 16x16. Never stalls: push on full is dropped.
    // ------------------------------------------------------------------
    reg [15:0] tx_mem [0:15];
    reg [3:0]  tx_wptr, tx_rptr;
    reg [4:0]  tx_cnt;
    reg        tx_rd_en;   // host-side pop strobe (main FSM)

    wire tx_push_ok = tx_push & (tx_cnt < 5'd16);
    wire tx_pop_ok  = tx_rd_en & (tx_cnt > 5'd0);
    wire [15:0] tx_rd_word = tx_mem[tx_rptr];
    wire tx_empty_f = (tx_cnt == 5'd0);

    assign tx_full = (tx_cnt == 5'd16);

    always @(posedge clk) begin
        if (rst) begin
            tx_wptr <= 4'd0; tx_rptr <= 4'd0; tx_cnt <= 5'd0;
        end else begin
            if (tx_push_ok) tx_mem[tx_wptr] <= tx_data;
            case ({tx_push_ok, tx_pop_ok})
                2'b10: begin tx_wptr <= tx_wptr + 4'd1; tx_cnt <= tx_cnt + 5'd1; end
                2'b01: begin tx_rptr <= tx_rptr + 4'd1; tx_cnt <= tx_cnt - 5'd1; end
                2'b11: begin tx_wptr <= tx_wptr + 4'd1; tx_rptr <= tx_rptr + 4'd1; end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // RX FIFO (host -> PE), 16x16. Never stalls: pull on empty -> 0.
    // ------------------------------------------------------------------
    reg [15:0] rx_mem [0:15];
    reg [3:0]  rx_wptr, rx_rptr;
    reg [4:0]  rx_cnt;
    reg        rx_fw_en;    // host-side push strobe (main FSM)
    reg [15:0] rx_fw_data;

    wire rx_push_ok = rx_fw_en & (rx_cnt < 5'd16);
    wire rx_pop_ok  = rx_pull & (rx_cnt > 5'd0);

    assign rx_empty = (rx_cnt == 5'd0);
    assign rx_data  = (rx_cnt == 5'd0) ? 16'h0000 : rx_mem[rx_rptr];
    wire rx_full_f = (rx_cnt == 5'd16);

    always @(posedge clk) begin
        if (rst) begin
            rx_wptr <= 4'd0; rx_rptr <= 4'd0; rx_cnt <= 5'd0;
        end else begin
            if (rx_push_ok) rx_mem[rx_wptr] <= rx_fw_data;
            case ({rx_push_ok, rx_pop_ok})
                2'b10: begin rx_wptr <= rx_wptr + 4'd1; rx_cnt <= rx_cnt + 5'd1; end
                2'b01: begin rx_rptr <= rx_rptr + 4'd1; rx_cnt <= rx_cnt - 5'd1; end
                2'b11: begin rx_wptr <= rx_wptr + 4'd1; rx_rptr <= rx_rptr + 4'd1; end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Event flags: PE raises via evt_code/evt_pulse.
    // v0.2 defines no host-port clear command -> cleared only by rst.
    // (Write-only until the integrator adds a read/clear path; the lint
    //  waiver below documents the intent.)
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSED */
    reg [15:0] evt_flags;
    /* verilator lint_on UNUSED */
    always @(posedge clk) begin
        if (rst) evt_flags <= 16'h0000;
        else if (evt_pulse) evt_flags[evt_code] <= 1'b1;
    end

    // ------------------------------------------------------------------
    // Main command FSM
    // ------------------------------------------------------------------
    localparam [5:0]
        S_IDLE  = 6'd0,   // wait CMD byte
        S_LEN   = 6'd1,   // wait LEN byte, dispatch
        S_DISC  = 6'd2,   // discard LEN bytes, no response (NOP)
        S_DISCN = 6'd3,   // discard LEN bytes, then NACK_ERR
        S_LDP   = 6'd4,   // LOAD_IMEM: validate LEN
        S_LDA   = 6'd5,   // LOAD_IMEM: 2 addr bytes
        S_LDD   = 6'd6,   // LOAD_IMEM: stream data bytes
        S_LDW   = 6'd7,   // LOAD_IMEM: assert prog_wen 1 cycle
        S_WRX   = 6'd8,   // WR_RXFIFO: stream bytes -> words
        S_RTMC  = 6'd9,   // RD_TXFIFO: get max_count
        S_RTSB  = 6'd10,  // RD_TXFIFO: send ret_count
        S_RTSP  = 6'd11,  // RD_TXFIFO: pop word
        S_RTSH  = 6'd12,  // RD_TXFIFO: send hi byte
        S_RTSL  = 6'd13,  // RD_TXFIFO: send lo byte
        S_RSI   = 6'd14,  // RD_TRACE: get start_idx
        S_RCT   = 6'd15,  // RD_TRACE: get count
        S_RPRE  = 6'd16,  // RD_TRACE: latch PTR_SNAP, compute ret
        S_RTRC  = 6'd17,  // RD_TRACE: send ret_count
        S_RTRD  = 6'd18,  // RD_TRACE: SRAM read + wait ack
        S_RTRN  = 6'd19,  // RD_TRACE: next byte/entry bookkeeping
        S_RTRP  = 6'd20,  // RD_TRACE: send OBS_PTR
        S_ST1   = 6'd21,  // RD_STATUS: send status byte
        S_TXB   = 6'd22,  // byte-sender: present byte, start TX
        S_TXW   = 6'd23,  // byte-sender: wait tx_done -> snd_ret
        // [AMD-B] VERIFY_IMEM states
        S_VFAD  = 6'd24,  // VERIFY: addr_hi byte
        S_VFAD2 = 6'd25,  // VERIFY: addr_lo byte
        S_VFNW  = 6'd26,  // VERIFY: nwords byte + range check
        S_VF0   = 6'd27,  // VERIFY: present addr, assert prog_ren
        S_VF1   = 6'd28,  // VERIFY: macro latch cycle
        S_VF2   = 6'd29,  // VERIFY: sample prog_dout
        S_VF3   = 6'd30,  // VERIFY: send byte[31:24]
        S_VF4   = 6'd31,  // VERIFY: send byte[23:16]
        S_VF5   = 6'd32,  // VERIFY: send byte[15:8]
        S_VF6   = 6'd33,  // VERIFY: send byte[7:0]
        S_GOP   = 6'd34;  // GO: 2-cycle prog_mode pulse (RUN restart)

    localparam [7:0] ACK_OK = 8'hA5, NACK_ERR = 8'h5B;
    // NOTE: NACK_BUSY (8'h5A) is defined by the ISA but this block never
    // sends it: the dictated observer interface exposes no writer-side
    // saturation condition to NACK on (documented deviation).

    reg [5:0]  m_st, snd_ret;
    reg [7:0]  cmd_r, len_r, snd_byte;
    reg [10:0] dcnt;          // discard / data byte counter
    // LOAD_IMEM
    reg [7:0]  nwords, widx;
    reg [8:0]  addr9;
    reg [7:0]  addr_hi;
    reg        abyte;         // 0/1 addr bytes received
    reg [1:0]  wbyte;
    reg [31:0] wacc;
    reg [10:0] dleft;         // data bytes remaining
    // WR_RXFIFO
    reg [7:0]  rxw_acc;
    reg        rxw_half;
    // RD_TXFIFO
    reg [7:0]  rtx_ret;
    reg [8:0]  rtx_left;
    reg [15:0] rtx_word;
    // RD_TRACE
    reg [7:0]  rtr_si, rtr_ct, rtr_e, ptr_snap;
    reg [4:0]  rtr_left;
    reg [2:0]  rtr_b;
    reg [7:0]  sram_to;
    // outputs
    reg        prog_mode_r, ena_d;
    reg [8:0]  prog_addr_r;
    reg [31:0] prog_din_r;
    reg        prog_wen_r;
    // [AMD-B] VERIFY_IMEM / HALT_REQ / GO-pulse
    reg        prog_ren_r;
    reg        halt_req_r;
    reg [1:0]  go_cnt;
    reg [7:0]  vaddr_hi, vaddr_lo, vnwords, vrem;
    reg [8:0]  vcur;
    reg [31:0] vwacc;
    reg        vmore;
    reg        host_rd_en_r;
    reg [9:0]  host_rd_addr_r;

    assign prog_mode    = prog_mode_r;
    assign prog_addr    = prog_addr_r;
    assign prog_din     = prog_din_r;
    assign prog_wen     = prog_wen_r;
    assign prog_ren     = prog_ren_r;
    assign halt_req     = halt_req_r;
    assign tx_empty     = tx_empty_f;
    assign rx_full      = rx_full_f;
    assign host_rd_en   = host_rd_en_r;
    assign host_rd_addr = host_rd_addr_r;

    // [AMD-B] TIMEOUT/CONFIG_ERR now come from PE status inputs
    wire [7:0] status_byte = {pe_running, pe_halted, timeout_sticky,
                              tx_empty_f, rx_full_f,
                              trace_wm, trace_full,
                              config_err};

    // (WR_RXFIFO space check is computed inline in S_LEN from rx_byte.)

    always @(posedge clk) begin
        if (rst) begin
            m_st <= S_IDLE; snd_ret <= S_IDLE;
            cmd_r <= 8'd0; len_r <= 8'd0; snd_byte <= 8'd0;
            dcnt <= 11'd0; dleft <= 11'd0;
            nwords <= 8'd0; widx <= 8'd0; addr9 <= 9'd0; addr_hi <= 8'd0;
            abyte <= 1'b0; wbyte <= 2'd0; wacc <= 32'd0;
            rxw_acc <= 8'd0; rxw_half <= 1'b0;
            rtx_ret <= 8'd0; rtx_left <= 9'd0; rtx_word <= 16'd0;
            rtr_si <= 8'd0; rtr_ct <= 8'd0; rtr_e <= 8'd0; ptr_snap <= 8'd0;
            rtr_left <= 5'd0; rtr_b <= 3'd0; sram_to <= 8'd0;
            prog_mode_r <= 1'b1;   // power-on = PROG (PE held in reset)
            ena_d <= 1'b1;
            prog_addr_r <= 9'd0; prog_din_r <= 32'd0; prog_wen_r <= 1'b0;
            prog_ren_r <= 1'b0; halt_req_r <= 1'b0; go_cnt <= 2'd0;
            vaddr_hi <= 8'd0; vaddr_lo <= 8'd0; vnwords <= 8'd0;
            vcur <= 9'd0; vrem <= 8'd0; vwacc <= 32'd0; vmore <= 1'b0;
            host_rd_en_r <= 1'b0; host_rd_addr_r <= 10'd0;
            tx_start <= 1'b0; tx_byte <= 8'd0;
            tx_rd_en <= 1'b0; rx_fw_en <= 1'b0; rx_fw_data <= 16'd0;
        end else begin
            // pulse defaults
            tx_start   <= 1'b0;
            tx_rd_en   <= 1'b0;
            rx_fw_en   <= 1'b0;
            prog_wen_r <= 1'b0;
            prog_ren_r <= 1'b0;   // re-asserted by S_VF0/S_VF1 when needed
            host_rd_en_r <= 1'b0;
            ena_d <= ena;

            case (m_st)
                // --------------------------------------------------
                S_IDLE: begin
                    if (rx_valid) begin
                        cmd_r <= rx_byte;
                        m_st  <= S_LEN;
                    end
                end
                // --------------------------------------------------
                S_LEN: begin
                    if (rx_valid) begin
                        len_r <= rx_byte;
                        case (cmd_r)
                            8'h00: begin  // NOP: consume, no response
                                if (rx_byte == 8'd0) m_st <= S_IDLE;
                                else begin dcnt <= {3'd0, rx_byte}; m_st <= S_DISC; end
                            end
                            8'h01: begin  // LOAD_IMEM
                                if (!prog_mode_r) begin
                                    if (rx_byte == 8'd0) begin
                                        snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                    end else begin
                                        dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                    end
                                end else m_st <= S_LDP;
                            end
                            8'h02: begin  // [AMD-B] VERIFY_IMEM: PROG-only readback
                                // NOTE: rejections must consume the payload via S_DISCN
                                // before NACKing, or the byte stream desynchronizes.
                                if (!prog_mode_r || rx_byte != 8'd3) begin
                                    dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                end else m_st <= S_VFAD;
                            end
                            8'h03, 8'h04: begin  // WR_CFG/RD_CFG: unsupported
                                if (rx_byte == 8'd0) begin
                                    snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                end else begin
                                    dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                end
                            end
                            8'h05: begin  // WR_RXFIFO
                                if (prog_mode_r) begin
                                    if (rx_byte == 8'd0) begin
                                        snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                    end else begin
                                        dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                    end
                                end else if ({4'd0, rx_cnt} + ((({1'b0, rx_byte} + 9'd1) >> 1)) > 9'd16) begin
                                    // all-or-nothing: insufficient space
                                    if (rx_byte == 8'd0) begin
                                        snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                    end else begin
                                        dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                    end
                                end else begin
                                    dcnt <= {3'd0, rx_byte};
                                    rxw_acc <= 8'd0; rxw_half <= 1'b0;
                                    m_st <= S_WRX;
                                end
                            end
                            8'h06: begin  // RD_TXFIFO
                                if (prog_mode_r || rx_byte != 8'd1) begin
                                    if (rx_byte == 8'd0) begin
                                        snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                    end else begin
                                        dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                    end
                                end else m_st <= S_RTMC;
                            end
                            8'h07: begin  // RD_TRACE
                                if (prog_mode_r || rx_byte != 8'd2) begin
                                    if (rx_byte == 8'd0) begin
                                        snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                    end else begin
                                        dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                    end
                                end else m_st <= S_RSI;
                            end
                            8'h08: begin  // RD_STATUS
                                if (rx_byte == 8'd0) begin
                                    snd_byte <= ACK_OK; snd_ret <= S_ST1; m_st <= S_TXB;
                                end else begin
                                    dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                end
                            end
                            8'h09: begin  // GO (+ [AMD-B] RUN-restart pulse)
                                if (rx_byte == 8'd0) begin
                                    halt_req_r <= 1'b0;  // [AMD-B] GO drops HALT_REQ
                                    if (prog_mode_r) begin
                                        prog_mode_r <= 1'b0;  // PROG->RUN: release reset, PC<-0
                                        snd_byte <= ACK_OK; snd_ret <= S_IDLE; m_st <= S_TXB;
                                    end else begin
                                        // RUN->RUN: 2-cycle prog_mode pulse restarts PE at PC=0
                                        prog_mode_r <= 1'b1;
                                        go_cnt <= 2'd2;
                                        m_st <= S_GOP;
                                    end
                                end else begin
                                    dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                end
                            end
                            8'h0A: begin  // [AMD-B] HALT_REQ: drives halt_req
                                if (prog_mode_r || rx_byte != 8'd0) begin
                                    if (rx_byte == 8'd0) begin
                                        snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                    end else begin
                                        dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                    end
                                end else begin
                                    halt_req_r <= 1'b1;  // stays high until GO/PROG-entry/rst
                                    snd_byte <= ACK_OK; snd_ret <= S_IDLE; m_st <= S_TXB;
                                end
                            end
                            default: begin  // unknown CMD -> NACK_ERR
                                if (rx_byte == 8'd0) begin
                                    snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                                end else begin
                                    dcnt <= {3'd0, rx_byte}; m_st <= S_DISCN;
                                end
                            end
                        endcase
                    end
                end
                // --------------------------------------------------
                S_DISC: begin  // discard bytes, no response
                    if (rx_valid) begin
                        if (dcnt == 11'd1) m_st <= S_IDLE;
                        else dcnt <= dcnt - 11'd1;
                    end
                end
                S_DISCN: begin  // discard bytes, then NACK_ERR
                    if (rx_valid) begin
                        if (dcnt == 11'd1) begin
                            snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                        end else dcnt <= dcnt - 11'd1;
                    end
                end
                // --------------------------------------------------
                // LOAD_IMEM
                S_LDP: begin
                    if (len_r < 8'd2 || len_r[1:0] != 2'b10) begin
                        dcnt <= {3'd0, len_r}; m_st <= S_DISCN;
                    end else begin
                        nwords <= (len_r - 8'd2) >> 2;
                        dleft  <= {3'd0, len_r} - 11'd2;
                        abyte  <= 1'b0; addr_hi <= 8'd0;
                        m_st   <= S_LDA;
                    end
                end
                S_LDA: begin
                    if (rx_valid) begin
                        // MSB-first: first byte = addr[15:8]
                        if (abyte == 1'b0) begin
                            addr_hi <= rx_byte;
                            abyte  <= 1'b1;
                        end else begin
                            // full addr = {addr_hi, rx_byte} (16-bit);
                            // IMEM is 512 words, so the span
                            // [addr, addr + nwords) must satisfy
                            // addr + nwords <= 512.
                            if (({1'b0, addr_hi, rx_byte} + {9'd0, nwords}) > 17'd512) begin
                                dcnt <= dleft; m_st <= S_DISCN;
                            end else begin
                                addr9 <= {addr_hi[0], rx_byte};
                                widx <= 8'd0; wbyte <= 2'd0; wacc <= 32'd0;
                                if (dleft == 11'd0) begin
                                    // LEN=2: zero data words -> ACK now
                                    snd_byte <= ACK_OK; snd_ret <= S_IDLE;
                                    m_st <= S_TXB;
                                end else m_st <= S_LDD;
                            end
                        end
                    end
                end
                S_LDD: begin
                    if (rx_valid) begin
                        wacc  <= {wacc[23:0], rx_byte};
                        dleft <= dleft - 11'd1;
                        if (wbyte == 2'd3) m_st <= S_LDW;
                        else wbyte <= wbyte + 2'd1;
                    end
                end
                S_LDW: begin
                    prog_addr_r <= addr9 + {1'b0, widx};
                    prog_din_r  <= wacc;
                    prog_wen_r  <= 1'b1;   // 1 cycle, full-word write
                    if (dleft == 11'd0) begin
                        snd_byte <= ACK_OK; snd_ret <= S_IDLE; m_st <= S_TXB;
                    end else begin
                        widx <= widx + 8'd1; wbyte <= 2'd0; wacc <= 32'd0;
                        m_st <= S_LDD;
                    end
                end
                // --------------------------------------------------
                // WR_RXFIFO: bytes -> 16-bit words, MSB-first, odd pads 0x00
                S_WRX: begin
                    if (dcnt == 11'd0) begin
                        if (rxw_half) begin
                            rx_fw_data <= {rxw_acc, 8'h00};
                            rx_fw_en   <= 1'b1;
                        end
                        snd_byte <= ACK_OK; snd_ret <= S_IDLE; m_st <= S_TXB;
                    end else if (rx_valid) begin
                        dcnt <= dcnt - 11'd1;
                        if (rxw_half) begin
                            // word complete: {prev_byte, this_byte}
                            rx_fw_data <= {rxw_acc, rx_byte};
                            rx_fw_en   <= 1'b1;
                        end else begin
                            rxw_acc <= rx_byte;
                        end
                        rxw_half <= ~rxw_half;
                    end
                end
                // --------------------------------------------------
                // RD_TXFIFO
                S_RTMC: begin
                    if (rx_valid) begin
                        // avail bytes = tx_cnt*2; ret = min(max_count, avail)
                        if ({1'b0, rx_byte} < ({4'd0, tx_cnt} << 1))
                            rtx_ret <= rx_byte;
                        else
                            rtx_ret <= {2'b00, tx_cnt, 1'b0};  // tx_cnt*2 <= 32
                        rtx_left <= ({1'b0, rx_byte} < ({4'd0, tx_cnt} << 1))
                                    ? {1'b0, rx_byte} : ({4'd0, tx_cnt} << 1);
                        snd_byte <= ACK_OK; snd_ret <= S_RTSB; m_st <= S_TXB;
                    end
                end
                S_RTSB: begin
                    snd_byte <= rtx_ret; snd_ret <= S_RTSP; m_st <= S_TXB;
                end
                S_RTSP: begin
                    if (rtx_left == 9'd0) m_st <= S_IDLE;
                    else begin
                        tx_rd_en <= 1'b1;
                        rtx_word <= tx_rd_word;
                        m_st <= S_RTSH;
                    end
                end
                S_RTSH: begin
                    snd_byte <= rtx_word[15:8];
                    rtx_left <= rtx_left - 9'd1;
                    snd_ret <= S_RTSL; m_st <= S_TXB;
                end
                S_RTSL: begin
                    if (rtx_left == 9'd0) m_st <= S_RTSP;
                    else begin
                        snd_byte <= rtx_word[7:0];
                        rtx_left <= rtx_left - 9'd1;
                        snd_ret <= S_RTSP; m_st <= S_TXB;
                    end
                end
                // --------------------------------------------------
                // RD_TRACE
                S_RSI: begin
                    if (rx_valid) begin rtr_si <= rx_byte; m_st <= S_RCT; end
                end
                S_RCT: begin
                    if (rx_valid) begin rtr_ct <= rx_byte; m_st <= S_RPRE; end
                end
                S_RPRE: begin
                    ptr_snap <= obs_ptr;   // PTR_SNAP at decode
                    if (rtr_ct > 8'd16) begin
                        snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                    end else begin
                        // ret = min(count, max(0, PTR_SNAP - start_idx)).
                        // count <= 16 here, so the result fits rtr_left.
                        if (rtr_si >= obs_ptr) rtr_left <= 5'd0;
                        else if ({1'b0, rtr_ct} < ({1'b0, obs_ptr} - {1'b0, rtr_si}))
                            rtr_left <= rtr_ct[4:0];
                        else
                            rtr_left <= 5'(obs_ptr - rtr_si);
                        rtr_e <= rtr_si;
                        snd_byte <= ACK_OK; snd_ret <= S_RTRC; m_st <= S_TXB;
                    end
                end
                S_RTRC: begin
                    snd_byte <= {3'd0, rtr_left}; snd_ret <= S_RTRD; m_st <= S_TXB;
                    rtr_b <= 3'd0;
                    if (rtr_left == 5'd0) snd_ret <= S_RTRP;  // no entries: send PTR next
                end
                S_RTRD: begin
                    host_rd_en_r   <= 1'b1;
                    host_rd_addr_r <= rtr_e * 8'd5 + {7'd0, rtr_b};
                    if (host_rd_ack) begin
                        sram_to  <= 8'd0;
                        snd_byte <= host_rd_data;
                        snd_ret  <= S_RTRN;
                        m_st     <= S_TXB;
                    end else if (sram_to == 8'd255) begin
                        // ack timeout: abort frame, host retries
                        m_st <= S_IDLE;
                    end else begin
                        sram_to <= sram_to + 8'd1;
                    end
                end
                S_RTRN: begin
                    if (rtr_b == 3'd4) begin
                        rtr_b <= 3'd0;
                        rtr_e <= rtr_e + 8'd1;
                        if (rtr_left == 5'd1) begin
                            rtr_left <= 5'd0;
                            m_st <= S_RTRP;
                        end else begin
                            rtr_left <= rtr_left - 5'd1;
                            m_st <= S_RTRD;
                        end
                    end else begin
                        rtr_b <= rtr_b + 3'd1;
                        m_st <= S_RTRD;
                    end
                end
                S_RTRP: begin
                    snd_byte <= ptr_snap; snd_ret <= S_IDLE; m_st <= S_TXB;
                end
                // --------------------------------------------------
                S_ST1: begin
                    snd_byte <= status_byte; snd_ret <= S_IDLE; m_st <= S_TXB;
                end
                // --------------------------------------------------
                // [AMD-B] VERIFY_IMEM: one IMEM read per cycle + macro latency
                S_VFAD: begin
                    if (rx_valid) begin vaddr_hi <= rx_byte; m_st <= S_VFAD2; end
                end
                S_VFAD2: begin
                    if (rx_valid) begin vaddr_lo <= rx_byte; m_st <= S_VFNW; end
                end
                S_VFNW: begin
                    if (rx_valid) begin
                        vnwords <= rx_byte;
                        // range check: full 16-bit base {vaddr_hi, vaddr_lo};
                        // the span [base, base+nwords) must fit 512 words
                        if (({1'b0, vaddr_hi, vaddr_lo} + {9'd0, rx_byte}) > 17'd512) begin
                            snd_byte <= NACK_ERR; snd_ret <= S_IDLE; m_st <= S_TXB;
                        end else begin
                            vcur <= {vaddr_hi[0], vaddr_lo}; vrem <= rx_byte;
                            snd_byte <= ACK_OK;
                            snd_ret <= (rx_byte == 8'd0) ? S_IDLE : S_VF0;
                            m_st <= S_TXB;
                        end
                    end
                end
                S_VF0: begin
                    prog_addr_r <= vcur;   // present read address
                    prog_ren_r  <= 1'b1;   // macro latches it at this edge
                    m_st <= S_VF1;
                end
                S_VF1: begin
                    prog_ren_r <= 1'b1;    // hold through the latch edge
                    m_st <= S_VF2;
                end
                S_VF2: begin
                    vwacc <= prog_dout;    // DOUT valid: addr latched 2 edges ago
                    if (vrem == 8'd1) begin
                        vmore <= 1'b0;
                    end else begin
                        vcur <= vcur + 9'd1; vrem <= vrem - 8'd1; vmore <= 1'b1;
                    end
                    m_st <= S_VF3;
                end
                S_VF3: begin
                    snd_byte <= vwacc[31:24]; snd_ret <= S_VF4; m_st <= S_TXB;
                end
                S_VF4: begin
                    snd_byte <= vwacc[23:16]; snd_ret <= S_VF5; m_st <= S_TXB;
                end
                S_VF5: begin
                    snd_byte <= vwacc[15:8];  snd_ret <= S_VF6; m_st <= S_TXB;
                end
                S_VF6: begin
                    snd_byte <= vwacc[7:0];
                    snd_ret <= vmore ? S_VF0 : S_IDLE; m_st <= S_TXB;
                end
                // --------------------------------------------------
                // [AMD-B] GO from RUN: hold prog_mode high 2 cycles, then drop
                S_GOP: begin
                    if (go_cnt == 2'd0) begin
                        prog_mode_r <= 1'b0;   // PE sees 1->0 -> GO, PC<-0
                        snd_byte <= ACK_OK; snd_ret <= S_IDLE; m_st <= S_TXB;
                    end else begin
                        go_cnt <= go_cnt - 2'd1;
                    end
                end
                // --------------------------------------------------
                // byte-sender subroutine
                S_TXB: begin
                    tx_byte  <= snd_byte;
                    tx_start <= 1'b1;
                    m_st     <= S_TXW;
                end
                S_TXW: begin
                    if (tx_done) m_st <= snd_ret;
                end
                default: m_st <= S_IDLE;
            endcase

            // ena 1->0 re-enters PROG (wins over GO in the same cycle)
            if (ena_d && !ena) begin
                prog_mode_r <= 1'b1;
                halt_req_r  <= 1'b0;   // [AMD-B] PROG-entry drops HALT_REQ
            end
        end
    end

endmodule
