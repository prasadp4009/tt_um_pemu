// tb_emu_loader.v -- iverilog check of emu_loader + tt_um_pemu + sram_emu.
// Mimics the VIO: pulses start_test, waits for done, prints the decoded
// status. Run from the repo root.
// SIM ONLY.
`default_nettype none
`timescale 1ns / 1ps

module tb_emu_loader;

    reg clk = 0;
    always #10 clk = ~clk;   // 50 MHz test clock
    reg rst_n = 0;

    wire hp_rx, hp_tx;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire [7:0] uio_in;
    assign uio_in = uio_oe & uio_out;   // tb_top pad model

    reg start_test = 0;
    reg inject_fault = 0;
    wire [15:0] milestones;
    wire [7:0]  fail_code;
    wire        phaseA_pass, phaseB_pass, done;
    wire [31:0] signature;
    wire [7:0]  st;
    wire        phase_reset;
    wire        dut_rst_n = rst_n & ~phase_reset;

    assign hp_tx = uo_out[0];

    tt_um_pemu dut (
        .ui_in({7'b0, hp_rx}), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(dut_rst_n)
    );

    emu_loader loader (
        .clk(clk), .rst_n(rst_n),
        .hp_rx(hp_rx), .hp_tx(hp_tx), .uio_out(uio_out),
        .phase_reset(phase_reset),
        .start_test(start_test), .inject_fault(inject_fault),
        .milestones(milestones), .fail_code(fail_code),
        .phaseA_pass(phaseA_pass), .phaseB_pass(phaseB_pass),
        .done(done), .signature(signature), .st(st),
        .tx_busy_o(), .rx_valid_o()
    );

    task run_test(input fault, input [255:0] name);
        integer to;
        begin
            inject_fault = fault;
            start_test = 0; repeat (5) @(posedge clk);
            start_test = 1;
            to = 0;
            while (!done && to < 20000000) begin @(posedge clk); to = to + 1; end
            $display("[%0s] done=%0d to=%0d st=0x%02h A=%0d B=%0d fail=0x%02x ms=0x%04h sig=0x%08h",
                     name, done, to, st, phaseA_pass, phaseB_pass, fail_code, milestones, signature);
            if (!done) $display("TIMEOUT waiting for done");
            start_test = 0; repeat (5) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("/tmp/tb_emu_loader.vcd"); $dumpvars(0, tb_emu_loader);
        rst_n = 0; repeat (10) @(posedge clk); rst_n = 1;
        repeat (10) @(posedge clk);
        run_test(0, "normal");
        run_test(1, "vacuity");
        $finish;
    end

    initial begin #200000000; $display("WATCHDOG"); $finish; end

endmodule
`default_nettype wire
