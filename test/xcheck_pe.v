// X-propagation check for tt_um_pemu_pe (Icarus 4-state).
// Releases reset, runs a mixed-opcode program with random pins, and fails
// if any key architectural signal is X after reset.
//
// Replaces the formal no_x proof: yosys smtbmc mis-evaluates $isunknown on
// wires in this flow (proven with a minimal reproducer), so X-freedom is
// checked here in 4-state simulation instead.
`default_nettype none
`timescale 1ns/1ps
module xcheck_pe;
    reg clk = 0;
    always #10 clk = ~clk;  // 50 MHz

    reg rst_n = 0;
    reg [7:0] pins_in = 0;

    wire [8:0] imem_addr;
    reg [31:0] rom [0:255];
    reg [31:0] imem_dout_r = 0;
    wire [31:0] imem_dout = imem_dout_r;
    // 1-cycle SRAM latency model (matches sram_sim / formal ROM)
    reg [7:0] addr_q = 0;
    always @(posedge clk) begin
        addr_q <= imem_addr;
        imem_dout_r <= rom[addr_q];
    end

    integer i;
    initial begin
        // 0: PSET d=0 val=0xAA ; 1: PGET d=1 rd=3 ; 2: SLEEP imm=2
        // 3: WAIT pin2 (hits: pin2 driven high) ; 4: JMP 0
        rom[0] = 32'h00154000;
        rom[1] = {6'd2, 5'd1, 4'd3, 17'd0};
        rom[2] = 32'h18000200;
        rom[3] = 32'h1CA00C00;
        rom[4] = 32'h4C000000;
        for (i = 5; i < 256; i = i + 1) rom[i] = 32'h00000000;
    end

    tt_um_pemu_pe dut (
        .clk(clk), .rst_n(rst_n), .ena(1'b1),
        .prog_mode(1'b0), .prog_addr(9'd0), .prog_din(32'd0),
        .prog_wen(1'b0), .prog_ren(1'b0), .prog_dout(),
        .imem_addr(imem_addr), .imem_men(), .imem_ren(), .imem_wen(),
        .imem_din(), .imem_bm(), .imem_dout(imem_dout),
        .pins_in(pins_in), .pins_out(), .pins_oe(), .pins_sync(),
        .tx_data(), .tx_push(), .tx_full(1'b0),
        .rx_data(16'd0), .rx_pull(), .rx_empty(1'b1),
        .evt_code(), .evt_pulse(), .pe_running(), .pe_halted(),
        .timeout_sticky(), .config_err(), .cycles(),
        .trig_mode(), .trig_wr_strobe(), .edge_mask(), .edge_cfg(),
        .pat_mask(), .pat_value(), .wmark(), .prescaler(),
        .obs_en(), .obs_clr(), .obs_ptr(8'd0),
        .trace_full(1'b0), .trace_wm(1'b0), .pmode_out(),
        .evt_clr(16'd0), .halt_req(1'b0), .cfg_dirty_set(1'b0),
        .tx_empty(1'b1), .rx_full(1'b0)
    );

    integer cyc = 0;
    integer errs = 0;
    always @(posedge clk) begin
        if (rst_n) cyc <= cyc + 1;
        // random pins (pin2 mostly high so WAIT hits promptly)
        pins_in <= {$random} | 8'h04;
        if (rst_n && cyc > 4) begin
            if ($isunknown(dut.pc) || $isunknown(dut.state) ||
                $isunknown(imem_addr) || $isunknown(dut.instr) ||
                $isunknown(dut.pin_drv) || $isunknown(dut.flag_c) ||
                $isunknown(dut.ts)) begin
                $display("XCHECK FAIL at cyc %0d: pc=%h state=%h imem=%h",
                         cyc, dut.pc, dut.state, imem_addr);
                errs <= errs + 1;
            end
        end
        if (cyc == 600) begin
            if (errs == 0) $display("XCHECK PASS: 600 cycles, no X on key signals");
            else $display("XCHECK FAIL: %0d X-hits", errs);
            $finish;
        end
    end

    initial begin
        #100 rst_n = 1;
        #20000 $display("XCHECK TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
