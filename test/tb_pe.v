// tb_pe.v -- PE block bench (Worker D, NOT for synthesis).
// Instantiates tt_um_pemu_pe + the PDK IMEM macro (functional model).
// Loads test/hex/pe_smoke.hex via the prog port, runs it, and checks
// regs / pins / TX push / RX pull / EVT / WAIT / HLT / prog_ren readback.
//
// Compile (from repo root):
//   iverilog -g2012 -DSYNTHESIS -DFUNCTIONAL -o /tmp/tb_pe test/tb_pe.v \
//     src/tt_um_pemu_pe.v \
//     <pdk>/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_256x32_c2_bm_bist.v \
//     <pdk>/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v
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
        .obs_ptr(8'd0), .trace_full(1'b0), .trace_wm(1'b0),
        .evt_clr(16'd0), .halt_req(1'b0), .cfg_dirty_set(1'b0),
        .tx_empty(1'b1), .rx_full(1'b0)
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
    reg [15:0] tx_seen [0:7];
    integer tx_n = 0;
    always @(posedge clk) if (tx_push) begin tx_seen[tx_n] = tx_data; tx_n = tx_n + 1; end
    reg evt_seen = 0; reg [3:0] evt_seen_code = 0;
    always @(posedge clk) if (evt_pulse) begin evt_seen = 1; evt_seen_code = evt_code; end

    reg [31:0] img [0:255];
    integer i;
    integer to;

    initial begin
        $dumpfile("/tmp/tb_pe.vcd"); $dumpvars(0, tb_pe);
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

        $display("done: %0d checks, %0s", nchecks, fail ? "FAIL" : "PASS");
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL: watchdog timeout");
        $finish;
    end
endmodule
