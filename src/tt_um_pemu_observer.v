// =============================================================================
// tt_um_pemu_observer.v -- TEMPO-32 Observer capture engine + trace SRAM port
//
// Worker B, TEMPO ASIC RTL phase (Jane Street Protocol Emulator, IHP 130nm).
// Single-writer file. Interface contract:
//   ~/workspace/janestreet-pemu/_phase6/intf_observer.md
// Normative refs: ISA_v0.2.md section 6, isa_v0.2.yaml (observer,
// observer_edge_packing), SRAM_TRIAL.md section 3, firmware/tools/sim.py
// (Observer golden behavior).
//
// Function:
//   - Evaluates the configured trigger (EDGE/PATTERN/PULSE) every core cycle
//     on the 2-FF synchronized pin vector.
//   - On trigger, latches {timestamp[31:0], pins[7:0]} and commits it as five
//     consecutive macro bytes (ts[31:24], ts[23:16], ts[15:8], ts[7:0], pins)
//     at rows 5*i..5*i+4. Trigger -> commit <= K=6 core cycles (T17).
//   - Trigger bursts faster than 1/5 cycles coalesce latest-wins through a
//     1-deep pending latch (spec section 6 / R-13).
//   - OBS_PTR saturates at 204 (never wraps); on full, triggers are ignored
//     and a trace_full event strobe fires (PE latches STATUS[3]).
//   - Watermark: the commit that makes OBS_PTR == WMARK (WMARK != 0) fires a
//     one-cycle trace_wm strobe (PE latches STATUS[12]; PE auto-clears on
//     OBS_CLR since it owns the OBS_CTL decode).
//   - Host readout: allowed any time, including during capture (YAML
//     read_trace.busy_rule overrules the brief's obs_en==0 guard). Capture
//     writes ALWAYS win the single macro port; host reads are served in
//     port-idle cycles with the ack delayed accordingly (never dropped while
//     held, never out-of-order). A committed entry's 5 bytes are never
//     rewritten: append-only, saturating pointer.
//
// Q4 compliance: NO PE<->trace data path. Trace bytes leave this block only
// through tmem_* (SRAM macro) and host_rd_* (host port). The PE sees only
// obs_ptr / trace_full / trace_wm.
// =============================================================================

`default_nettype none

module tt_um_pemu_observer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ena,

    // -- trigger source (PE / pin fabric) --
    input  wire [31:0] cycles,          // prescaled 32-bit timestamp (PE-owned)
    input  wire [7:0]  pins_sync,       // 2-FF synchronized pins (T5)

    // -- observer configuration (decoded register values, PE/top-owned) --
    input  wire [1:0]  trig_mode,       // M1: 00=DIS 01=EDGE 10=PATTERN 11=PULSE
    input  wire        trig_wr_strobe,  // 1-cycle pulse: TRIG_MODE was written
    input  wire [7:0]  edge_mask,       // EDGE_MASK
    input  wire [15:0] edge_cfg,        // {EDGE_CFG1, EDGE_CFG0}, pin-major 2b
    input  wire [7:0]  pat_mask,        // MASK
    input  wire [7:0]  pat_value,       // VALUE
    input  wire [2:0]  pin_sel,         // PIN_SEL (PULSE pin); see intf doc
    input  wire [7:0]  wmark,           // WMARK (0 = disabled)
    input  wire [7:0]  prescaler,       // PRESCALER, shared; [1:0] valid
    input  wire        obs_en,          // OBS_CTL[0]
    input  wire        obs_clr,         // OBS_CTL[2] W1C strobe

    // -- status to PE (single-cycle event strobes) --
    output wire [7:0]  obs_ptr,         // valid entries, 0..204, saturates
    output wire        trace_full,      // strobe: trigger ignored, trace full
    output wire        trace_wm,        // strobe: commit reached WMARK

    // -- trace SRAM macro port (single; mapping in intf doc section 5) --
    output wire [9:0]  tmem_addr,
    output wire        tmem_men,
    output wire        tmem_ren,
    output wire        tmem_wen,
    output wire [7:0]  tmem_din,
    output wire [7:0]  tmem_bm,
    input  wire [7:0]  tmem_dout,

    // -- host readout (any time incl. during capture; see intf doc section 6) --
    input  wire        host_rd_en,
    input  wire [9:0]  host_rd_addr,
    output wire [7:0]  host_rd_data,
    output wire        host_rd_ack
);

    // ------------------------------------------------------------------
    // prescaler is informational: `cycles` arrives from the PE already
    // divided by the shared prescaler (ISA section 4 PRESCALER, R-8). Only
    // [1:0] are architecturally valid; the value is not used by this block.
    // ------------------------------------------------------------------
    // verilator lint_off UNUSEDSIGNAL
    wire [7:0] prescaler_unused = prescaler;
    // verilator lint_on UNUSEDSIGNAL

    // ------------------------------------------------------------------
    // Trigger evaluation (combinational, per core cycle)
    // ------------------------------------------------------------------
    reg [7:0] prev_pins;

    wire eval_en = ena & obs_en & ~trig_wr_strobe & (trig_mode != 2'b00);

    // EDGE: pin i fires iff EDGE_MASK[i]=1, edge code != 00, selected edge.
    wire [7:0] edge_hit;
    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_edge
            wire [1:0] ecfg = edge_cfg[2*gi+1 : 2*gi];
            wire       een  = edge_mask[gi] & (ecfg != 2'b00);
            wire       ris  =  pins_sync[gi] & ~prev_pins[gi];
            wire       fal  = ~pins_sync[gi] &  prev_pins[gi];
            assign edge_hit[gi] = een & ( (ecfg == 2'b01) & ris
                                        | (ecfg == 2'b10) & fal
                                        | (ecfg == 2'b11) & (ris | fal) );
        end
    endgenerate
    wire edge_fire = |edge_hit;

    // PATTERN: level-triggered, fires every cycle while the match holds.
    // (pins & MASK) == (VALUE & MASK), exactly as the sim.py golden model.
    wire pattern_fire = ((pins_sync & pat_mask) == (pat_value & pat_mask));

    // PULSE: any edge on the PIN_SEL pin commits.
    // T4 (owner: observer designer): the falling-edge "disarm" ends the pulse
    // measurement; obs_en is NOT modified (no port exists for it); the next
    // rising edge re-arms and commits. Observationally this is
    // commit-on-every-edge, identical to the sim.py golden model.
    wire pulse_fire = pins_sync[pin_sel] ^ prev_pins[pin_sel];

    wire trig_fire = eval_en & ( (trig_mode == 2'b01) & edge_fire
                               | (trig_mode == 2'b10) & pattern_fire
                               | (trig_mode == 2'b11) & pulse_fire );

    // ------------------------------------------------------------------
    // Capture engine: 1-deep pending latch (latest-wins) + 5-byte commit.
    // Trigger (cycle T, inputs sampled at edge ending T) -> latch -> 5 macro
    // byte writes -> obs_ptr++ at the edge ending T+5: K = 6 cycles (T17).
    // ------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0,
                     S_B0   = 3'd1,
                     S_B1   = 3'd2,
                     S_B2   = 3'd3,
                     S_B3   = 3'd4,
                     S_B4   = 3'd5;

    reg [2:0]  cap_st;
    reg [31:0] pend_ts, wr_ts;
    reg [7:0]  pend_pins, wr_pins;
    reg        pend_valid;
    reg [7:0]  obs_ptr_r;
    reg        trace_full_r, trace_wm_r;

    wire cap_start_st   = (cap_st == S_IDLE) | (cap_st == S_B0);
    wire cap_start_fire = cap_start_st & pend_valid & (obs_ptr_r != 8'd204);
    wire pend_clr       = cap_start_st & pend_valid;

    // Byte source: byte 0 comes from the fresh pending latch, bytes 1..4
    // from the working registers captured at commit start.
    wire        src_is_pend = (cap_st == S_IDLE) | (cap_st == S_B0);
    wire [31:0] src_ts      = src_is_pend ? pend_ts  : wr_ts;
    wire [7:0]  src_pins    = src_is_pend ? pend_pins : wr_pins;

    wire [2:0] byte_idx = (cap_st == S_B4) ? 3'd4 :
                          (cap_st == S_B3) ? 3'd3 :
                          (cap_st == S_B2) ? 3'd2 :
                          (cap_st == S_B1) ? 3'd1 : 3'd0;

    wire [7:0] cap_din = (byte_idx == 3'd4) ? src_pins      :
                         (byte_idx == 3'd3) ? src_ts[7:0]   :
                         (byte_idx == 3'd2) ? src_ts[15:8]  :
                         (byte_idx == 3'd1) ? src_ts[23:16] : src_ts[31:24];

    // entry i -> rows 5*i..5*i+4; 5*ptr+idx, max 5*203+4 = 1019 < 1024.
    wire [9:0] ptr_times5 = ({2'b00, obs_ptr_r} << 2) + {2'b00, obs_ptr_r};
    wire [9:0] cap_addr   = ptr_times5 + {7'b0, byte_idx};

    wire cap_write = cap_start_fire
                   | (cap_st == S_B1) | (cap_st == S_B2)
                   | (cap_st == S_B3) | (cap_st == S_B4);

    // ------------------------------------------------------------------
    // Host readout: variable-latency, writer-priority (R4, YAML busy_rule).
    // Reads are allowed at any time, including during capture (obs_en == 1):
    // the trace SRAM is append-only with immutable committed entries, and the
    // host latches OBS_PTR at decode (PTR_SNAP, host block) and reads only
    // indices < PTR_SNAP, so entry data can never tear.
    //
    // Protocol: host asserts host_rd_en with host_rd_addr and holds both
    // until host_rd_ack. A request is recognized on the RISING edge of
    // host_rd_en (so a slow deassert after ack never restarts a read).
    // The request is served at the first port-idle cycle(s); capture writes
    // ALWAYS win the single macro port. If a capture write preempts the
    // read's address phase or data phase, the read retries from the address
    // phase (the macro's DOUT during a write is unspecified, so DOUT is only
    // sampled after an address phase immediately followed by a port-idle
    // cycle). Best case: ack 2 cycles after the request edge. Under writer
    // saturation no idle cycle appears and the ack is delayed indefinitely;
    // the host block times out at 256 core cycles and returns NACK_BUSY
    // (this block never NACKs and never drops a held request). If the host
    // deasserts host_rd_en before the ack (its timeout), the pending request
    // is aborted: no stale ack is ever produced, so acks can never go
    // out of order. obs_clr aborts any in-flight read.
    // Guarantee: a committed entry's 5 bytes are never rewritten by the
    // capture path (append-only, saturating pointer); the read path never
    // writes. (OBS_CLR is an explicit host-coordinated trace reset, not part
    // of the append-only capture path.)
    // ------------------------------------------------------------------
    localparam [1:0] R_IDLE = 2'd0,   // no pending request
                     R_PEND = 2'd1,   // request latched, waiting for ~cap_write
                     R_ADDR = 2'd2,   // macro address phase (REN)
                     R_DATA = 2'd3;   // capture DOUT + ack iff port stayed idle
    reg [1:0] rd_st;
    reg [9:0] rd_addr_r;
    reg [7:0] host_rd_data_r;
    reg       host_rd_ack_r;
    reg       host_rd_en_d;           // for rising-edge request detection

    wire rd_req_rise   = host_rd_en & ~host_rd_en_d;
    wire rd_addr_phase = (rd_st == R_ADDR) & ~cap_write;

    // ------------------------------------------------------------------
    // Single macro port arbitration: capture writes always win. The read
    // address comes from the latched request (host holds it too, but the
    // latch makes preemption retries safe).
    // ------------------------------------------------------------------
    assign tmem_men  = cap_write | rd_addr_phase;
    assign tmem_wen  = cap_write;
    assign tmem_ren  = rd_addr_phase;
    assign tmem_bm   = cap_write ? 8'hFF : 8'h00;
    assign tmem_din  = cap_din;
    assign tmem_addr = cap_write ? cap_addr : rd_addr_r;

    assign obs_ptr      = obs_ptr_r;
    assign trace_full   = trace_full_r;
    assign trace_wm     = trace_wm_r;
    assign host_rd_data = host_rd_data_r;
    assign host_rd_ack  = host_rd_ack_r;

    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_pins      <= 8'h00;
            pend_ts        <= 32'h00000000;
            pend_pins      <= 8'h00;
            pend_valid     <= 1'b0;
            wr_ts          <= 32'h00000000;
            wr_pins        <= 8'h00;
            obs_ptr_r      <= 8'h00;
            cap_st         <= S_IDLE;
            trace_full_r   <= 1'b0;
            trace_wm_r     <= 1'b0;
            rd_st          <= R_IDLE;
            rd_addr_r      <= 10'h000;
            host_rd_data_r <= 8'h00;
            host_rd_ack_r  <= 1'b0;
            host_rd_en_d   <= 1'b0;
        end else if (ena) begin
            // single-cycle strobes default low
            trace_full_r  <= 1'b0;
            trace_wm_r    <= 1'b0;
            host_rd_ack_r <= 1'b0;

            prev_pins <= pins_sync;

            if (obs_clr) begin
                // OBS_CLR: discard the trace; cancel any in-flight commit,
                // pending latch, or host read. TRACE_FULL sticky is NOT
                // touched here (STATUS W1C, owned by the PE); the PE also
                // clears its TRACE_WM sticky latch on this strobe (M2).
                obs_ptr_r  <= 8'h00;
                pend_valid <= 1'b0;
                cap_st     <= S_IDLE;
                rd_st      <= R_IDLE;
            end else begin
                // pending latch: latest trigger wins
                if (trig_fire) begin
                    pend_ts    <= cycles;
                    pend_pins  <= pins_sync;
                    pend_valid <= 1'b1;
                end else if (pend_clr) begin
                    pend_valid <= 1'b0;
                end

                // capture FSM
                case (cap_st)
                    S_IDLE, S_B0: begin
                        if (pend_valid) begin
                            if (obs_ptr_r == 8'd204) begin
                                // full: stop, no overwrite, no wrap
                                trace_full_r <= 1'b1;
                                cap_st       <= S_IDLE;
                            end else begin
                                wr_ts    <= pend_ts;
                                wr_pins  <= pend_pins;
                                cap_st   <= S_B1;
                            end
                        end else if (cap_st == S_B0) begin
                            cap_st <= S_IDLE; // unreachable; keeps FSM tight
                        end
                    end
                    S_B1: cap_st <= S_B2;
                    S_B2: cap_st <= S_B3;
                    S_B3: cap_st <= S_B4;
                    S_B4: begin
                        // atomic pointer update between commits; the commit
                        // that reaches WMARK fires the watermark event.
                        obs_ptr_r <= obs_ptr_r + 8'd1;
                        if ((wmark != 8'h00) && ((obs_ptr_r + 8'd1) == wmark))
                            trace_wm_r <= 1'b1;
                        cap_st <= pend_valid ? S_B0 : S_IDLE;
                    end
                    default: cap_st <= S_IDLE;
                endcase

                // host read FSM: writer-priority with preemption retry
                host_rd_en_d <= host_rd_en;
                case (rd_st)
                    R_IDLE: if (rd_req_rise) begin
                        rd_addr_r <= host_rd_addr;
                        rd_st     <= cap_write ? R_PEND : R_ADDR;
                    end
                    R_PEND: begin
                        if (!host_rd_en)
                            rd_st <= R_IDLE;        // host timeout: abort
                        else if (!cap_write)
                            rd_st <= R_ADDR;
                    end
                    R_ADDR: begin
                        if (!host_rd_en)
                            rd_st <= R_IDLE;        // host timeout: abort
                        else if (cap_write)
                            rd_st <= R_PEND;       // writer won the race: retry
                        else
                            rd_st <= R_DATA;
                    end
                    R_DATA: begin
                        if (!host_rd_en)
                            rd_st <= R_IDLE;        // host timeout: no ack
                        else if (cap_write)
                            rd_st <= R_PEND;       // preempted: retry
                        else begin
                            host_rd_data_r <= tmem_dout;
                            host_rd_ack_r  <= 1'b1;
                            rd_st          <= R_IDLE;
                        end
                    end
                    default: rd_st <= R_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
