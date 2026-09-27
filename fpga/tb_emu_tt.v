// tb_emu_tt.v -- Icarus pre-check of emu_tt_loader + tt_um_pemu.
//
// Runs the full test.py-equivalent scenario in simulation before the FPGA
// build, catching loader FSM bugs early. SRAM macros resolve to
// fpga/sram_emu.v (plain Verilog, no specify blocks).
//
// Build from repo root:
//   iverilog -g2012 -o /tmp/tb_emu_tt fpga/tb_emu_tt.v fpga/emu_tt_loader.v \
//     fpga/sram_emu.v src/tt_um_pemu.v src/tt_um_pemu_pe.v \
//     src/tt_um_pemu_host.v src/tt_um_pemu_observer.v
//   vvp /tmp/tb_emu_tt
//
// FPGA-EMULATION-ONLY. Not for ASIC synthesis.
// SPDX-License-Identifier: Apache-2.0
`default_nettype none
`timescale 1ns/1ps

module tb_emu_tt;
    reg clk = 0;
    always #10 clk = ~clk;  // 50 MHz

    reg rst_n = 0;
    wire hp_rx, hp_tx;
    wire [7:0] uio_out, uio_oe;
    wire [7:0] uio_in = uio_out & uio_oe;  // TT pad loopback
    wire phase_reset;
    reg start_test = 0;
    reg inject_fault = 0;

    wire [15:0] milestones;
    wire [7:0]  fail_code;
    wire        tt_pass, loader_done;
    wire [31:0] signature;
    wire [7:0]  loader_st;
    wire [31:0] dbg0, dbg1, dbg2;

    wire dut_rst_n = rst_n & ~phase_reset;
    wire [7:0] uo_bus;

    emu_tt_loader u_loader (
        .clk(clk), .rst_n(rst_n),
        .hp_rx(hp_rx), .hp_tx(hp_tx),
        .uio_out(uio_out), .uio_oe(uio_oe),
        .phase_reset(phase_reset),
        .start_test(start_test), .inject_fault(inject_fault),
        .milestones(milestones), .fail_code(fail_code),
        .tt_pass(tt_pass), .done(loader_done), .signature(signature),
        .st(loader_st), .tx_busy_o(), .rx_valid_o(),
        .dbg0(dbg0), .dbg1(dbg1), .dbg2(dbg2)
    );

    tt_um_pemu u_dut (
        .ui_in  ({7'b0, hp_rx}),
        .uo_out (uo_bus),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (1'b1),
        .clk    (clk),
        .rst_n  (dut_rst_n)
    );
    assign hp_tx = uo_bus[0];

    integer i;
    initial begin
        $dumpfile("/tmp/tb_emu_tt.vcd");
        $dumpvars(1, tb_emu_tt.u_loader);
        #100;
        rst_n = 1;
        #200;
        start_test = 1;
        // wait for done, timeout 3M clocks (60 ms at 50 MHz)
        for (i = 0; i < 3000000; i = i + 1) begin
            @(posedge clk);
            if (loader_done) begin
                i = 3000000;
            end
        end
        #100;
        $display("SIM RESULT: tt_pass=%0d fail_code=0x%02x milestones=0x%04x",
                 tt_pass, fail_code, milestones);
        $display("SIM RESULT: signature=0x%08x", signature);
        $display("SIM RESULT: dbg0=0x%08x dbg1=0x%08x dbg2=0x%08x", dbg0, dbg1, dbg2);
        if (tt_pass && fail_code == 0 && milestones == 16'h7FFF)
            $display("SIM RESULT: PASS");
        else
            $display("SIM RESULT: FAIL");
        $finish;
    end
endmodule
`default_nettype wire
