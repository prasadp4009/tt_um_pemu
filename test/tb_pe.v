// tb_pe.v -- PE block bench (Worker D track, NOT for synthesis).
// Instantiates tt_um_pemu_pe + the IMEM macro functional model (sram_sim.v
// under Verilator). Fully separate from the TT track (test/test.py+test/tb.v).
//
// Part 1: original smoke (19 checks): PSET/PDIR/PGET/LDI/ADD/PUSH/PULL/EVT/
//         WAIT/HLT + prog_ren readback.
// Part 2: exhaustive corner cases -- every opcode with edge encodings, GPR
//         read-after-write hazards on all 3 read ports, WAIT corners (max
//         preset, exact-timeout boundary, entry-hit, all edge modes,
//         tsel[1] CONFIG_ERR), reset in every FSM state + halted, delay-
//         field corners (d=31, reserved_zero ignored), reserved-bits-ignored,
//         SLEEP 0/max, CALL overflow / RET underflow, JMP all conditions +
//         reserved cond, illegal opcodes, AND-fn=11, full MRS/MSR sreg map,
//         PUSH-full/PULL-empty stickies + W1C clear, observer-status inputs,
//         CAP, PMASK gating, ena freeze, halt_req boundary.
// Part 3: fixed-bug regressions:
//         (1) prefetch used pc_plus1 in ST_DELAY/ST_SLEEP (commit 6352084),
//         (2) SUB/CMP carry inverted, ISA C=1 iff a>=b (commit 942a318),
//         (3) HLT incremented PC instead of holding (commit 942a318).
//
// Compile (from repo root):
//   bash test/run_verilator.sh pe
//   (verilator --timing; equivalent iverilog: iverilog -g2012 -DSYNTHESIS
//    -DFUNCTIONAL -o /tmp/tb_pe test/tb_pe.v src/tt_um_pemu_pe.v
//    <pdk>/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_256x32_c2_bm_bist.v
//    <pdk>/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v)
`default_nettype none
`timescale 1ns / 1ps

module tb_pe;

    reg clk = 0;
    always #10 clk = ~clk;   // 50 MHz

    reg rst_n = 0;
    reg ena = 1;

    // program port
    reg        prog_mode = 1;
    reg [7:0]  prog_addr = 0;
    reg [31:0] prog_din = 0;
    reg        prog_wen = 0;
    reg        prog_ren = 0;
    wire [31:0] prog_dout;

    // IMEM macro
    wire [7:0]  imem_addr, imem_men, imem_wen, imem_ren;
    wire [31:0] imem_din, imem_bm;
    wire [31:0] imem_dout;

    // pins
    reg  [7:0] pins_in = 8'h3C;
    wire [7:0] pins_out, pins_oe, pins_sync;
    wire [15:0] pmode_out;

    // FIFOs (TB-owned)
    wire [15:0] tx_data;
    wire        tx_push;
    reg         tx_full = 0;
    reg  [15:0] rx_data = 16'hBEEF;
    wire        rx_pull;
    reg         rx_empty = 0;

    // events / run control
    wire [3:0] evt_code;
    wire       evt_pulse;
    wire       pe_running, pe_halted, timeout_sticky, config_err;
    wire [31:0] cycles;

    // observer config (monitored, not driven)
    wire [1:0]  trig_mode;
    wire        trig_wr_strobe;
    wire [7:0]  edge_mask;
    wire [15:0] edge_cfg;
    wire [7:0]  pat_mask, pat_value, wmark, prescaler;
    wire        obs_en, obs_clr;

    // TB-driven observer/status inputs (were ties in the smoke bench)
    reg [7:0]  obs_ptr_r = 8'd0;
    reg        trace_full_r = 0, trace_wm_r = 0;
    reg [15:0] evt_clr_r = 16'd0;
    reg        halt_req_r = 0, cfg_dirty_set_r = 0;
    reg        tx_empty_r = 1, rx_full_r = 0;

    integer fail = 0, nchecks = 0;
    task check(input integer cond, input [255:0] what);
        begin
            nchecks = nchecks + 1;
            if (!cond) begin $display("FAIL: %0s", what); fail = 1; end
        end
    endtask

    tt_um_pemu_pe dut (
        .clk(clk), .rst_n(rst_n), .ena(ena),
        .prog_mode(prog_mode), .prog_addr(prog_addr), .prog_din(prog_din),
        .prog_wen(prog_wen), .prog_ren(prog_ren), .prog_dout(prog_dout),
        .imem_addr(imem_addr), .imem_men(imem_men), .imem_wen(imem_wen),
        .imem_ren(imem_ren), .imem_din(imem_din), .imem_bm(imem_bm),
        .imem_dout(imem_dout),
        .pins_in(pins_in), .pins_out(pins_out), .pins_oe(pins_oe),
        .pins_sync(pins_sync), .pmode_out(pmode_out),
        .tx_data(tx_data), .tx_push(tx_push), .tx_full(tx_full),
        .rx_data(rx_data), .rx_pull(rx_pull), .rx_empty(rx_empty),
        .evt_code(evt_code), .evt_pulse(evt_pulse),
        .pe_running(pe_running), .pe_halted(pe_halted),
        .timeout_sticky(timeout_sticky), .config_err(config_err),
        .cycles(cycles),
        .trig_mode(trig_mode), .trig_wr_strobe(trig_wr_strobe),
        .edge_mask(edge_mask), .edge_cfg(edge_cfg),
        .pat_mask(pat_mask), .pat_value(pat_value),
        .wmark(wmark), .prescaler(prescaler),
        .obs_en(obs_en), .obs_clr(obs_clr),
        .obs_ptr(obs_ptr_r), .trace_full(trace_full_r), .trace_wm(trace_wm_r),
        .evt_clr(evt_clr_r), .halt_req(halt_req_r), .cfg_dirty_set(cfg_dirty_set_r),
        .tx_empty(tx_empty_r), .rx_full(rx_full_r)
    );

    RM_IHPSG13_1P_256x32_c2_bm_bist u_imem (
        .A_CLK(clk), .A_MEN(imem_men[0]), .A_WEN(imem_wen[0]),
        .A_REN(imem_ren[0]), .A_ADDR(imem_addr), .A_DIN(imem_din),
        .A_DLY(1'b1), .A_DOUT(imem_dout), .A_BM(imem_bm),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(8'd0),
        .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0)
    );

    // capture TX pushes and events
    reg [15:0] tx_seen [0:15];
    integer tx_n = 0;
    always @(posedge clk) if (tx_push) begin tx_seen[tx_n] = tx_data; tx_n = tx_n + 1; end
    reg evt_seen = 0; reg [3:0] evt_seen_code = 0;
    always @(posedge clk) if (evt_pulse) begin evt_seen = 1; evt_seen_code = evt_code; end
    reg tws_seen = 0;   // trig_wr_strobe monitor
    always @(posedge clk) if (trig_wr_strobe) tws_seen <= 1'b1;
    reg oclr_seen = 0;  // obs_clr monitor
    always @(posedge clk) if (obs_clr) oclr_seen <= 1'b1;
    reg rx_pull_seen = 0;
    always @(posedge clk) if (rx_pull) rx_pull_seen <= 1'b1;
    reg del_seen = 0;   // ST_DELAY entered (for no-stall checks)
    always @(posedge clk) if (dut.state === 3'd2) del_seen <= 1'b1;
    reg slp_seen = 0;   // ST_SLEEP entered
    always @(posedge clk) if (dut.state === 3'd4) slp_seen <= 1'b1;
    reg wst_seen = 0;   // ST_WAIT entered
    always @(posedge clk) if (dut.state === 3'd3) wst_seen <= 1'b1;

    // ------------------------------------------------------------------
    // Instruction encoders (isa_v0.2: [31:26] op, [25:21] d, [20:0] operand)
    // ------------------------------------------------------------------
    function [31:0] enc(input [5:0] op, input [4:0] d, input [20:0] opr);
        enc = {op, d, opr};
    endfunction
    function [31:0] i_pset(input [7:0] imm, input [4:0] d);
        i_pset = enc(6'd0, d, {imm, 13'd0});
    endfunction
    function [31:0] i_psetr(input [3:0] rs, input [4:0] d);
        i_psetr = enc(6'd1, d, {rs, 17'd0});
    endfunction
    function [31:0] i_pget(input [3:0] rd, input [4:0] d);
        i_pget = enc(6'd2, d, {rd, 17'd0});
    endfunction
    function [31:0] i_pmask(input [7:0] imm, input [4:0] d);
        i_pmask = enc(6'd3, d, {imm, 13'd0});
    endfunction
    function [31:0] i_pdir(input [7:0] imm, input [4:0] d);
        i_pdir = enc(6'd4, d, {imm, 13'd0});
    endfunction
    function [31:0] i_pmode(input [3:0] rs, input [4:0] d);
        i_pmode = enc(6'd5, d, {rs, 17'd0});
    endfunction
    function [31:0] i_sleep(input [12:0] imm);
        i_sleep = enc(6'd6, 5'd0, {imm, 8'd0});
    endfunction
    function [31:0] i_wait(input [2:0] pin, input pol, input [1:0] mode,
                           input [1:0] tsel, input [3:0] rd);
        i_wait = enc(6'd7, 5'd0, {pin, pol, mode, tsel, rd, 9'd0});
    endfunction
    function [31:0] i_cap(input [3:0] rd, input [4:0] d);
        i_cap = enc(6'd8, d, {rd, 17'd0});
    endfunction
    function [31:0] i_mov(input [3:0] rd, input [3:0] rs, input [4:0] d);
        i_mov = enc(6'd9, d, {rd, rs, 13'd0});
    endfunction
    function [31:0] i_ldi(input [3:0] rd, input [15:0] imm);
        i_ldi = enc(6'd10, 5'd0, {rd, imm, 1'b0});
    endfunction
    function [31:0] i_push(input [3:0] rs, input [4:0] d);
        i_push = enc(6'd11, d, {rs, 17'd0});
    endfunction
    function [31:0] i_pull(input [3:0] rd, input [4:0] d);
        i_pull = enc(6'd12, d, {rd, 17'd0});
    endfunction
    function [31:0] i_mrs(input [3:0] rd, input [5:0] sreg, input [4:0] d);
        i_mrs = enc(6'd13, d, {rd, sreg, 11'd0});
    endfunction
    function [31:0] i_msr(input [3:0] rs, input [5:0] sreg, input [4:0] d);
        i_msr = enc(6'd14, d, {rs, sreg, 11'd0});
    endfunction
    function [31:0] i_addsub(input [3:0] rd, input [3:0] ra, input [3:0] rb,
                             input fn, input [4:0] d);
        i_addsub = enc(6'd15, d, {rd, ra, rb, fn, 8'd0});
    endfunction
    function [31:0] i_alu2(input [3:0] rd, input [3:0] ra, input [3:0] rb,
                           input [1:0] fn, input [4:0] d);
        i_alu2 = enc(6'd16, d, {rd, ra, rb, fn, 7'd0});
    endfunction
    function [31:0] i_shift(input [3:0] rd, input [3:0] ra, input [3:0] rb,
                            input fn, input [4:0] d);
        i_shift = enc(6'd17, d, {rd, ra, rb, fn, 8'd0});
    endfunction
    function [31:0] i_cmp(input [3:0] ra, input [3:0] rb, input [4:0] d);
        i_cmp = enc(6'd18, d, {ra, rb, 13'd0});
    endfunction
    function [31:0] i_jmp(input [8:0] tgt, input [3:0] cond, input [4:0] d);
        i_jmp = enc(6'd19, d, {tgt, cond, 8'd0});
    endfunction
    function [31:0] i_djnz(input [3:0] rs, input [8:0] tgt, input [4:0] d);
        i_djnz = enc(6'd20, d, {rs, tgt, 8'd0});
    endfunction
    function [31:0] i_call(input [8:0] tgt, input [4:0] d);
        i_call = enc(6'd21, d, {tgt, 1'b0, 11'd0});
    endfunction
    function [31:0] i_ret(input [4:0] d);
        i_ret = enc(6'd21, d, {9'd0, 1'b1, 11'd0});
    endfunction
    function [31:0] i_hlt();
        i_hlt = enc(6'd22, 5'd0, 21'd0);
    endfunction
    function [31:0] i_evt(input [3:0] imm, input [4:0] d);
        i_evt = enc(6'd23, d, {imm, 17'd0});
    endfunction

    // ------------------------------------------------------------------
    // Program load / run helpers
    // ------------------------------------------------------------------
    reg [31:0] prog [0:255];
    reg [31:0] img [0:255];

    task load_prog(input integer n);
        integer k;
        begin
            @(negedge clk); prog_mode = 1;   // hold PE in reset
            prog_wen = 0; prog_ren = 0;
            repeat (2) @(posedge clk);
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                prog_addr = k[7:0]; prog_din = prog[k]; prog_wen = 1;
                @(negedge clk);
                prog_wen = 0;
            end
            repeat (2) @(posedge clk);
        end
    endtask

    task go;
        begin
            @(negedge clk); prog_mode = 0;
            repeat (2) @(posedge clk);
        end
    endtask

    // wait until DUT enters FSM state st (st: 0=PRIME 1=BASE 2=DELAY 3=WAIT 4=SLEEP)
    task wait_state(input [2:0] st);
        integer to;
        begin
            to = 0;
            while (dut.state !== st && to < 200000) begin @(posedge clk); #1; to = to + 1; end
            check(to < 200000, "wait_state reached");
        end
    endtask

    // call right after wait_state(st): counts posedges spent in st
    task count_state(input [2:0] st, output integer n);
        begin
            n = 0;
            do begin @(posedge clk); #1; n = n + 1; end
            while (dut.state === st && n < 200000);
        end
    endtask

    task wait_halt(input integer maxc);
        integer nc;
        begin
            nc = 0;
            while (!pe_halted && nc < maxc) begin @(posedge clk); nc = nc + 1; end
            check(nc < maxc, "wait_halt: PE halted in time");
        end
    endtask

    task clear_mon;
        begin
            tx_n = 0; evt_seen = 0; evt_seen_code = 0;
            tws_seen = 0; oclr_seen = 0; rx_pull_seen = 0;
            del_seen = 0; slp_seen = 0; wst_seen = 0;
        end
    endtask

    // assert async reset while the DUT is in a chosen FSM state, then verify
    // the full architectural reset state; deasserts and lets the PE restart.
    // Call when the target state is active (just after a posedge #1 sample).
    task reset_during;
        begin
            @(negedge clk); rst_n = 0;
            repeat (3) @(posedge clk); #1;
            check(dut.state === 3'd0, "reset: state==ST_PRIME");
            check(dut.halted === 1'b0, "reset: halted cleared");
            check(dut.regs[1] === 16'd0 && dut.regs[15] === 16'd0, "reset: GPRs cleared");
            check(dut.sticky === 5'd0, "reset: sticky cleared");
            check(dut.flag_c === 1'b0 && dut.flag_z === 1'b0, "reset: flags cleared");
            check(dut.pmask === 8'hFF, "reset: pmask=0xFF");
            check(dut.pdir === 8'h00 && dut.pin_drv === 8'h00, "reset: pdir/pin_drv=0");
            check(dut.evtflag === 16'd0, "reset: evtflag cleared");
            check(dut.rsp === 3'd0, "reset: rsp=0");
            check(pe_running === 1'b0, "reset: pe_running=0");
            check(pins_out === 8'h00 && pins_oe === 8'h00, "reset: pins quiet");
            check(pmode_out === 16'h0000, "reset: pmode=0");
            check(obs_en === 1'b0, "reset: obs_en=0");
            @(negedge clk); rst_n = 1;
            repeat (2) @(posedge clk); #1;
        end
    endtask

    integer i;
    integer to;
    integer n;
    reg [15:0] snap [0:15];
    integer expd [0:21];

    initial begin
        $dumpfile("/tmp/tb_pe.vcd"); $dumpvars(0, tb_pe);

        // ================= Part 1: original smoke (19 checks) =================
        $readmemh("test/hex/pe_smoke.hex", img);

        // ---- reset (PE held via prog_mode) ----
        #100; rst_n = 1;
        repeat (4) @(posedge clk);

        // ---- LOAD via prog port ----
        for (i = 0; i < 10; i = i + 1) begin
            @(negedge clk);
            prog_addr = i[7:0]; prog_din = img[i]; prog_wen = 1;
            @(negedge clk);
            prog_wen = 0;
        end
        repeat (2) @(posedge clk);

        // ---- Amendment A: prog_ren readback ----
        @(negedge clk); prog_addr = 8'd3; prog_ren = 1;
        repeat (3) @(posedge clk);   // addr latch + macro latency
        check(imem_addr === 8'd3, "prog_ren routes prog_addr to macro");
        check(prog_dout === img[3], "prog_dout readback word3");
        @(negedge clk); prog_ren = 0; prog_addr = 8'd0;
        repeat (2) @(posedge clk);
        check(imem_addr === 8'd0, "imem_addr back to 0 (prime)");

        // ---- GO ----
        check(prog_wen === 1'b0, "prog_wen deasserted before GO");
        @(negedge clk); prog_mode = 0;
        repeat (2) @(posedge clk);
        check(pe_running === 1'b1, "pe_running after GO");

        // ---- let PSET/PDIR/PGET/LDI/ADD/PUSH/PULL/EVT execute ----
        repeat (30) @(posedge clk);
        check(pins_out === 8'hA5, "pins_out=0xA5 after PSET");
        check(pins_oe === 8'hFF, "pins_oe=0xFF after PDIR");
        check(dut.regs[1] === 16'h003C, "r1 = PGET pins (0x3C)");
        check(dut.regs[3] === 16'h2468, "r3 = 0x1234+0x1234");
        check(dut.regs[4] === 16'hBEEF, "r4 = RX pull 0xBEEF");
        check(tx_n === 1 && tx_seen[0] === 16'h2468, "TX push 0x2468");
        check(evt_seen === 1'b1 && evt_seen_code === 4'd3, "EVT 3 raised");
        check(pe_halted === 1'b0, "not halted (in WAIT)");

        // ---- WAIT: drive pin1 high, PE should resume and HLT ----
        to = 0;
        while (!pe_halted && to < 1000) begin
            @(posedge clk); to = to + 1;
            if (to == 50) pins_in[1] = 1'b1;
        end
        check(pe_halted === 1'b1, "pe_halted after WAIT pin + HLT");
        check(pe_running === 1'b0, "pe_running=0 when halted");
        check(dut.regs[5] < 16'd256 && dut.regs[5] > 16'd0, "WAIT elapsed sane");
        check(timeout_sticky === 1'b0, "no TIMEOUT sticky");
        check(config_err === 1'b0, "no CONFIG_ERR");
        // cycles counter frozen while halted
        begin
            reg [31:0] c0; c0 = cycles;
            repeat (10) @(posedge clk);
            check(cycles === c0, "cycles frozen while halted");
        end
        $display("  info: Part 1 smoke done: %0d checks", nchecks);

        // ============ Part 2: ALU / logic / shift / MOV / LDI corners ============
        $display("  info: Part 2: datapath corners");

        // ---- ADD/SUB carry/zero/negative, AND/OR/XOR, MOV ----
        prog[0]  = i_ldi(4'd1, 16'hFFFF);
        prog[1]  = i_ldi(4'd2, 16'h0001);
        prog[2]  = i_addsub(4'd3, 4'd1, 4'd2, 1'b0, 5'd0); // 0xFFFF+1 = 0, C=1 Z=1
        prog[3]  = i_jmp(9'd5, 4'd1, 5'd0);               // JMP z -> taken
        prog[4]  = i_ldi(4'd4, 16'hBADC);                 // error marker
        prog[5]  = i_addsub(4'd5, 4'd1, 4'd2, 1'b1, 5'd0); // 0xFFFF-1 = FFFE, C=1
        prog[6]  = i_jmp(9'd8, 4'd3, 5'd0);               // JMP c -> taken
        prog[7]  = i_ldi(4'd4, 16'hBADD);
        prog[8]  = i_addsub(4'd6, 4'd2, 4'd1, 1'b1, 5'd0); // 1-0xFFFF = 2, C=0
        prog[9]  = i_jmp(9'd11, 4'd4, 5'd0);              // JMP nc -> taken
        prog[10] = i_ldi(4'd4, 16'hBADE);
        prog[11] = i_alu2(4'd7, 4'd1, 4'd2, 2'd0, 5'd0);  // AND = 0x0001
        prog[12] = i_alu2(4'd8, 4'd1, 4'd2, 2'd1, 5'd0);  // OR  = 0xFFFF
        prog[13] = i_alu2(4'd9, 4'd1, 4'd2, 2'd2, 5'd0);  // XOR = 0xFFFE
        prog[14] = i_mov(4'd10, 4'd7, 5'd0);              // MOV r10,r7
        prog[15] = i_hlt();
        clear_mon(); tx_full = 0; rx_empty = 0;
        load_prog(16); go(); wait_halt(2000);
        check(dut.regs[3] === 16'h0000, "ADD 0xFFFF+1 = 0");
        check(dut.regs[5] === 16'hFFFE, "SUB 0xFFFF-1 = FFFE, no borrow");
        check(dut.regs[6] === 16'h0002, "SUB 1-0xFFFF = 2, borrow");
        check(dut.regs[7] === 16'h0001, "AND = 0x0001");
        check(dut.regs[8] === 16'hFFFF, "OR  = 0xFFFF");
        check(dut.regs[9] === 16'hFFFE, "XOR = 0xFFFE");
        check(dut.regs[10] === 16'h0001, "MOV r10,r7");
        check(dut.regs[4] === 16'h0000, "no error marker: all JMP conds right");

        // ---- shifts: shamt corners, C from bit shifted out, shamt[3:0] mask ----
        prog[0]  = i_ldi(4'd1, 16'h8001);
        prog[1]  = i_ldi(4'd2, 16'h0001);
        prog[2]  = i_shift(4'd3, 4'd1, 4'd2, 1'b0, 5'd0); // SHL 0x8001,1 = 2, C=1
        prog[3]  = i_jmp(9'd5, 4'd3, 5'd0);               // JMP c -> taken
        prog[4]  = i_ldi(4'd4, 16'hBADC);
        prog[5]  = i_shift(4'd5, 4'd1, 4'd2, 1'b1, 5'd0); // SHR 0x8001,1 = 4000, C=1
        prog[6]  = i_jmp(9'd8, 4'd3, 5'd0);
        prog[7]  = i_ldi(4'd4, 16'hBADD);
        prog[8]  = i_ldi(4'd6, 16'h0000);
        prog[9]  = i_shift(4'd7, 4'd1, 4'd6, 1'b0, 5'd0); // SHL by 0: val same, C kept
        prog[10] = i_jmp(9'd12, 4'd3, 5'd0);              // C still 1 -> taken
        prog[11] = i_ldi(4'd4, 16'hBADE);
        prog[12] = i_ldi(4'd6, 16'h000F);
        prog[13] = i_shift(4'd8, 4'd1, 4'd6, 1'b0, 5'd0); // SHL by 15 = 0x8000, C=a[1]=0
        prog[14] = i_jmp(9'd16, 4'd4, 5'd0);              // JMP nc -> taken
        prog[15] = i_ldi(4'd4, 16'hBADF);
        prog[16] = i_ldi(4'd6, 16'h001F);
        prog[17] = i_shift(4'd9, 4'd1, 4'd6, 1'b1, 5'd0); // SHR by 31&15=15 = 1, C=a[14]=0
        prog[18] = i_jmp(9'd20, 4'd4, 5'd0);
        prog[19] = i_ldi(4'd4, 16'hBAE0);
        prog[20] = i_hlt();
        clear_mon();
        load_prog(21); go(); wait_halt(2000);
        check(dut.regs[3] === 16'h0002, "SHL 0x8001<<1 = 2");
        check(dut.regs[5] === 16'h4000, "SHR 0x8001>>1 = 0x4000");
        check(dut.regs[7] === 16'h8001, "SHL by 0 keeps value");
        check(dut.regs[8] === 16'h8000, "SHL by 15 = 0x8000");
        check(dut.regs[9] === 16'h0001, "SHR by 31(masked 15) = 1");
        check(dut.regs[4] === 16'h0000, "no error marker: shift C corners");

        // ---- CMP + SUB/CMP carry regression (bug: C was inverted) ----
        prog[0]  = i_ldi(4'd1, 16'd5);
        prog[1]  = i_ldi(4'd2, 16'd3);
        prog[2]  = i_cmp(4'd1, 4'd2, 5'd0);        // 5>=3: C=1, Z=0
        prog[3]  = i_jmp(9'd5, 4'd3, 5'd0);       // JMP c -> taken
        prog[4]  = i_ldi(4'd4, 16'hBADC);
        prog[5]  = i_cmp(4'd2, 4'd1, 5'd0);        // 3<5: C=0
        prog[6]  = i_jmp(9'd8, 4'd4, 5'd0);       // JMP nc -> taken
        prog[7]  = i_ldi(4'd4, 16'hBADD);
        prog[8]  = i_cmp(4'd1, 4'd1, 5'd0);        // equal: Z=1, C=1
        prog[9]  = i_jmp(9'd11, 4'd1, 5'd0);      // JMP z -> taken
        prog[10] = i_ldi(4'd4, 16'hBADE);
        prog[11] = i_ldi(4'd3, 16'h8000);
        prog[12] = i_ldi(4'd5, 16'h0001);
        prog[13] = i_addsub(4'd6, 4'd3, 4'd5, 1'b1, 5'd0); // 0x8000-1 = 7FFF, C=1
        prog[14] = i_jmp(9'd16, 4'd3, 5'd0);
        prog[15] = i_ldi(4'd4, 16'hBADF);
        prog[16] = i_addsub(4'd7, 4'd5, 4'd3, 1'b1, 5'd0); // 1-0x8000 = 8001, C=0 N=1
        // (no JMP-on-N cond in ISA; N verified via result value 0x8001)
        prog[17] = i_hlt();
        clear_mon();
        load_prog(18); go(); wait_halt(2000);
        check(dut.regs[4] === 16'h0000, "carry regression: no error marker");
        check(dut.regs[6] === 16'h7FFF, "SUB 0x8000-1 = 0x7FFF");
        check(dut.regs[7] === 16'h8001, "SUB 1-0x8000 = 0x8001 (N=1)");
        check(config_err === 1'b0, "no CONFIG_ERR in carry test");

        // ---- GPR read-after-write hazards on all 3 read ports ----
        prog[0]  = i_ldi(4'd1, 16'd5);
        prog[1]  = i_addsub(4'd1, 4'd1, 4'd1, 1'b0, 5'd0); // rd=rs1=rs2: old r1=5 -> 10
        prog[2]  = i_addsub(4'd2, 4'd1, 4'd1, 1'b1, 5'd0); // reads NEW r1=10 -> 0
        prog[3]  = i_cmp(4'd2, 4'd2, 5'd0);               // Z=1
        prog[4]  = i_jmp(9'd6, 4'd1, 5'd0);
        prog[5]  = i_ldi(4'd4, 16'hBADC);
        prog[6]  = i_mov(4'd3, 4'd3, 5'd0);               // MOV r3,r3 no-op
        prog[7]  = i_ldi(4'd5, 16'h1234);
        prog[8]  = i_push(4'd5, 5'd0);                    // PUSH reads new r5 (port0)
        prog[9]  = i_pull(4'd6, 5'd0);                    // PULL -> rx_data
        prog[10] = i_ldi(4'd7, 16'h00FF);
        prog[11] = i_psetr(4'd7, 5'd0);                   // PSETR reads new r7 (port0)
        prog[12] = i_pmode(4'd7, 5'd0);                   // PMODE reads new r7 (port0)
        prog[13] = i_hlt();
        clear_mon(); tx_full = 0; rx_empty = 0; rx_data = 16'hBEEF;
        load_prog(14); go(); wait_halt(2000);
        check(dut.regs[1] === 16'd10, "RAW hazard: ADD r1,r1,r1 used old r1=5");
        check(dut.regs[2] === 16'd0, "next-cycle read sees new r1=10");
        check(dut.regs[3] === 16'h0000, "MOV r3,r3 no-op");
        check(dut.regs[4] === 16'h0000, "no error marker: CMP r2,r2 Z=1");
        check(dut.regs[6] === 16'hBEEF, "PULL -> rx_data");
        check(pins_out === 8'hFF, "PSETR forwarded just-written r7");
        check(pmode_out === 16'h00FF, "PMODE forwarded just-written r7");
        check(tx_n === 1 && tx_seen[0] === 16'h1234, "PUSH forwarded just-written r5");

        // ---- LDI reserved bit0 ignored; imm16 max ----
        prog[0]  = enc(6'd10, 5'd0, {4'd3, 16'h1234, 1'b1}); // bit0=1 reserved
        prog[1]  = i_ldi(4'd4, 16'hFFFF);
        prog[2]  = i_ldi(4'd5, 16'h0000);
        prog[3]  = i_hlt();
        load_prog(4); go(); wait_halt(2000);
        check(dut.regs[3] === 16'h1234, "LDI ignores reserved bit0");
        check(dut.regs[4] === 16'hFFFF, "LDI imm16 max");
        check(dut.regs[5] === 16'h0000, "LDI imm16 zero");

        // ---- LDI with delay d=3: ST_DELAY entry (dly!=0 branch) ----
        prog[0]  = enc(6'd10, 5'd3, {4'd6, 16'hBEEF, 1'b0});
        prog[1]  = i_hlt();
        load_prog(2); go(); wait_halt(2000);
        check(dut.regs[6] === 16'hBEEF, "LDI d=3: delayed write commits");

        // ---- DJNZ loop + single-iteration fallthrough ----
        prog[0] = i_ldi(4'd5, 16'd3);
        prog[1] = i_ldi(4'd6, 16'd0);
        prog[2] = i_addsub(4'd6, 4'd6, 4'd5, 1'b0, 5'd0);
        prog[3] = i_djnz(4'd5, 9'd2, 5'd0);
        prog[4] = i_hlt();
        load_prog(5); go(); wait_halt(5000);
        check(dut.regs[5] === 16'd0, "DJNZ loop exits at r5=0");
        check(dut.regs[6] === 16'd6, "DJNZ loop ran 3 times (3+2+1)");
        prog[0] = i_ldi(4'd5, 16'd1);
        prog[1] = i_djnz(4'd5, 9'd5, 5'd0);   // r5=1 -> 0, not taken
        prog[2] = i_ldi(4'd7, 16'h1111);
        prog[3] = i_jmp(9'd6, 4'd0, 5'd0);
        prog[4] = i_ldi(4'd7, 16'h2222);       // skipped
        prog[5] = i_ldi(4'd7, 16'h3333);       // skipped
        prog[6] = i_hlt();
        load_prog(7); go(); wait_halt(2000);
        check(dut.regs[5] === 16'd0, "DJNZ single: decremented to 0");
        check(dut.regs[7] === 16'h1111, "DJNZ single: fell through, not taken");

        // ---- CALL/RET nesting, overflow, underflow ----
        prog[0] = i_call(9'd4, 5'd0);
        prog[1] = i_hlt();
        prog[2] = 32'd0;
        prog[3] = 32'd0;
        prog[4] = i_ldi(4'd7, 16'h1111);
        prog[5] = i_call(9'd8, 5'd0);
        prog[6] = i_ldi(4'd7, 16'h2222);
        prog[7] = i_ret(5'd0);
        prog[8] = i_ldi(4'd8, 16'h3333);
        prog[9] = i_ret(5'd0);
        load_prog(10); go(); wait_halt(2000);
        check(dut.regs[7] === 16'h2222, "CALL/RET nesting: r7 after returns");
        check(dut.regs[8] === 16'h3333, "CALL/RET nesting: r8 set in sub2");
        check(config_err === 1'b0, "no CONFIG_ERR in legal nesting");
        // 5-deep overflow (stack holds 4): f1..f4 ok, 5th CALL drops + CONFIG_ERR
        prog[0]  = i_call(9'd3, 5'd0);
        prog[1]  = i_hlt();
        prog[2]  = 32'd0;
        prog[3]  = i_call(9'd5, 5'd0);
        prog[4]  = i_ret(5'd0);
        prog[5]  = i_call(9'd7, 5'd0);
        prog[6]  = i_ret(5'd0);
        prog[7]  = i_call(9'd9, 5'd0);
        prog[8]  = i_ret(5'd0);
        prog[9]  = i_call(9'd12, 5'd0);   // 5th: rsp==4 -> overflow, dropped
        prog[10] = i_ldi(4'd9, 16'hAAAA); // fall-through: executes if CALL dropped
        prog[11] = i_ret(5'd0);           // unwind: pops 8 -> pc=8
        prog[12] = i_ret(5'd0);
        load_prog(13); go(); wait_halt(5000);
        check(config_err === 1'b1, "CALL overflow sets CONFIG_ERR");
        check(dut.regs[9] === 16'hAAAA, "CALL overflow: dropped call falls through");
        // RET underflow
        prog[0] = i_ret(5'd0);
        prog[1] = i_hlt();
        load_prog(2); go(); wait_halt(2000);
        check(config_err === 1'b1, "RET underflow sets CONFIG_ERR");
        check(pe_halted === 1'b1, "RET underflow: pc++ -> HLT");

        // ---- HLT PC-hold regression (bug: PC incremented on HLT) ----
        prog[0] = i_ldi(4'd1, 16'd1);
        prog[1] = enc(6'd22, 5'd31, 21'h1FFFFF); // HLT, d=31, operand all-ones
        prog[2] = i_ldi(4'd2, 16'd2);           // must never execute
        prog[3] = i_hlt();
        load_prog(4); go(); wait_halt(2000);
        check(pe_halted === 1'b1, "HLT regression: halted");
        check(dut.pc === 8'd1, "HLT regression: PC holds at HLT addr (was pc+1)");
        check(dut.regs[2] === 16'h0000, "HLT regression: post-HLT insn not executed");
        check(dut.regs[1] === 16'h0001, "HLT regression: pre-HLT state intact");
        repeat (5) @(posedge clk); #1;
        check(dut.pc === 8'd1 && pe_halted, "HLT regression: PC still held 5 cycles later");

        // ---- illegal opcodes: CONFIG_ERR, pc advances ----
        prog[0] = enc(6'd24, 5'd0, 21'd0);
        prog[1] = i_ldi(4'd1, 16'h1234);
        prog[2] = enc(6'd63, 5'd0, 21'd0);
        prog[3] = i_hlt();
        load_prog(4); go(); wait_halt(2000);
        check(config_err === 1'b1, "illegal opcode 24 -> CONFIG_ERR");
        check(dut.regs[1] === 16'h1234, "illegal opcode: pc advanced past it");

        // ---- illegal opcode with delay d=2: ST_DELAY entry (dly!=0 branch) ----
        prog[0] = enc(6'd24, 5'd2, 21'd0);
        prog[1] = i_hlt();
        load_prog(2); go(); wait_halt(2000);
        check(config_err === 1'b1, "illegal opcode d=2 -> CONFIG_ERR");
        check(dut.pe_halted === 1'b1, "illegal opcode d=2: HLT reached after delay");

        // ---- AND/OR/XOR fn=11: CONFIG_ERR, still computes AND ----
        prog[0] = i_ldi(4'd1, 16'h00FF);
        prog[1] = i_ldi(4'd2, 16'h0F0F);
        prog[2] = enc(6'd16, 5'd0, {4'd3, 4'd1, 4'd2, 2'b11, 7'd0});
        prog[3] = i_hlt();
        load_prog(4); go(); wait_halt(2000);
        check(config_err === 1'b1, "ALU2 fn=11 -> CONFIG_ERR");
        check(dut.regs[3] === 16'h000F, "ALU2 fn=11 still computes AND");

        // ---- JMP: all conditions (correct cond map: 0=always,1=Z,2=NZ,3=C,4=NC,5=TMO,6=RXNE,7=TXNF,8-15=rsv) ----
        prog[0]  = i_ldi(4'd1, 16'd0);
        prog[1]  = i_ldi(4'd2, 16'd0);
        prog[2]  = i_cmp(4'd1, 4'd2, 5'd0);      // Z=1 C=1
        prog[3]  = i_jmp(9'd6, 4'd0, 5'd0);      // always -> taken
        prog[4]  = i_ldi(4'd4, 16'hBADC);        // error marker
        prog[5]  = i_jmp(9'd31, 4'd0, 5'd0);     // skipped
        prog[6]  = i_jmp(9'd9, 4'd1, 5'd0);      // z -> taken (Z=1)
        prog[7]  = i_ldi(4'd4, 16'hBADD);        // error marker
        prog[8]  = i_jmp(9'd31, 4'd0, 5'd0);
        prog[9]  = i_jmp(9'd12, 4'd2, 5'd0);     // nz -> NOT taken (Z=1)
        prog[10] = i_ldi(4'd5, 16'h1111);        // executes
        prog[11] = i_jmp(9'd13, 4'd0, 5'd0);
        prog[12] = i_ldi(4'd5, 16'h2222);        // skipped
        prog[13] = i_jmp(9'd16, 4'd3, 5'd0);     // c -> taken (C=1)
        prog[14] = i_ldi(4'd4, 16'hBADF);        // error marker
        prog[15] = i_jmp(9'd17, 4'd0, 5'd0);
        prog[16] = i_jmp(9'd19, 4'd4, 5'd0);     // nc -> NOT taken (C=1)
        prog[17] = i_ldi(4'd6, 16'h1111);        // executes
        prog[18] = i_jmp(9'd20, 4'd0, 5'd0);
        prog[19] = i_ldi(4'd6, 16'h2222);        // skipped
        prog[20] = i_jmp(9'd0, 4'd15, 5'd0);     // reserved cond 15 -> not taken + CONFIG_ERR
        prog[21] = i_ldi(4'd7, 16'h9999);        // executes (falls through)
        prog[22] = i_jmp(9'd23, 4'd8, 5'd0);     // reserved cond 8 -> not taken
        prog[23] = i_hlt();
        load_prog(24); go(); wait_halt(5000);
        check(dut.regs[4] === 16'h0000, "JMP conds: no error marker");
        check(dut.regs[5] === 16'h1111, "JMP nz not taken");
        check(dut.regs[6] === 16'h1111, "JMP nc not taken");
        check(dut.regs[7] === 16'h9999, "JMP reserved cond 15/8 not taken");
        check(dut.sticky[4] === 1'b1, "JMP reserved cond sets CONFIG_ERR");

        // ---- JMP tmo / rxne / txnf ----
        prog[0] = i_wait(3'd0, 1'b1, 2'd0, 2'd0, 4'd0); // times out (256)
        prog[1] = i_jmp(9'd4, 4'd5, 5'd0);             // tmo -> taken
        prog[2] = i_ldi(4'd4, 16'hBADC);
        prog[3] = i_jmp(9'd5, 4'd0, 5'd0);
        prog[4] = i_hlt();
        pins_in = 8'h00; clear_mon();
        load_prog(5); go(); wait_halt(5000);
        check(timeout_sticky === 1'b1, "WAIT timed out -> TIMEOUT sticky");
        check(dut.regs[4] === 16'h0000, "JMP tmo taken after timeout");
        // rxne taken / not taken
        prog[0] = i_jmp(9'd3, 4'd6, 5'd0);
        prog[1] = i_ldi(4'd4, 16'hBADC);
        prog[2] = i_jmp(9'd5, 4'd0, 5'd0);
        prog[3] = i_ldi(4'd5, 16'h5555);
        prog[4] = i_jmp(9'd6, 4'd0, 5'd0);
        prog[5] = i_ldi(4'd5, 16'hAAAA);
        prog[6] = i_hlt();
        rx_empty = 0; load_prog(7); go(); wait_halt(2000);
        check(dut.regs[5] === 16'h5555 && dut.regs[4] === 16'h0000, "JMP rxne taken (rx not empty)");
        rx_empty = 1; load_prog(7); go(); wait_halt(2000);
        check(dut.regs[4] === 16'hBADC && dut.regs[5] === 16'hAAAA, "JMP rxne not taken (rx empty)");
        // txnf taken / not taken
        prog[0] = i_jmp(9'd3, 4'd7, 5'd0);
        prog[1] = i_ldi(4'd4, 16'hBADC);
        prog[2] = i_jmp(9'd5, 4'd0, 5'd0);
        prog[3] = i_ldi(4'd5, 16'h5555);
        prog[4] = i_jmp(9'd6, 4'd0, 5'd0);
        prog[5] = i_ldi(4'd5, 16'hAAAA);
        prog[6] = i_hlt();
        tx_full = 0; load_prog(7); go(); wait_halt(2000);
        check(dut.regs[5] === 16'h5555 && dut.regs[4] === 16'h0000, "JMP txnf taken (tx not full)");
        tx_full = 1; load_prog(7); go(); wait_halt(2000);
        check(dut.regs[4] === 16'hBADC && dut.regs[5] === 16'hAAAA, "JMP txnf not taken (tx full)");
        tx_full = 0;

        // ---- EVT imm4 corners: 0 and 15; evtflag; evt_clr ----
        prog[0] = i_evt(4'd0, 5'd0);
        prog[1] = i_hlt();
        clear_mon();
        load_prog(2); go(); wait_halt(2000);
        // EVT and MRS in SAME program (load_prog clears evtflag, so cannot split)
        prog[0] = i_evt(4'd0, 5'd0);
        prog[1] = i_mrs(4'd1, 6'h13, 5'd0);   // MRS EVTFLAG
        prog[2] = i_hlt();
        clear_mon();
        load_prog(3); go(); wait_halt(2000);
        check(evt_seen === 1'b1 && evt_seen_code === 4'd0, "EVT 0 raised");
        check(dut.regs[1][0] === 1'b1, "EVTFLAG bit0 set by EVT 0");
        // EVT 15 with delay d=3, then MRS in same program
        // (delay count verified in Part 6 sweep; here just check function)
        prog[0] = i_evt(4'd15, 5'd3);         // EVT 15 with delay d=3
        prog[1] = i_mrs(4'd1, 6'h13, 5'd0);
        prog[2] = i_hlt();
        clear_mon();
        load_prog(3); go(); wait_halt(2000);
        check(evt_seen === 1'b1 && evt_seen_code === 4'd15, "EVT 15 raised (delay d=3)");
        check(dut.regs[1][15] === 1'b1, "EVTFLAG bit15 set by EVT 15");
        // evt_clr: pulse mid-run during SLEEP, then MRS in same program
        prog[0] = i_evt(4'd15, 5'd0);
        prog[1] = i_sleep(13'd100);      // SLEEP 100 cycles (for evt_clr pulse window)
        prog[2] = i_mrs(4'd1, 6'h13, 5'd0);
        prog[3] = i_hlt();
        clear_mon();
        load_prog(4); go();
        wait_state(3'd4);                     // in ST_SLEEP (not ST_WAIT!)
        @(negedge clk); evt_clr_r = 16'h8001;   // clear bits 15 and 0
        @(negedge clk); evt_clr_r = 16'h0000;
        wait_halt(20000);
        check(evt_seen === 1'b1, "EVT 15 raised before evt_clr");
        check(dut.regs[1] === 16'h0000, "evt_clr pulsed mid-run clears EVTFLAG");

        // ============ Part 3: pin insns, MRS/MSR map, FIFOs, CAP ============
        $display("  info: Part 3: pins / specials / FIFOs");

        // ---- PSET/PMASK/PDIR/PGET corners ----
        prog[0] = i_pmask(8'h0F, 5'd0);
        prog[1] = i_pset(8'hFF, 5'd0);      // gated -> 0x0F
        prog[2] = i_pset(8'h5A, 5'd0);      // gated -> 0x0A
        prog[3] = i_pdir(8'hF0, 5'd0);
        prog[4] = i_mrs(4'd1, 6'h06, 5'd0);  // PMASKR
        prog[5] = i_mrs(4'd2, 6'h07, 5'd0);  // PDIRR
        prog[6] = i_hlt();
        pins_in = 8'h00;
        load_prog(7); go(); wait_halt(2000);
        check(pins_out === 8'h0A, "PMASK gates PSET: 0x5A & 0x0F = 0x0A");
        check(pins_oe === 8'hF0, "PDIR sets pins_oe");
        check(dut.regs[1] === 16'h000F, "MRS PMASKR");
        check(dut.regs[2] === 16'h00F0, "MRS PDIRR");
        // PGET synchronizer (2-stage): pins_in held before GO
        pins_in = 8'h5A;
        prog[0] = i_sleep(13'd2);
        prog[1] = i_pget(4'd1, 5'd0);
        prog[2] = i_hlt();
        load_prog(3); go(); wait_halt(2000);
        check(dut.regs[1] === 16'h005A, "PGET reads synchronized pins_in");
        check(pins_sync === 8'h5A, "pins_sync output = synced pins");

        // ---- full MRS/MSR sreg map ----
        prog[0]  = i_ldi(4'd1, 16'h003C);
        prog[1]  = i_msr(4'd1, 6'h06, 5'd0);
        prog[2]  = i_mrs(4'd2, 6'h06, 5'd0);
        prog[3]  = i_ldi(4'd1, 16'h00F0);
        prog[4]  = i_msr(4'd1, 6'h07, 5'd0);
        prog[5]  = i_mrs(4'd3, 6'h07, 5'd0);
        prog[6]  = i_ldi(4'd1, 16'hA5A4);
        prog[7]  = i_msr(4'd1, 6'h08, 5'd0);
        prog[8]  = i_mrs(4'd4, 6'h08, 5'd0);
        prog[9]  = i_ldi(4'd1, 16'h0007);
        prog[10] = i_msr(4'd1, 6'h0A, 5'd0);
        prog[11] = i_mrs(4'd5, 6'h0A, 5'd0);
        prog[12] = i_ldi(4'd1, 16'h00AA);
        prog[13] = i_msr(4'd1, 6'h0B, 5'd0);
        prog[14] = i_ldi(4'd1, 16'h0055);
        prog[15] = i_msr(4'd1, 6'h0C, 5'd0);
        prog[16] = i_mrs(4'd6, 6'h0B, 5'd0);
        prog[17] = i_mrs(4'd7, 6'h0C, 5'd0);
        prog[18] = i_ldi(4'd1, 16'h00F0);
        prog[19] = i_msr(4'd1, 6'h0D, 5'd0);
        prog[20] = i_ldi(4'd1, 16'h1234);
        prog[21] = i_msr(4'd1, 6'h0E, 5'd0);
        prog[22] = i_ldi(4'd1, 16'h0012);
        prog[23] = i_msr(4'd1, 6'h0F, 5'd0);
        prog[24] = i_mrs(4'd8, 6'h0D, 5'd0);
        prog[25] = i_mrs(4'd9, 6'h0E, 5'd0);
        prog[26] = i_mrs(4'd10, 6'h0F, 5'd0);
        prog[27] = i_ldi(4'd1, 16'h00C8);
        prog[28] = i_msr(4'd1, 6'h10, 5'd0);
        prog[29] = i_mrs(4'd11, 6'h10, 5'd0);
        prog[30] = i_ldi(4'd1, 16'h0003);
        prog[31] = i_msr(4'd1, 6'h11, 5'd0);
        prog[32] = i_mrs(4'd12, 6'h11, 5'd0);
        prog[33] = i_ldi(4'd1, 16'h0001);
        prog[34] = i_msr(4'd1, 6'h12, 5'd0);   // OBS_CTL bit0: obs_en=1
        prog[35] = i_ldi(4'd1, 16'h0002);
        prog[36] = i_msr(4'd1, 6'h09, 5'd0);   // TRIG_MODE=2: disarm + strobe
        prog[37] = i_mrs(4'd13, 6'h09, 5'd0);
        prog[38] = i_ldi(4'd1, 16'h0002);
        prog[39] = i_msr(4'd1, 6'h12, 5'd0);   // OBS_CTL bit1: obs_arm (set-only)
        prog[40] = i_ldi(4'd1, 16'h0004);
        prog[41] = i_msr(4'd1, 6'h12, 5'd0);   // OBS_CTL bit2: obs_clr pulse
        prog[42] = i_hlt();
        clear_mon();
        load_prog(43); go(); wait_halt(5000);
        check(dut.regs[2] === 16'h00FF, "MSR PMASK ignored: MRS reads reset 0xFF");
        check(dut.regs[3] === 16'h0000, "MSR PDIR ignored: MRS reads reset 0x00");
        check(dut.regs[4] === 16'h0000 && pmode_out === 16'h0000, "MSR PMODE ignored: reads reset 0");
        check(dut.regs[5] === 16'h0007, "MSR PIN_SEL=7 readback");
        check(dut.pin_sel_r === 3'd7, "MSR PIN_SEL=7 (internal reg)");
        check(dut.regs[6] === 16'h00AA, "MSR PATTERN mask");
        check(dut.regs[7] === 16'h0055, "MSR PATTERN value");
        check(pat_mask === 8'hAA && pat_value === 8'h55, "pattern ports");
        check(dut.regs[8] === 16'h00F0, "MRS EDGE_MASK");
        check(dut.regs[9] === 16'h0034, "MRS EDGE_CFG0");
        check(dut.regs[10] === 16'h0012, "MRS EDGE_CFG1");
        check(edge_mask === 8'hF0 && edge_cfg === 16'h1234, "edge ports");
        check(dut.regs[11] === 16'h00C8 && wmark === 8'd200, "MSR WMARK=200");
        check(dut.regs[12] === 16'h0003 && prescaler === 8'd3, "MSR PRESCALER=3");
        check(dut.regs[13] === 16'h0002 && trig_mode === 2'd2, "MSR TRIG_MODE=2");
        check(tws_seen === 1'b1, "TRIG_MODE write pulses trig_wr_strobe");
        check(obs_en === 1'b0, "TRIG_MODE write disarms obs_en");
        check(oclr_seen === 1'b1, "OBS_CTL bit2 pulses obs_clr");
        // OBS_PTR / CYCLES / CTS readbacks (CAP first to latch cts_pins)
        // SLEEP prefix lets sync stabilize to pins_in after GO
        obs_ptr_r = 8'd42;
        pins_in = 8'h5A;  // set explicitly for CTS_PINS test
        prog[0] = i_sleep(13'd10);
        prog[1] = i_cap(4'd0, 5'd0);          // CAP: cts_pins <= sync1, cts_hi <= ts
        prog[2] = i_mrs(4'd1, 6'h05, 5'd0);
        prog[3] = i_mrs(4'd2, 6'h01, 5'd0);
        prog[4] = i_mrs(4'd3, 6'h02, 5'd0);
        prog[5] = i_mrs(4'd4, 6'h03, 5'd0);
        prog[6] = i_mrs(4'd5, 6'h04, 5'd0);
        prog[7] = i_mrs(4'd6, 6'h00, 5'd0);
        prog[8] = i_hlt();
        load_prog(9); go(); wait_halt(2000);
        check(dut.regs[1] === 16'd42, "MRS OBS_PTR = tb-driven 42");
        check(dut.regs[2] !== 16'd0 || dut.regs[3] !== 16'd0, "MRS CYCLES nonzero");
        check(dut.regs[4] === dut.regs[3], "MRS CTS_HI == CYCLES_HI (same ts)");
        check(dut.regs[5] === 16'h005A, "MRS CTS_PINS = pins_sync");
        check(dut.regs[6][8] === 1'b1, "MRS STATUS pe_running=1 mid-run");
        check(dut.regs[6][9] === 1'b0, "MRS STATUS halted=0 mid-run");
        check(dut.regs[6][10] === 1'b1, "MRS STATUS tx_empty=1 (tb tie)");
        check(dut.regs[6][11] === 1'b0, "MRS STATUS rx_full=0 (tb tie)");
        obs_ptr_r = 8'd0;
        // unallocated / read-only / write-ignored sregs
        prog[0] = i_mrs(4'd1, 6'h12, 5'd0);   // OBS_CTL not in MRS map -> 0
        prog[1] = i_mrs(4'd2, 6'h14, 5'd0);   // unallocated -> 0
        prog[2] = i_mrs(4'd3, 6'h3F, 5'd0);   // unallocated -> 0
        prog[3] = i_evt(4'd3, 5'd0);
        prog[4] = i_ldi(4'd4, 16'hFFFF);
        prog[5] = i_msr(4'd4, 6'h13, 5'd0);  // MSR EVTFLAG ignored
        prog[6] = i_msr(4'd4, 6'h14, 5'd0);  // MSR unallocated ignored
        prog[7] = i_mrs(4'd5, 6'h13, 5'd0);
        prog[8] = i_hlt();
        clear_mon();
        load_prog(9); go(); wait_halt(2000);
        check(dut.regs[1] === 16'h0000, "MRS OBS_CTL (no map entry) = 0");
        check(dut.regs[2] === 16'h0000, "MRS unallocated 0x14 = 0");
        check(dut.regs[3] === 16'h0000, "MRS unallocated 0x3F = 0");
        check(dut.regs[5][3] === 1'b1, "MSR EVTFLAG ignored: bit3 still set");
        check(config_err === 1'b0, "MSR ignored sregs: no CONFIG_ERR");

        // ---- PUSH-full / PULL-empty stickies + STATUS W1C ----
        prog[0] = i_ldi(4'd1, 16'h1111);
        prog[1] = i_push(4'd1, 5'd0);        // tx_full=1 -> dropped
        prog[2] = i_mrs(4'd2, 6'h00, 5'd0);
        prog[3] = i_hlt();
        clear_mon(); tx_full = 1;
        load_prog(4); go(); wait_halt(2000);
        check(tx_n === 0, "PUSH while tx_full: no tx_push pulse");
        check(dut.regs[2][1] === 1'b1, "PUSH while tx_full: TX_OVERRUN sticky");
        prog[0] = i_ldi(4'd1, 16'h0002);
        prog[1] = i_msr(4'd1, 6'h00, 5'd0);  // W1C clear bit1
        prog[2] = i_mrs(4'd2, 6'h00, 5'd0);
        prog[3] = i_hlt();
        load_prog(4); go(); wait_halt(2000);
        check(dut.regs[2][1] === 1'b0, "MSR STATUS W1C clears TX_OVERRUN");
        tx_full = 0;
        prog[0] = i_pull(4'd3, 5'd0);        // rx_empty=1 -> dropped, r3=0
        prog[1] = i_mrs(4'd2, 6'h00, 5'd0);
        prog[2] = i_hlt();
        clear_mon(); rx_empty = 1;
        load_prog(3); go(); wait_halt(2000);
        check(dut.regs[3] === 16'h0000, "PULL while rx_empty: rd=0");
        check(rx_pull_seen === 1'b0, "PULL while rx_empty: no rx_pull pulse");
        check(dut.regs[2][2] === 1'b1, "PULL while rx_empty: RX_UNDERRUN sticky");
        prog[0] = i_ldi(4'd1, 16'h0004);
        prog[1] = i_msr(4'd1, 6'h00, 5'd0);
        prog[2] = i_mrs(4'd2, 6'h00, 5'd0);
        prog[3] = i_hlt();
        load_prog(4); go(); wait_halt(2000);
        check(dut.regs[2][2] === 1'b0, "MSR STATUS W1C clears RX_UNDERRUN");
        rx_empty = 0;

        // ---- CAP ----
        prog[0] = i_sleep(13'd100);
        prog[1] = i_cap(4'd1, 5'd2);         // CAP with d=2
        prog[2] = i_mrs(4'd2, 6'h03, 5'd0);  // CTS_HI
        prog[3] = i_mrs(4'd3, 6'h02, 5'd0);  // CYCLES_HI
        prog[4] = i_mrs(4'd4, 6'h04, 5'd0);  // CTS_PINS
        prog[5] = i_hlt();
        pins_in = 8'h5A;
        load_prog(6); go();
        wait_state(3'd2); count_state(3'd2, n);  // CAP delay d=2
        wait_halt(2000);
        check(n === 2, "CAP delay d=2 -> 2 ST_DELAY cycles");
        check(dut.regs[1] > 16'd100 && dut.regs[1] < 16'd200, "CAP r1 = ts[15:0] ~100+");
        check(dut.regs[2] === dut.regs[3], "CAP: CTS_HI == CYCLES_HI");
        check(dut.regs[4] === 16'h005A, "CAP: CTS_PINS = pins_sync");

        // ============ Part 4: SLEEP / WAIT corners ============
        $display("  info: Part 4: SLEEP/WAIT corners");

        // ---- SLEEP 0 / max / dly+rsv ignored ----
        prog[0] = i_sleep(13'd0);
        prog[1] = i_ldi(4'd1, 16'd7);
        prog[2] = i_hlt();
        clear_mon();
        load_prog(3); go(); wait_halt(2000);
        check(slp_seen === 1'b0, "SLEEP 0: ST_SLEEP never entered");
        check(dut.regs[1] === 16'd7, "SLEEP 0: falls straight through");
        prog[0] = i_sleep(13'd8191);
        prog[1] = i_hlt();
        load_prog(2); go();
        wait_state(3'd4); count_state(3'd4, n);
        wait_halt(20000);
        // wait_state consumes 1 cycle, so count_state sees 8190
        check(n === 8190, "SLEEP 8191: 8190 ST_SLEEP cycles (max preset)");
        prog[0] = enc(6'd6, 5'd31, {13'd4, 8'hFF});  // dly=31, rsv=all-ones
        prog[1] = i_hlt();
        load_prog(2); go();
        wait_state(3'd4); count_state(3'd4, n);
        wait_halt(2000);
        // wait_state consumes 1 cycle, so count_state sees 3 (not 4)
        check(n === 3, "SLEEP: dly + reserved_zero ignored, 4 cycles");

        // ---- WAIT entry-hit (level, pin already at pol) ----
        // SLEEP prefix lets sync0/sync1 stabilize to pins_in after GO
        pins_in = 8'h04;   // bit2 = 1
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b1, 2'd0, 2'd0, 4'd1);
        prog[2] = i_hlt();
        clear_mon();
        load_prog(3); go(); wait_halt(2000);
        check(wst_seen === 1'b0, "WAIT entry-hit: ST_WAIT never entered");
        check(dut.regs[1] === 16'd0, "WAIT entry-hit: elapsed=0");
        check(timeout_sticky === 1'b0, "WAIT entry-hit: no TIMEOUT");
        // ---- WAIT timeout tsel=0 (256) ----
        pins_in = 8'h00;
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b1, 2'd0, 2'd0, 4'd1);
        prog[2] = i_hlt();
        clear_mon();
        load_prog(3); go();
        wait_state(3'd3); count_state(3'd3, n);
        wait_halt(2000);
        check(n === 256, "WAIT tsel=0: 256 ST_WAIT cycles");
        check(dut.regs[1] === 16'd256, "WAIT timeout: elapsed=256");
        check(timeout_sticky === 1'b1, "WAIT timeout: TIMEOUT sticky set");
        // ---- WAIT exact-timeout boundary: hit when ecnt==255 -> no TIMEOUT ----
        pins_in = 8'h00;
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b1, 2'd0, 2'd0, 4'd1);
        prog[2] = i_hlt();
        load_prog(3); go();
        wait_state(3'd3);
        to = 0;
        while (dut.ecnt !== 13'd254 && to < 2000) begin @(posedge clk); #1; to = to + 1; end
        check(to < 2000, "WAIT boundary: reached ecnt=254");
        @(negedge clk); pins_in[2] = 1'b1;   // sync0=1 at next edge, hit the one after
        wait_halt(2000);
        check(dut.regs[1] === 16'd256, "WAIT boundary: hit at ecnt=255 -> elapsed=256");
        check(timeout_sticky === 1'b0, "WAIT boundary: no TIMEOUT when hit at deadline");
        // ---- WAIT rising edge: elapsed exactly 2 ----
        pins_in = 8'h00;
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b1, 2'd1, 2'd0, 4'd1);
        prog[2] = i_hlt();
        load_prog(3); go();
        wait_state(3'd3);
        @(negedge clk); pins_in[2] = 1'b1;
        wait_halt(2000);
        check(dut.regs[1] === 16'd2, "WAIT rising-edge: elapsed=2");
        check(timeout_sticky === 1'b0, "WAIT rising-edge: no TIMEOUT");
        // ---- WAIT falling edge: pin high first, entry-miss, elapsed=2 ----
        pins_in = 8'h04;
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b0, 2'd2, 2'd0, 4'd1);
        prog[2] = i_hlt();
        clear_mon();
        load_prog(3); go();
        wait_state(3'd3);
        // wait_state succeeded => ST_WAIT entered => entry-miss on steady-high pin
        @(negedge clk); pins_in[2] = 1'b0;
        wait_halt(2000);
        check(dut.regs[1] === 16'd2, "WAIT falling-edge: elapsed=2");
        check(timeout_sticky === 1'b0, "WAIT falling-edge: no TIMEOUT");
        // ---- WAIT either-edge ----
        pins_in = 8'h00;
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b0, 2'd3, 2'd0, 4'd1);
        prog[2] = i_hlt();
        load_prog(3); go();
        wait_state(3'd3);
        @(negedge clk); pins_in[2] = 1'b1;
        wait_halt(2000);
        check(dut.regs[1] === 16'd2, "WAIT either-edge: elapsed=2");
        // ---- WAIT level wait-for-low (pol=0) ----
        pins_in = 8'h04;
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b0, 2'd0, 2'd0, 4'd1);
        prog[2] = i_hlt();
        load_prog(3); go();
        wait_state(3'd3);
        @(negedge clk); pins_in[2] = 1'b0;
        wait_halt(2000);
        check(dut.regs[1] === 16'd2, "WAIT level pol=0: elapsed=2 after pin fell");
        check(timeout_sticky === 1'b0, "WAIT level pol=0: no TIMEOUT");
        // ---- WAIT max implemented preset tsel=1 (4096) ----
        pins_in = 8'h00;
        prog[0] = i_sleep(13'd10);
        prog[1] = i_wait(3'd2, 1'b1, 2'd0, 2'd1, 4'd1);
        prog[2] = i_hlt();
        load_prog(3); go();
        wait_state(3'd3); count_state(3'd3, n);
        wait_halt(20000);
        check(n === 4096, "WAIT tsel=1: 4096 ST_WAIT cycles (max implemented)");
        check(dut.regs[1] === 16'd4096, "WAIT tsel=1: elapsed=4096");
        check(timeout_sticky === 1'b1, "WAIT tsel=1: TIMEOUT sticky");
        // ---- WAIT tsel=2/3: CONFIG_ERR (T17 open: 65536/1048576 not implemented) ----
        prog[0] = enc(6'd7, 5'd0, {3'd2, 1'b1, 2'd0, 2'd2, 4'd1, 9'd0});
        prog[1] = i_hlt();
        load_prog(2); go(); wait_halt(5000);
        check(config_err === 1'b1, "WAIT tsel=2: CONFIG_ERR (T17: 65536 preset N/A)");
        prog[0] = enc(6'd7, 5'd0, {3'd2, 1'b1, 2'd0, 2'd3, 4'd1, 9'd0});
        prog[1] = i_hlt();
        load_prog(2); go(); wait_halt(5000);
        check(config_err === 1'b1, "WAIT tsel=3: CONFIG_ERR (T17: 1048576 preset N/A)");
        // ---- WAIT rsv + delay ignored on entry-hit ----
        pins_in = 8'h04;
        prog[0] = i_sleep(13'd10);
        prog[1] = enc(6'd7, 5'd5, {3'd2, 1'b1, 2'd0, 2'd0, 4'd1, 9'h1FF});
        prog[2] = i_hlt();
        clear_mon();
        load_prog(3); go(); wait_halt(2000);
        check(wst_seen === 1'b0 && del_seen === 1'b0, "WAIT entry-hit: rsv/dly ignored");
        check(dut.regs[1] === 16'd0, "WAIT entry-hit w/ rsv: elapsed=0");
        pins_in = 8'h00;

        // ============ Part 5: prefetch regression (commit 6352084) ============
        // Old bug: ST_DELAY/ST_SLEEP prefetched pc_plus1 -> insn after a
        // delayed insn was skipped.
        $display("  info: Part 5: prefetch regression");
        prog[0] = i_ldi(4'd2, 16'd5);
        prog[1] = i_ldi(4'd3, 16'd7);
        prog[2] = i_addsub(4'd1, 4'd2, 4'd3, 1'b0, 5'd3);  // r1=12, d=3
        prog[3] = i_addsub(4'd4, 4'd2, 4'd2, 1'b0, 5'd0);  // r4=10
        prog[4] = enc(6'd6, 5'd7, {13'd4, 8'd0});          // SLEEP 4, dly=7
        prog[5] = i_addsub(4'd5, 4'd3, 4'd3, 1'b0, 5'd0);  // r5=14
        prog[6] = i_hlt();
        load_prog(7); go();
        wait_state(3'd2); count_state(3'd2, n);
        check(n === 3, "prefetch: ADD d=3 -> 3 ST_DELAY cycles");
        wait_state(3'd4); count_state(3'd4, n);
        check(n === 4, "prefetch: SLEEP 4 (dly ignored) -> 4 ST_SLEEP cycles");
        wait_halt(5000);
        check(dut.regs[1] === 16'd12, "prefetch: r1=12 after ADD d=3");
        check(dut.regs[4] === 16'd10, "prefetch: insn after ST_DELAY not skipped");
        check(dut.regs[5] === 16'd14, "prefetch: insn after ST_SLEEP not skipped");

        // ============ Part 6: delay field on every opcode class ============
        $display("  info: Part 6: delay sweep");
        // (delay counts verified functionally; exact counts for SLEEP/WAIT/d=31 below)
        prog[0]  = i_pset(8'h11, 5'd2);
        prog[1]  = i_pmask(8'hFF, 5'd1);
        prog[2]  = i_pdir(8'hFF, 5'd1);
        prog[3]  = i_pget(4'd12, 5'd1);
        prog[4]  = i_ldi(4'd1, 16'h0022);
        prog[5]  = i_psetr(4'd1, 5'd1);
        prog[6]  = i_pmode(4'd1, 5'd1);
        prog[7]  = i_cap(4'd2, 5'd2);
        prog[8]  = i_mov(4'd3, 4'd1, 5'd4);
        prog[9]  = i_addsub(4'd4, 4'd1, 4'd1, 1'b0, 5'd3);
        prog[10] = i_alu2(4'd5, 4'd1, 4'd1, 2'd0, 5'd1);
        prog[11] = i_shift(4'd6, 4'd1, 4'd1, 1'b0, 5'd1);
        prog[12] = i_cmp(4'd1, 4'd1, 5'd1);
        prog[13] = i_jmp(9'd16, 4'd0, 5'd5);
        prog[14] = i_ldi(4'd7, 16'hBADC);
        prog[15] = i_ldi(4'd7, 16'hBADF);
        prog[16] = i_ldi(4'd8, 16'h0001);
        prog[17] = i_djnz(4'd8, 9'd16, 5'd2);
        prog[18] = i_call(9'd21, 5'd1);
        prog[19] = i_jmp(9'd23, 4'd0, 5'd0);
        prog[20] = i_hlt();
        prog[21] = i_ret(5'd1);
        prog[22] = i_hlt();
        prog[23] = i_push(4'd1, 5'd1);
        prog[24] = i_pull(4'd9, 5'd1);
        prog[25] = i_mrs(4'd10, 6'h01, 5'd1);
        prog[26] = i_ldi(4'd11, 16'd5);
        prog[27] = i_msr(4'd11, 6'h10, 5'd1);
        prog[28] = i_evt(4'd3, 5'd3);
        prog[29] = i_hlt();
        clear_mon(); tx_full = 0; rx_empty = 0; rx_data = 16'hCAFE; pins_in = 8'h5A;
        load_prog(30); go(); wait_halt(5000);
        // Functional checks verify delays work (control flow correct, no skipped insns).
        // Exact ST_DELAY counts verified for SLEEP/WAIT/d=31 separately.
        check(del_seen === 1'b1, "delay sweep: ST_DELAY entered");
        check(dut.regs[3] === 16'h0022, "sweep: MOV r3,r1 d=4");
        check(dut.regs[4] === 16'h0044, "sweep: ADD d=3");
        check(dut.regs[5] === 16'h0022, "sweep: AND d=1");
        check(dut.regs[6] === 16'h0088, "sweep: SHL 0x22<<2 d=1");
        check(dut.regs[7] === 16'h0000, "sweep: JMP d=5 skipped markers");
        check(dut.regs[8] === 16'h0000, "sweep: DJNZ d=2 fell through");
        check(dut.regs[9] === 16'hCAFE, "sweep: PULL d=1");
        check(dut.regs[10] !== 16'h0000, "sweep: MRS d=1");
        check(dut.regs[12] === 16'h005A, "sweep: PGET d=1");
        check(wmark === 8'd5, "sweep: MSR d=1 wrote wmark");
        check(tx_n === 1 && tx_seen[0] === 16'h0022, "sweep: PUSH d=1");
        check(evt_seen === 1'b1 && evt_seen_code === 4'd3, "sweep: EVT d=3");
        // d=31 max + GPRs frozen during ST_DELAY
        prog[0] = i_ldi(4'd2, 16'd1);
        prog[1] = i_ldi(4'd3, 16'd2);
        prog[2] = i_addsub(4'd1, 4'd2, 4'd3, 1'b0, 5'd31);
        prog[3] = i_hlt();
        load_prog(4); go();
        wait_state(3'd2);
        for (i = 0; i < 16; i = i + 1) snap[i] = dut.regs[i];
        count_state(3'd2, n);
        check(n === 31, "delay d=31: 31 ST_DELAY cycles (max)");
        for (i = 0; i < 16; i = i + 1)
            check(dut.regs[i] === snap[i], "GPRs frozen during ST_DELAY");
        check(dut.regs[1] === 16'd3, "ADD d=31: result committed at base");

        // ============ Part 7: reserved-bits-ignored sweep ============
        $display("  info: Part 7: reserved bits ignored");
        prog[0] = i_ldi(4'd1, 16'd1);
        prog[1] = i_ldi(4'd2, 16'd2);
        prog[2] = enc(6'd15, 5'd0, {4'd3, 4'd1, 4'd2, 1'b0, 8'hFF}); // ADD rsv=FF
        prog[3] = enc(6'd6, 5'd31, {13'd4, 8'hFF});                  // SLEEP dly+rsv
        prog[4] = enc(6'd7, 5'd5, {3'd0, 1'b1, 2'd0, 2'd0, 4'd4, 9'h1FF}); // WAIT rsv+dly
        prog[5] = enc(6'd19, 5'd0, {9'd7, 4'd0, 8'hFF});             // JMP rsv
        prog[6] = i_ldi(4'd5, 16'hBADC);                            // skipped
        prog[7] = enc(6'd0, 5'd0, {8'hA5, 13'h1FFF});                // PSET rsv
        prog[8] = enc(6'd13, 5'd0, {4'd6, 6'h01, 11'h7FF});          // MRS rsv
        prog[9] = i_hlt();
        pins_in = 8'h01;   // bit0=1 for WAIT entry-hit
        clear_mon();
        load_prog(10); go();
        wait_state(3'd4); count_state(3'd4, n);
        wait_halt(5000);
        check(n === 4, "rsv: SLEEP dly/rsv ignored -> 4 cycles");
        check(dut.regs[3] === 16'd3, "rsv: ADD rsv=0xFF -> r3=3");
        check(dut.regs[4] === 16'd0, "rsv: WAIT entry-hit, elapsed=0");
        check(wst_seen === 1'b0 && del_seen === 1'b0, "rsv: WAIT no ST_WAIT/ST_DELAY");
        check(dut.regs[5] === 16'h0000, "rsv: JMP rsv taken, marker skipped");
        check(pins_out === 8'hA5, "rsv: PSET rsv=all-ones -> pins=0xA5");
        check(dut.regs[6] !== 16'h0000, "rsv: MRS rsv -> CYCLES_LO nonzero");
        pins_in = 8'h00;

        // ============ Part 8: reset in every FSM state + halted ============
        $display("  info: Part 8: reset in every state");
        // ST_BASE (back-to-back LDIs: every cycle is ST_BASE)
        for (i = 0; i < 64; i = i + 1) prog[i] = i_ldi(4'd1, 16'h0001);
        prog[64] = i_hlt();
        load_prog(65); go();
        repeat (5) @(posedge clk); #1;
        check(dut.state === 3'd1, "in ST_BASE before reset");
        reset_during();
        // ST_DELAY
        prog[0] = i_ldi(4'd2, 16'd1);
        prog[1] = i_ldi(4'd3, 16'd2);
        prog[2] = i_addsub(4'd1, 4'd2, 4'd3, 1'b0, 5'd31);
        prog[3] = i_sleep(13'd5000);
        prog[4] = i_hlt();
        load_prog(5); go();
        wait_state(3'd2);
        reset_during();
        // ST_WAIT
        prog[0] = i_wait(3'd2, 1'b1, 2'd0, 2'd0, 4'd1);
        prog[1] = i_hlt();
        pins_in = 8'h00;
        load_prog(2); go();
        wait_state(3'd3);
        reset_during();
        // ST_SLEEP
        prog[0] = i_sleep(13'd5000);
        prog[1] = i_hlt();
        load_prog(2); go();
        wait_state(3'd4);
        reset_during();
        // ST_PRIME: re-assert reset inside the single post-reset ST_PRIME cycle
        prog[0] = i_ldi(4'd1, 16'h1234);
        prog[1] = i_hlt();
        load_prog(2); go(); wait_halt(2000);
        @(negedge clk); rst_n = 0;
        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1;
        #5; rst_n = 0;   // re-assert before the next posedge: still ST_PRIME
        repeat (2) @(posedge clk); #1;
        check(dut.state === 3'd0, "reset during ST_PRIME: state held");
        check(dut.halted === 1'b0, "reset during ST_PRIME: halted=0");
        @(negedge clk); rst_n = 1;
        wait_halt(2000);
        check(dut.regs[1] === 16'h1234, "post-reset: clean restart runs program");
        // reset while halted
        prog[0] = i_hlt();
        load_prog(1); go(); wait_halt(500);
        check(pe_halted === 1'b1, "halted before reset");
        @(negedge clk); rst_n = 0;
        repeat (2) @(posedge clk); #1;
        check(dut.halted === 1'b0 && dut.state === 3'd0, "reset while halted clears");
        @(negedge clk); rst_n = 1;
        wait_halt(500);
        check(pe_halted === 1'b1, "post-reset: HLT re-executes");

        // ============ Part 9: ena freeze ============
        $display("  info: Part 9: ena freeze");
        prog[0] = i_ldi(4'd1, 16'd5);
        prog[1] = i_sleep(13'd200);
        prog[2] = i_addsub(4'd2, 4'd1, 4'd1, 1'b0, 5'd0);
        prog[3] = i_hlt();
        load_prog(4); go();
        wait_state(3'd4);
        begin
            reg [31:0] c0; c0 = cycles;
            @(negedge clk); ena = 0;
            repeat (20) @(posedge clk); #1;
            check(dut.cycles === c0, "ena=0: cycles frozen");
            check(dut.state === 3'd4, "ena=0: FSM frozen in ST_SLEEP");
            check(pe_running === 1'b1, "ena=0: pe_running stays 1 (not ena-gated, per RTL)");
            @(negedge clk); ena = 1;
        end
        wait_halt(5000);
        check(dut.regs[1] === 16'd5 && dut.regs[2] === 16'd10, "ena freeze: resumes correctly");

        // ============ Part 10: halt_req boundary ============
        $display("  info: Part 10: halt_req");
        for (i = 0; i < 10; i = i + 1) prog[i] = i_ldi(4'd0, 16'd0);  // pad
        prog[10] = i_ldi(4'd2, 16'd2);   // target insn
        prog[11] = i_hlt();
        halt_req_r = 0;
        load_prog(12); go();
        to = 0;
        while (!(dut.state === 3'd1 && dut.pc === 8'd10) && to < 2000) begin
            @(posedge clk); #1; to = to + 1;
        end
        check(to < 2000, "halt_req: caught ST_BASE of target insn");
        @(negedge clk); halt_req_r = 1;
        wait_halt(2000);
        check(pe_halted === 1'b1, "halt_req: PE halted");
        check(dut.pc === 8'd11, "halt_req: pc advanced past current insn");
        // RTL halts AFTER current insn completes (at insn boundary)
        check(dut.regs[2] === 16'h0002, "halt_req: current insn DID execute");
        halt_req_r = 0;
        // (GO-wake restart covered by prog_mode GO in other tests; skip here)

        // ============ Part 11: observer-status inputs -> stickies ============
        $display("  info: Part 11: observer status inputs");
        // Single program (load_prog clears stickies, so cannot split across programs)
        for (i = 0; i < 64; i = i + 1) prog[i] = i_ldi(4'd1, 16'h0001);
        prog[64] = i_mrs(4'd2, 6'h00, 5'd0);      // read STATUS (stickies set by inputs)
        prog[65] = i_ldi(4'd3, 16'h0004);
        prog[66] = i_msr(4'd3, 6'h12, 5'd0);      // OBS_CTL bit2: obs_clr
        prog[67] = i_mrs(4'd4, 6'h00, 5'd0);      // read STATUS (stmw cleared)
        prog[68] = i_ldi(4'd3, 16'h0008);
        prog[69] = i_msr(4'd3, 6'h00, 5'd0);      // STATUS W1C: clear TRACE_FULL
        prog[70] = i_mrs(4'd5, 6'h00, 5'd0);      // read STATUS (TRACE_FULL cleared)
        prog[71] = i_hlt();
        trace_full_r = 0; trace_wm_r = 0; cfg_dirty_set_r = 0;
        load_prog(72); go();
        to = 0;
        while (dut.pc !== 8'd10 && to < 1000) begin @(posedge clk); #1; to = to + 1; end
        @(negedge clk); trace_full_r = 1; @(negedge clk); trace_full_r = 0;
        @(negedge clk); trace_wm_r = 1;   @(negedge clk); trace_wm_r = 0;
        @(negedge clk); cfg_dirty_set_r = 1; @(negedge clk); cfg_dirty_set_r = 0;
        wait_halt(5000);
        check(dut.regs[2][3] === 1'b1, "trace_full -> TRACE_FULL sticky (STATUS[3])");
        check(dut.regs[2][12] === 1'b1, "trace_wm -> sticky_trace_wm (STATUS[12])");
        check(dut.regs[2][13] === 1'b1, "cfg_dirty_set -> cfg_dirty (STATUS[13])");
        check(dut.regs[4][12] === 1'b0, "obs_clr clears trace_wm sticky");
        check(dut.regs[4][3] === 1'b1, "obs_clr leaves TRACE_FULL sticky");
        check(dut.regs[5][3] === 1'b0, "MSR STATUS W1C clears TRACE_FULL");

        // ================= finish =================
        if (fail) $display("RESULT: FAIL (%0d checks)", nchecks);
        else begin
            $display("RESULT: PASS (%0d checks)", nchecks);
            $display("  info: final totals: %0d checks", nchecks);
        end
        $finish;
    end

endmodule
