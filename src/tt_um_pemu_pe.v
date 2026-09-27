/*
 * tt_um_pemu_pe.v — TEMPO-32 PE core (Protocol Emulator, Jane Street ASIC competition)
 *
 * Worker A (PE core), Phase 6. Single-cycle, non-pipelined 32-bit datapath
 * implementing all 24 TEMPO-32 instructions per isa_v0.2.yaml + ISA_v0.2.md
 * timing contract T1–T17, cycle-exact vs firmware/tools/sim.py.
 *
 * Key microarchitectural decisions (see also intf_pe.md):
 *  - IMEM is a synchronous 1P macro (registered DOUT, 1-cycle read latency).
 *    The PE presents the *next* fetch address combinationally each cycle
 *    (branch-resolved); the macro latches it at the clock edge. Sustained
 *    1 instruction/cycle, no per-instruction hidden cycles (T6). On
 *    prog_mode deassert (GO) one explicit fetch-prime cycle presents addr 0;
 *    a plain rst_n release needs no prime (reset interval already presents 0).
 *  - Pin outputs (pins_out/pins_oe/pmode_out) are COMBINATIONAL functions of
 *    the current decode + committed state, i.e. a PSET/PSETR/PDIR/PMODE base
 *    cycle drives the new pin state during that same cycle. This is what makes
 *    the RTL cycle-exact with sim.py and satisfies T5 (PGET/CAP/Observer see
 *    physical pins exactly 2 core cycles earlier). Registered shadows
 *    (pin_drv/pdir/pmode) commit at the end of the base cycle.
 *  - WAIT tsel 2/3: NOT implemented (T17-OPEN). tsel[1] is ignored for the
 *    timeout (256/4096 from tsel[0]) and sets CONFIG_ERR sticky. Elapsed is
 *    therefore always exactly defined; no invented overflow semantics.
 *  - Illegal opcode (24-63): NOP (1+d) + CONFIG_ERR sticky (T6 open).
 *  - CALL on full return stack: call dropped (pc+1), CONFIG_ERR (T11 open).
 *    RET on empty stack: NOP (pc+1), CONFIG_ERR (T10 open).
 *  - AND/OR/XOR fn=11: executed as AND + CONFIG_ERR (T7 open).
 *  - JMP cond4 8-15: never taken + CONFIG_ERR.
 *  - MSR STATUS W1C mask is bits [4:0] only (matches sim.py golden model;
 *    TRACE_WM[12] clears only via the OBS_CLR strobe). NOTE: ISA_v0.2.md §4
 *    bit table says "W1C via MSR" for bit 12 — flagged for the ISA lead.
 *  - MRS/MSR to unallocated sregs 0x14-0x3F: read-as-zero / write-ignored,
 *    no CONFIG_ERR (matches sim.py; T5 open).
 *  - HLT: T16 clock-gating -- the HLT base cycle performs no tick and, while
 *    halted, the synchronizer, timestamp and `cycles` counter all freeze
 *    (exactly like sim.py). Wake via GO (prog_mode 1->0, PC forced to 0).
 *  - HALT_REQ (ISA 0x0A): `halt_req` (active-high level) halts the PE at the
 *    next instruction boundary, exactly as if HLT executed. The request is
 *    registered: the PE stays halted until halt_req is LOW and a GO
 *    (prog_mode 1->0) occurs. `halted` is therefore NOT cleared by prog_mode
 *    (only by rst_n); a GO while halt_req is high leaves the PE halted.
 *  - IMEM prefetch: during ST_DELAY/ST_WAIT/ST_SLEEP the macro address is
 *    pc_plus1 (not pc), so the instruction after a multi-cycle op is already
 *    in DOUT on the exit edge. Without this, a WAIT timeout/hit would
 *    re-fetch the WAIT instruction itself (synchronous-read corruption).
 *  - `timeout_sticky` / `config_err` mirror STATUS[0] / STATUS[4] for the
 *    host RD_STATUS byte (bits 5 and 0).
 *  - Nine spec-forced interface additions beyond the dictated port list are
 *    documented in intf_pe.md: pmode_out, evt_clr[15:0], halt_req,
 *    cfg_dirty_set, tx_empty, rx_full, prog_dout, timeout_sticky, config_err.
 *    (A dedicated `go` input was removed: GO is defined as the prog_mode
 *    1->0 transition per the coordinator's HALT_REQ amendment.)
 *  - [AMD-A] Worker D: `prog_ren` input for host VERIFY_IMEM. In prog_mode,
 *    imem_addr = prog_addr when prog_wen|prog_ren. prog-mode REN is NOT
 *    gated by prog_ren (deliberate deviation from D8's literal
 *    imem_ren={8{prog_ren}}): gating REN low in prog_mode would leave the
 *    macro DOUT unprimed, so the first fetch after a LOAD->GO with no
 *    VERIFY_IMEM would execute the STALE write-through word of the last
 *    program write -- a silent mis-execution. Keeping REN=1 in prog_mode
 *    (write cycles excepted) preserves the D8 intent (host-driven IMEM
 *    reads) and the fetch-prime invariant (GO fetches word 0).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_pemu_pe (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ena,
    // Program-load port (loader active only in prog_mode; PE held in reset)
    input  wire        prog_mode,
    input  wire [7:0]  prog_addr,
    input  wire [31:0] prog_din,
    input  wire        prog_wen,
    input  wire        prog_ren,       // [AMD-A] host VERIFY_IMEM read enable
    output wire [31:0] prog_dout,     // IMEM readback for host VERIFY_IMEM
    // IMEM macro port (RM_IHPSG13_1P_256x32_c2_bm_bist). men/ren/wen are
    // 8-bit per the dictated interface; all 8 bits carry the same enable.
    output wire [7:0]  imem_addr,
    output wire [7:0]  imem_men,
    output wire [7:0]  imem_ren,
    output wire [7:0]  imem_wen,
    output wire [31:0] imem_din,
    output wire [31:0] imem_bm,
    input  wire [31:0] imem_dout,
    // Pins
    input  wire [7:0]  pins_in,
    output wire [7:0]  pins_out,
    output wire [7:0]  pins_oe,
    output wire [7:0]  pins_sync,
    // FIFOs (16x16, owned by sibling workers)
    output wire [15:0] tx_data,
    output wire        tx_push,
    input  wire        tx_full,
    input  wire [15:0] rx_data,
    output wire        rx_pull,
    input  wire        rx_empty,
    // Events / run control
    output wire [3:0]  evt_code,
    output wire        evt_pulse,
    output wire        pe_running,
    output wire        pe_halted,
    output wire        timeout_sticky, // STATUS[0] TIMEOUT (host RD_STATUS bit5)
    output wire        config_err,     // STATUS[4] CONFIG_ERR (host RD_STATUS bit0)
    output wire [31:0] cycles,
    // Observer configuration (PE-owned registers; observer worker consumes)
    output wire [1:0]  trig_mode,
    output wire        trig_wr_strobe,
    output wire [7:0]  edge_mask,
    output wire [15:0] edge_cfg,
    output wire [7:0]  pat_mask,
    output wire [7:0]  pat_value,
    output wire [7:0]  wmark,
    output wire [7:0]  prescaler,
    output wire        obs_en,
    output wire        obs_clr,
    input  wire [7:0]  obs_ptr,
    input  wire        trace_full,
    input  wire        trace_wm,
    // ---- Documented spec-forced additions (see intf_pe.md) ----
    output wire [15:0] pmode_out,     // per-pin {open_drain,pull_up} to pin fabric
    input  wire [15:0] evt_clr,       // host clear of EVTFLAG (1 bit per flag)
    input  wire        halt_req,      // host HALT_REQ (0x0A): halt at insn boundary;
                                      // wake on GO (prog_mode 1->0) with halt_req low
    input  wire        cfg_dirty_set, // host WR_CFG touched live config
    input  wire        tx_empty,      // TX FIFO empty (for STATUS[10])
    input  wire        rx_full        // RX FIFO full  (for STATUS[11])
);

    // ------------------------------------------------------------------
    // Opcode map (isa_v0.2.yaml §3)
    // ------------------------------------------------------------------
    localparam [5:0] OP_PSET    = 6'd0,
                     OP_PSETR   = 6'd1,
                     OP_PGET    = 6'd2,
                     OP_PMASK   = 6'd3,
                     OP_PDIR    = 6'd4,
                     OP_PMODE   = 6'd5,
                     OP_SLEEP   = 6'd6,
                     OP_WAIT    = 6'd7,
                     OP_CAP     = 6'd8,
                     OP_MOV     = 6'd9,
                     OP_LDI     = 6'd10,
                     OP_PUSH    = 6'd11,
                     OP_PULL    = 6'd12,
                     OP_MRS     = 6'd13,
                     OP_MSR     = 6'd14,
                     OP_ADDSUB  = 6'd15,
                     OP_ALU2    = 6'd16,
                     OP_SHIFT   = 6'd17,
                     OP_CMP     = 6'd18,
                     OP_JMP     = 6'd19,
                     OP_DJNZ    = 6'd20,
                     OP_CALLRET = 6'd21,
                     OP_HLT     = 6'd22,
                     OP_EVT     = 6'd23;

    // STATUS sticky bit positions
    localparam ST_TIMEOUT = 0, ST_TX_OVERRUN = 1, ST_RX_UNDERRUN = 2,
               ST_TRACE_FULL = 3, ST_CONFIG_ERR = 4;

    // FSM states
    localparam [2:0] ST_PRIME = 3'd0,   // fetch prime (addr 0 presented)
                     ST_BASE  = 3'd1,   // base cycle: decode + execute
                     ST_DELAY = 3'd2,   // d delay cycles (NOP-equivalent)
                     ST_WAIT  = 3'd3,   // WAIT poll loop
                     ST_SLEEP = 3'd4;   // SLEEP countdown

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    reg [2:0]  state;
    reg [7:0]  pc;
    reg [15:0] regs [0:15];
    // flag_n is architectural state per ISA §5.1 (set on every ALU/SHIFT/CMP
    // result) but no JMP condition reads N; it is write-only in hardware.
    /* verilator lint_off UNUSEDSIGNAL */
    reg        flag_z, flag_n, flag_c;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [4:0]  sticky;             // TIMEOUT,TX_OVERRUN,RX_UNDERRUN,TRACE_FULL,CONFIG_ERR
    reg        sticky_trace_wm;    // STATUS[12]
    reg        cfg_dirty;          // STATUS[13]
    reg [7:0]  pmask;              // reset 0xFF
    reg [7:0]  pdir;               // reset 0x00 (all Hi-Z)
    reg [15:0] pmode;              // reset 0x0000
    reg [7:0]  pin_drv;
    reg [7:0]  sync0, sync1;       // 2-FF input synchronizer
    reg [31:0] ts;                 // prescaled timestamp (runs in HLT per T16)
    reg [12:0] prescale_cnt;
    reg [31:0] cycles_r;           // raw PE cycle counter (frozen in HLT)
    reg [7:0]  retstack [0:3];
    reg [2:0]  rsp;
    reg [15:0] cts_hi;
    reg [7:0]  cts_pins;
    reg [15:0] evtflag;
    // Observer config registers (PE-owned)
    reg [1:0]  trig_mode_r;
    reg [2:0]  pin_sel_r;
    reg [7:0]  obs_mask_r, obs_value_r;
    reg [7:0]  edge_mask_r, edge_cfg0_r, edge_cfg1_r;
    reg [7:0]  wmark_r;
    reg [1:0]  prescaler_r;
    reg        obs_en_r, obs_arm_r;
    // Control
    reg        halted;
    reg        prog_mode_d;
    reg        rst_n_d;
    reg [4:0]  dcnt;               // delay countdown
    reg [12:0] scnt;               // SLEEP countdown
    reg [12:0] ecnt;               // WAIT elapsed countdown
    reg [12:0] wait_timeout_r;
    reg [2:0]  wait_pin;
    reg        wait_pol;
    reg [1:0]  wait_mode;
    reg [3:0]  wait_rd;
    reg [7:0]  wait_prev;
    // Single-cycle pulse outputs (registered)
    reg        tx_push_r, rx_pull_r, evt_pulse_r, trig_wr_strobe_r, obs_clr_r;
    reg [3:0]  evt_code_r;
    reg [15:0] tx_data_r;
    // Edge detectors for observer inputs
    reg        trace_full_d, trace_wm_d;

    integer i;

    // ------------------------------------------------------------------
    // Decode (combinational; instr = macro DOUT, stable through the cycle)
    // ------------------------------------------------------------------
    // instr[0] is the LDI reserved_zero bit and is intentionally unused.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] instr  = imem_dout;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [5:0]  opcode = instr[31:26];
    wire [4:0]  dly    = instr[25:21];
    wire [3:0]  rd     = instr[20:17];

    wire        in_reset    = !rst_n || prog_mode;
    wire        exec_active = (state == ST_BASE) && !halted && !in_reset && ena;
    // T16: HLT gates PE clocks -- synchronizer, timestamp and the cycle
    // counter freeze (sim.py: the HLT base cycle itself performs no tick).
    // The reset-release / GO-prime edge also performs no tick so that the
    // first architectural tick is the first instruction's base cycle,
    // exactly like the golden model.
    wire        tick_en = rst_n_d && !prog_mode_d && !halted &&
                          !(exec_active && opcode == OP_HLT);

    // ALU operands (CMP uses the [20:17]/[16:13] lanes)
    // Area opt: shared GPR read ports. The ISA never reads more than 3 distinct
    // GPR addresses in one cycle; all [20:17] reads share one physical port.
    wire [15:0] rf_rd0 = regs[instr[20:17]];
    wire [15:0] rf_rd1 = regs[instr[16:13]];
    wire [15:0] rf_rd2 = regs[instr[12:9]];
    wire [15:0] alu_a = (opcode == OP_CMP) ? rf_rd0 : rf_rd1;
    wire [15:0] alu_b = (opcode == OP_CMP) ? rf_rd1 : rf_rd2;
    // Area opt: shared add/sub. sub_op=1 computes a-b as a+~b+1; the 17-bit
    // carry-out is exact for both (C=carry for ADD, C=~borrow for SUB/CMP).
    wire sub_op = (opcode == OP_CMP) || ((opcode == OP_ADDSUB) && instr[8]);
    wire [16:0] addsub_r = {1'b0, alu_a} + (sub_op ? {1'b0, ~alu_b} : {1'b0, alu_b}) + (sub_op ? 17'd1 : 17'd0);
    wire [16:0] add_r = addsub_r;
    wire [16:0] sub_r = addsub_r;
    wire [15:0] and_r = alu_a & alu_b;
    wire [15:0] or_r  = alu_a | alu_b;
    wire [15:0] xor_r = alu_a ^ alu_b;
    wire [3:0]  shamt = alu_b[3:0];
    // Area opt: shared barrel shifter via bit-reversal.
    // shr(a,n) = rev(rev(a) << n); reversal is free (wires).
    // shl_r/shr_r are only consumed by OP_SHIFT, where shr_op selects
    // the correct data path, so values are exact whenever used.
    wire [15:0] alu_a_rev;
    genvar gv_i;
    generate
        for (gv_i = 0; gv_i < 16; gv_i = gv_i + 1) begin : g_rev_a
            assign alu_a_rev[gv_i] = alu_a[15-gv_i];
        end
    endgenerate
    wire        shr_op = (opcode == OP_SHIFT) && instr[8];
    wire [15:0] sh_in = shr_op ? alu_a_rev : alu_a;
    wire [15:0] sh_out = sh_in << shamt;
    wire [15:0] sh_out_rev;
    generate
        for (gv_i = 0; gv_i < 16; gv_i = gv_i + 1) begin : g_rev_o
            assign sh_out_rev[gv_i] = sh_out[15-gv_i];
        end
    endgenerate
    wire [15:0] shl_r = sh_out;
    wire [15:0] shr_r = sh_out_rev;

    // JMP condition decode
    wire [3:0] cond4 = instr[11:8];
    wire jmp_taken =
        (cond4 == 4'd0) ? 1'b1 :
        (cond4 == 4'd1) ? flag_z :
        (cond4 == 4'd2) ? ~flag_z :
        (cond4 == 4'd3) ? flag_c :
        (cond4 == 4'd4) ? ~flag_c :
        (cond4 == 4'd5) ? sticky[ST_TIMEOUT] :
        (cond4 == 4'd6) ? ~rx_empty :
        (cond4 == 4'd7) ? ~tx_full : 1'b0;
    wire jmp_cond_reserved = (cond4 > 4'd7);

    // DJNZ take: test NEW (post-decrement) Rs
    wire [15:0] djnz_new = rf_rd0 - 16'd1;
    wire djnz_take = (djnz_new != 16'd0);

    // WAIT entry check (T8 adopted interpretation): compare post-base-cycle
    // sync sample (pre-edge sync0) against the pre-base sample (pre-edge sync1)
    wire wv_e  = sync0[instr[20:18]];
    wire wpv_e = sync1[instr[20:18]];
    wire w_entry_hit =
        (instr[16:15] == 2'b00) ? (wv_e == instr[17]) :
        (instr[16:15] == 2'b01) ? (wv_e && !wpv_e) :
        (instr[16:15] == 2'b10) ? (!wv_e && wpv_e) : (wv_e != wpv_e);

    // WAIT loop check uses the latched config
    wire wv_l  = sync0[wait_pin];
    wire wpv_l = wait_prev[wait_pin];
    wire wait_hit =
        (wait_mode == 2'b00) ? (wv_l == wait_pol) :
        (wait_mode == 2'b01) ? (wv_l && !wpv_l) :
        (wait_mode == 2'b10) ? (!wv_l && wpv_l) : (wv_l != wpv_l);

    // Next fetch address (branch-resolved, combinational). The synchronous
    // IMEM macro latches this at the clock edge; DOUT is the instruction
    // for the following cycle.
    wire [7:0] pc_plus1 = pc + 8'd1;
    wire [7:0] next_pc_addr =
        (exec_active && opcode == OP_JMP && jmp_taken) ? instr[19:12] :
        (exec_active && opcode == OP_DJNZ && djnz_take) ? instr[15:8] :
        (exec_active && opcode == OP_CALLRET && !instr[11] && rsp != 3'd4) ? instr[19:12] :
        (exec_active && opcode == OP_CALLRET && instr[11] && rsp != 3'd0) ? retstack[rsp[1:0] - 2'd1] :
        pc_plus1;

    // Pin drive (combinational — see header note re T5/sim-exactness)
    wire [7:0] pset_new  = (pin_drv & ~pmask) | (instr[20:13] & pmask);
    wire [7:0] psetr_new = (pin_drv & ~pmask) | (rf_rd0[7:0] & pmask);
    wire [7:0] pins_out_comb =
        (!exec_active) ? pin_drv :
        (opcode == OP_PSET)  ? pset_new :
        (opcode == OP_PSETR) ? psetr_new : pin_drv;
    wire [7:0]  pins_oe_comb =
        (!exec_active) ? pdir :
        (opcode == OP_PDIR) ? instr[20:13] : pdir;
    wire [15:0] pmode_out_comb =
        (!exec_active) ? pmode :
        (opcode == OP_PMODE) ? rf_rd0 : pmode;

    // Prescaler divide value
    wire [12:0] div_val = (prescaler_r == 2'd0) ? 13'd1 :
                          (prescaler_r == 2'd1) ? 13'd16 :
                          (prescaler_r == 2'd2) ? 13'd256 : 13'd4096;

    // Special-register read mux
    reg [15:0] sreg_read;
    wire pe_running_w = rst_n && !prog_mode && !halted;
    always @(*) begin
        case (instr[16:11])
            6'h00: sreg_read = {2'b0, cfg_dirty, sticky_trace_wm, rx_full,
                                tx_empty, halted, pe_running_w, 3'b0, sticky};
            6'h01: sreg_read = ts[15:0];
            6'h02: sreg_read = ts[31:16];
            6'h03: sreg_read = cts_hi;
            6'h04: sreg_read = {8'd0, cts_pins};
            6'h05: sreg_read = {8'd0, obs_ptr};
            6'h06: sreg_read = {8'd0, pmask};
            6'h07: sreg_read = {8'd0, pdir};
            6'h08: sreg_read = pmode;
            6'h09: sreg_read = {14'd0, trig_mode_r};
            6'h0A: sreg_read = {13'd0, pin_sel_r};
            6'h0B: sreg_read = {8'd0, obs_mask_r};
            6'h0C: sreg_read = {8'd0, obs_value_r};
            6'h0D: sreg_read = {8'd0, edge_mask_r};
            6'h0E: sreg_read = {8'd0, edge_cfg0_r};
            6'h0F: sreg_read = {8'd0, edge_cfg1_r};
            6'h10: sreg_read = {8'd0, wmark_r};
            6'h11: sreg_read = {14'd0, prescaler_r};
            6'h12: sreg_read = {13'd0, obs_arm_r, 1'b0, obs_en_r};
            6'h13: sreg_read = evtflag;
            default: sreg_read = 16'd0;  // unallocated: read-as-zero (T5 open)
        endcase
    end

    // ------------------------------------------------------------------
    // Main sequential block
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        prog_mode_d <= prog_mode;
        rst_n_d     <= rst_n;

        if (!rst_n || prog_mode) begin
            state           <= ST_PRIME;
            pc              <= 8'd0;
            for (i = 0; i < 16; i = i + 1) regs[i] <= 16'd0;
            flag_z          <= 1'b0;
            flag_n          <= 1'b0;
            flag_c          <= 1'b0;
            sticky          <= 5'd0;
            sticky_trace_wm <= 1'b0;
            cfg_dirty       <= 1'b0;
            pmask           <= 8'hFF;
            pdir            <= 8'd0;
            pmode           <= 16'd0;
            pin_drv         <= 8'd0;
            sync0           <= 8'd0;
            sync1           <= 8'd0;
            ts              <= 32'd0;
            prescale_cnt    <= 13'd0;
            cycles_r        <= 32'd0;
            rsp             <= 3'd0;
            for (i = 0; i < 4; i = i + 1) retstack[i] <= 8'd0;
            cts_hi          <= 16'd0;
            cts_pins        <= 8'd0;
            evtflag         <= 16'd0;
            trig_mode_r     <= 2'd0;
            pin_sel_r       <= 3'd0;
            obs_mask_r      <= 8'd0;
            obs_value_r     <= 8'd0;
            edge_mask_r     <= 8'd0;
            edge_cfg0_r     <= 8'd0;
            edge_cfg1_r     <= 8'd0;
            wmark_r         <= 8'd0;
            prescaler_r     <= 2'd0;
            obs_en_r        <= 1'b0;
            obs_arm_r       <= 1'b0;
            // halted is cleared by rst_n only: it persists across prog_mode
            // (HALT_REQ 0x0A: the request is registered; wake needs GO with
            // halt_req low). See the halted branch below.
            if (!rst_n) halted <= 1'b0;
            dcnt            <= 5'd0;
            scnt            <= 13'd0;
            ecnt            <= 13'd0;
            wait_timeout_r  <= 13'd0;
            wait_pin        <= 3'd0;
            wait_pol        <= 1'b0;
            wait_mode       <= 2'd0;
            wait_rd         <= 4'd0;
            wait_prev       <= 8'd0;
            tx_push_r       <= 1'b0;
            rx_pull_r       <= 1'b0;
            evt_pulse_r     <= 1'b0;
            trig_wr_strobe_r <= 1'b0;
            obs_clr_r       <= 1'b0;
            evt_code_r      <= 4'd0;
            tx_data_r       <= 16'd0;
            trace_full_d    <= 1'b0;
            trace_wm_d      <= 1'b0;
        end else if (ena) begin
            // ---- host-driven updates (not gated by tick_en) ----
            // single-cycle pulses default off
            tx_push_r        <= 1'b0;
            rx_pull_r        <= 1'b0;
            evt_pulse_r      <= 1'b0;
            trig_wr_strobe_r <= 1'b0;
            obs_clr_r        <= 1'b0;
            // host clear of EVTFLAG: applies even while halted (T16 gates
            // only the PE's own clocks). An EVT in the same cycle re-sets
            // its bit (see OP_EVT).
            evtflag <= evtflag & ~evt_clr;

            // ---- clocked always-on updates (frozen when tick_en==0) ----
            if (tick_en) begin
                sync0 <= pins_in;
                sync1 <= sync0;
                if (prescale_cnt == div_val - 13'd1) begin
                    prescale_cnt <= 13'd0;
                    ts           <= ts + 32'd1;
                end else begin
                    prescale_cnt <= prescale_cnt + 13'd1;
                end
                cycles_r <= cycles_r + 32'd1;
                // observer sticky inputs: rising-edge detect (robust to both
                // pulse and level signalling from the observer worker)
                trace_full_d <= trace_full;
                trace_wm_d   <= trace_wm;
                if (cfg_dirty_set) cfg_dirty <= 1'b1;
            end

            if (halted) begin
                // GO = prog_mode 1->0. Wakes only when halt_req is low;
                // a GO while halt_req is high leaves the PE halted (the
                // registered HALT_REQ re-asserts at the next boundary).
                // PC is already 0 (prog_mode holds the reset state).
                if (prog_mode_d && !prog_mode && !halt_req) begin
                    halted <= 1'b0;
                    state  <= ST_BASE;
                    pc     <= 8'd0;
                end
            end else if (prog_mode_d) begin
                // GO while running: the IMEM macro was already primed with
                // addr 0 during prog_mode (loader must deassert prog_wen
                // first), so go straight to BASE -- no extra prime bubble.
                state <= ST_BASE;
            end else begin
                case (state)
                    ST_PRIME: begin
                        state <= ST_BASE;
                    end

                    ST_BASE: begin
                        case (opcode)
                            OP_PSET: begin
                                pin_drv <= pset_new;
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_PSETR: begin
                                pin_drv <= psetr_new;
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_PGET: begin
                                regs[rd] <= {8'd0, sync1};
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_PMASK: begin
                                pmask <= instr[20:13];
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_PDIR: begin
                                pdir <= instr[20:13];
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_PMODE: begin
                                pmode <= rf_rd0;
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_SLEEP: begin
                                // dly reserved_zero: ignored (not a delay)
                                pc <= pc_plus1;
                                if (instr[20:8] == 13'd0) begin
                                    if (halt_req) halted <= 1'b1;
                                end else begin
                                    scnt  <= instr[20:8];
                                    state <= ST_SLEEP;
                                end
                            end
                            OP_WAIT: begin
                                // dly reserved_zero: ignored
                                wait_pin       <= instr[20:18];
                                wait_pol       <= instr[17];
                                wait_mode      <= instr[16:15];
                                wait_rd        <= instr[12:9];
                                // T17-OPEN: tsel[1] ignored for the timeout;
                                // flag it instead of inventing semantics.
                                wait_timeout_r <= instr[13] ? 13'd4096 : 13'd256;
                                wait_prev      <= sync0;
                                if (instr[14]) sticky[ST_CONFIG_ERR] <= 1'b1;
                                if (w_entry_hit) begin
                                    regs[instr[12:9]] <= 16'd0;  // elapsed=0
                                    pc <= pc_plus1;
                                    if (halt_req) halted <= 1'b1;
                                end else begin
                                    state <= ST_WAIT;
                                    ecnt  <= 13'd0;
                                end
                            end
                            OP_CAP: begin
                                cts_hi   <= ts[31:16];
                                cts_pins <= sync1;
                                regs[rd] <= ts[15:0];
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_MOV: begin
                                regs[rd] <= rf_rd1;
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_LDI: begin
                                regs[rd] <= instr[16:1];
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_PUSH: begin
                                if (tx_full) begin
                                    sticky[ST_TX_OVERRUN] <= 1'b1;
                                end else begin
                                    tx_data_r <= rf_rd0;
                                    tx_push_r <= 1'b1;
                                end
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_PULL: begin
                                if (rx_empty) begin
                                    regs[instr[20:17]] <= 16'd0;
                                    sticky[ST_RX_UNDERRUN] <= 1'b1;
                                end else begin
                                    regs[instr[20:17]] <= rx_data;
                                    rx_pull_r <= 1'b1;
                                end
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_MRS: begin
                                regs[rd] <= sreg_read;
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_MSR: begin
                                case (instr[16:11])
                                    6'h00: sticky <= sticky & ~rf_rd0[4:0];
                                    6'h09: begin
                                        trig_mode_r      <= rf_rd0[1:0];
                                        obs_en_r         <= 1'b0;  // any write disarms
                                        trig_wr_strobe_r <= 1'b1;
                                    end
                                    6'h0A: pin_sel_r   <= rf_rd0[2:0];
                                    6'h0B: obs_mask_r  <= rf_rd0[7:0];
                                    6'h0C: obs_value_r <= rf_rd0[7:0];
                                    6'h0D: edge_mask_r <= rf_rd0[7:0];
                                    6'h0E: edge_cfg0_r <= rf_rd0[7:0];
                                    6'h0F: edge_cfg1_r <= rf_rd0[7:0];
                                    6'h10: wmark_r     <= rf_rd0[7:0];
                                    6'h11: prescaler_r <= rf_rd0[1:0];
                                    6'h12: begin
                                        if (rf_rd0[2]) begin
                                            obs_clr_r       <= 1'b1;
                                            sticky_trace_wm <= 1'b0;
                                        end
                                        if (rf_rd0[0])
                                            obs_en_r <= 1'b1;
                                        // OBS_ARM is set-only (T4 open),
                                        // matching sim.py's golden model.
                                        if (rf_rd0[1])
                                            obs_arm_r <= 1'b1;
                                    end
                                    // 0x13 EVTFLAG: MSR ignored (host clears).
                                    // RO + unallocated: MSR ignored (T5 open).
                                    default: ;
                                endcase
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_ADDSUB: begin
                                if (instr[8] == 1'b0) begin
                                    regs[rd] <= add_r[15:0];
                                    flag_c   <= add_r[16];
                                    flag_z   <= (add_r[15:0] == 16'd0);
                                    flag_n   <= add_r[15];
                                end else begin
                                    regs[rd] <= sub_r[15:0];
                                    flag_c   <= sub_r[16];
                                    flag_z   <= (sub_r[15:0] == 16'd0);
                                    flag_n   <= sub_r[15];
                                end
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_ALU2: begin
                                case (instr[8:7])
                                    2'b00: begin
                                        regs[rd] <= and_r;
                                        flag_z   <= (and_r == 16'd0);
                                        flag_n   <= and_r[15];
                                    end
                                    2'b01: begin
                                        regs[rd] <= or_r;
                                        flag_z   <= (or_r == 16'd0);
                                        flag_n   <= or_r[15];
                                    end
                                    2'b10: begin
                                        regs[rd] <= xor_r;
                                        flag_z   <= (xor_r == 16'd0);
                                        flag_n   <= xor_r[15];
                                    end
                                    default: begin
                                        // fn=11 reserved (T7 open): AND + CONFIG_ERR
                                        regs[rd] <= and_r;
                                        flag_z   <= (and_r == 16'd0);
                                        flag_n   <= and_r[15];
                                        sticky[ST_CONFIG_ERR] <= 1'b1;
                                    end
                                endcase
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_SHIFT: begin
                                if (shamt == 4'd0) begin
                                    regs[rd] <= alu_a;  // C unchanged
                                    flag_z   <= (alu_a == 16'd0);
                                    flag_n   <= alu_a[15];
                                end else if (instr[8] == 1'b0) begin
                                    regs[rd] <= shl_r;
                                    flag_c   <= alu_a[16 - shamt];
                                    flag_z   <= (shl_r == 16'd0);
                                    flag_n   <= shl_r[15];
                                end else begin
                                    regs[rd] <= shr_r;
                                    flag_c   <= alu_a[shamt - 4'd1];
                                    flag_z   <= (shr_r == 16'd0);
                                    flag_n   <= shr_r[15];
                                end
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_CMP: begin
                                flag_z <= (sub_r[15:0] == 16'd0);
                                flag_n <= sub_r[15];
                                flag_c <= sub_r[16];
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_JMP: begin
                                if (jmp_cond_reserved)
                                    sticky[ST_CONFIG_ERR] <= 1'b1;
                                pc <= jmp_taken ? instr[19:12] : pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_DJNZ: begin
                                regs[instr[20:17]] <= djnz_new;
                                pc <= djnz_take ? instr[15:8] : pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_CALLRET: begin
                                if (instr[11] == 1'b0) begin
                                    // CALL
                                    if (rsp == 3'd4) begin
                                        // overflow (T11 open): drop call, flag
                                        sticky[ST_CONFIG_ERR] <= 1'b1;
                                        pc <= pc_plus1;
                                    end else begin
                                        retstack[rsp[1:0]] <= pc_plus1;
                                        rsp <= rsp + 3'd1;
                                        pc <= instr[19:12];
                                    end
                                end else begin
                                    // RET
                                    if (rsp == 3'd0) begin
                                        // underflow (T10 open): NOP, flag
                                        sticky[ST_CONFIG_ERR] <= 1'b1;
                                        pc <= pc_plus1;
                                    end else begin
                                        rsp <= rsp - 3'd1;
                                        pc <= retstack[rsp[1:0] - 2'd1];
                                    end
                                end
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            OP_HLT: begin
                                // dly reserved_zero: ignored
                                // BUG FIX (pre-existing): ISA golden model (sim.py) does NOT
                                // increment PC on HLT; the halted PC points AT the HLT
                                // instruction. Removed pc_plus1 to match golden.
                                halted <= 1'b1;
                            end
                            OP_EVT: begin
                                // explicit whole-reg update: host clear applies,
                                // then the event bit is set (clear+set same
                                // cycle => set wins, matching the old comment).
                                evtflag <= (evtflag & ~evt_clr) |
                                           (16'h0001 << instr[20:17]);
                                evt_code_r  <= instr[20:17];
                                evt_pulse_r <= 1'b1;
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                            default: begin
                                // Illegal opcode 24-63 (T6 open): NOP + CONFIG_ERR
                                sticky[ST_CONFIG_ERR] <= 1'b1;
                                pc <= pc_plus1;
                                if (dly != 5'd0) begin
                                    state <= ST_DELAY; dcnt <= dly;
                                end else if (halt_req) halted <= 1'b1;
                            end
                        endcase
                    end

                    ST_DELAY: begin
                        dcnt <= dcnt - 5'd1;
                        if (dcnt == 5'd1) begin
                            if (halt_req) halted <= 1'b1;
                            else state <= ST_BASE;
                        end
                    end

                    ST_WAIT: begin
                        if (wait_hit) begin
                            regs[wait_rd] <= {3'd0, ecnt} + 16'd1;  // elapsed
                            pc <= pc_plus1;
                            if (halt_req) halted <= 1'b1;
                            else state <= ST_BASE;
                        end else if (ecnt + 13'd1 == wait_timeout_r) begin
                            regs[wait_rd] <= {3'd0, wait_timeout_r};
                            sticky[ST_TIMEOUT] <= 1'b1;
                            pc <= pc_plus1;
                            if (halt_req) halted <= 1'b1;
                            else state <= ST_BASE;
                        end else begin
                            ecnt      <= ecnt + 13'd1;
                            wait_prev <= sync0;
                        end
                    end

                    ST_SLEEP: begin
                        scnt <= scnt - 13'd1;
                        if (scnt == 13'd1) begin
                            if (halt_req) halted <= 1'b1;
                            else state <= ST_BASE;
                        end
                    end

                    default: state <= ST_BASE;
                endcase
                // Observer sticky sets come AFTER the instruction updates so
                // that a simultaneous edge-detect set wins over an MSR
                // STATUS W1C clear of the same bit -- matching sim.py, where
                // observer_eval() runs after the instruction's effects.
                if (tick_en) begin
                    if (trace_full && !trace_full_d)
                        sticky[ST_TRACE_FULL] <= 1'b1;
                    if (trace_wm && !trace_wm_d)
                        sticky_trace_wm <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // IMEM macro interface
    // ------------------------------------------------------------------
    // Run mode: single read port, address = branch-resolved next PC during
    // the base cycle (the macro latches it for the following cycle).
    // ST_WAIT: pc NOT advanced at entry (polls the WAIT insn); exit does
    // pc<=pc_plus1, so prefetch pc_plus1.
    // ST_DELAY/ST_SLEEP: pc ALREADY advanced (pc<=pc_plus1) at entry;
    // exit holds pc, so prefetch pc (pc_plus1 would skip an instruction).
    // Halted: hold pc. Prog mode: loader writes.
    assign imem_addr = prog_mode ? ((prog_wen || prog_ren) ? prog_addr : 8'd0) :
                       (state == ST_PRIME) ? 8'd0 :
                       ((state == ST_BASE) && !halted) ? next_pc_addr :
                       (state == ST_WAIT) ? pc_plus1 : pc;
    assign imem_men  = 8'hFF;
    assign imem_wen  = (prog_mode && prog_wen) ? 8'hFF : 8'h00;
    // [AMD-A] prog_ren selects the address; REN itself is kept high in
    // prog_mode (except during prog_wen writes) so the ST_PRIME/ST_BASE
    // fetch always sees a valid, primed DOUT at GO even when no
    // VERIFY_IMEM was issued (Worker D deviation from D8 literal text).
    assign imem_ren  = (prog_mode && prog_wen) ? 8'h00 : 8'hFF;
    assign imem_din  = prog_din;
    assign imem_bm   = (prog_mode && prog_wen) ? 32'hFFFFFFFF : 32'h0;

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    assign pins_out   = pins_out_comb;
    assign pins_oe    = pins_oe_comb;
    assign pmode_out  = pmode_out_comb;
    assign pins_sync  = sync1;

    assign tx_data = tx_data_r;
    assign tx_push = tx_push_r;
    assign rx_pull = rx_pull_r;

    assign evt_code  = evt_code_r;
    assign evt_pulse = evt_pulse_r;

    assign pe_running = rst_n && !prog_mode && !halted;
    assign pe_halted  = halted && rst_n && !prog_mode;

    assign timeout_sticky = sticky[ST_TIMEOUT];
    assign config_err     = sticky[ST_CONFIG_ERR];

    // IMEM readback for host VERIFY_IMEM (combinational mux is fine)
    assign prog_dout = prog_mode ? imem_dout : 32'b0;

    assign cycles = cycles_r;

    assign trig_mode      = trig_mode_r;
    assign trig_wr_strobe = trig_wr_strobe_r;
    assign edge_mask      = edge_mask_r;
    assign edge_cfg       = {edge_cfg1_r, edge_cfg0_r};
    assign pat_mask       = obs_mask_r;
    assign pat_value      = obs_value_r;
    assign wmark          = wmark_r;
    assign prescaler      = {6'd0, prescaler_r};
    assign obs_en         = obs_en_r;
    assign obs_clr        = obs_clr_r;

endmodule
`default_nettype wire
