// tb_observer.v -- observer block bench (Worker D, NOT for synthesis).
// Instantiates tt_um_pemu_observer + the PDK trace macro (functional model).
// Checks EDGE/PATTERN/PULSE triggers, commit latency <= 6 (T17), entry
// content, watermark + saturation strobes, host readout during capture,
// and OBS_CLR.
//
// Timing note: `cyc` increments at negedge; pins_sync is driven just after
// a negedge (#1 settles ordering) so the *next* posedge is the trigger edge
// and `cycles` sampled there equals the recorded expected timestamp.
//
// Compile (from repo root):
//   iverilog -g2012 -DSYNTHESIS -DFUNCTIONAL -o /tmp/tb_obs test/tb_observer.v \
//     src/tt_um_pemu_observer.v \
//     <pdk>/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_1024x8_c2_bm_bist.v \
//     <pdk>/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v
`default_nettype none
`timescale 1ns / 1ps

module tb_observer;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg ena = 1;

    // TB-driven timestamp (stable across each posedge)
    reg [31:0] cyc = 0;
    always @(negedge clk) cyc = cyc + 1;
    wire [31:0] cycles = cyc;

    reg [7:0] pins_sync = 8'h00;

    reg [1:0] trig_mode = 2'b00;
    reg       trig_wr_strobe = 0;
    reg [7:0] edge_mask = 0;
    reg [15:0] edge_cfg = 0;
    reg [7:0] pat_mask = 0, pat_value = 0;
    reg [2:0] pin_sel = 0;
    reg [7:0] wmark = 0;
    reg [7:0] prescaler = 0;
    reg       obs_en = 0;
    reg       obs_clr = 0;

    wire [7:0] obs_ptr;
    wire       trace_full, trace_wm;

    wire [9:0] tmem_addr, host_rd_addr;
    wire       tmem_men, tmem_ren, tmem_wen, host_rd_en;
    wire [7:0] tmem_din, tmem_bm;
    wire [7:0] tmem_dout, host_rd_data;
    wire       host_rd_ack;
    reg        host_rd_en_r = 0;
    reg [9:0]  host_rd_addr_r = 0;

    assign host_rd_en = host_rd_en_r;
    assign host_rd_addr = host_rd_addr_r;

    integer fail = 0, nchecks = 0;
    task check(input integer cond, input [255:0] what);
        begin
            nchecks = nchecks + 1;
            if (!cond) begin $display("FAIL: %0s", what); fail = 1; end
        end
    endtask

    tt_um_pemu_observer dut (
        .clk(clk), .rst_n(rst_n), .ena(ena),
        .cycles(cycles), .pins_sync(pins_sync),
        .trig_mode(trig_mode), .trig_wr_strobe(trig_wr_strobe),
        .edge_mask(edge_mask), .edge_cfg(edge_cfg),
        .pat_mask(pat_mask), .pat_value(pat_value),
        .pin_sel(pin_sel), .wmark(wmark), .prescaler(prescaler),
        .obs_en(obs_en), .obs_clr(obs_clr),
        .obs_ptr(obs_ptr), .trace_full(trace_full), .trace_wm(trace_wm),
        .tmem_addr(tmem_addr), .tmem_men(tmem_men), .tmem_ren(tmem_ren),
        .tmem_wen(tmem_wen), .tmem_din(tmem_din), .tmem_bm(tmem_bm),
        .tmem_dout(tmem_dout),
        .host_rd_en(host_rd_en), .host_rd_addr(host_rd_addr),
        .host_rd_data(host_rd_data), .host_rd_ack(host_rd_ack)
    );

    RM_IHPSG13_1P_1024x8_c2_bm_bist u_tmem (
        .A_CLK(clk), .A_MEN(tmem_men), .A_WEN(tmem_wen), .A_REN(tmem_ren),
        .A_ADDR(tmem_addr), .A_DIN(tmem_din), .A_DLY(1'b1),
        .A_DOUT(tmem_dout), .A_BM(tmem_bm),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(10'd0),
        .A_BIST_DIN(8'd0), .A_BIST_BM(8'd0)
    );

    // read one trace byte via the host port (holds en/addr till ack)
    task host_read(input [9:0] addr, output reg [7:0] data);
        integer to;
        begin
            @(negedge clk); #1;
            host_rd_addr_r = addr; host_rd_en_r = 1;
            to = 0;
            while (!host_rd_ack && to < 600) begin
                @(posedge clk); #1; to = to + 1;
            end
            check(host_rd_ack === 1'b1, "host_rd ack");
            data = host_rd_data;
            @(negedge clk); #1; host_rd_en_r = 0;
            repeat (2) @(posedge clk);
        end
    endtask

    // configure + arm for a mode (mirrors the PE's MSR sequence)
    task arm(input [1:0] mode);
        begin
            trig_mode = mode;
            @(negedge clk); #1; trig_wr_strobe = 1;
            @(negedge clk); #1; trig_wr_strobe = 0;
            repeat (2) @(posedge clk);
            obs_en = 1;
            repeat (2) @(posedge clk);
        end
    endtask

    // drive pins_sync just after a negedge; ts = cycles sampled at next posedge
    task set_pins(input [7:0] v, output reg [31:0] ts);
        begin
            @(negedge clk); #1;
            pins_sync = v; ts = cycles;
        end
    endtask

    // wait for obs_ptr==want; n = posedges elapsed (call right after trigger edge)
    task wait_ptr(input [7:0] want, output integer n);
        begin
            n = 0;
            while (obs_ptr !== want && n < 30) begin @(posedge clk); #1; n = n + 1; end
        end
    endtask

    reg [7:0] b0, b1, b2, b3, b4;
    reg [31:0] exp_ts, dummy_ts;
    integer n, i, to;

    initial begin
        $dumpfile("/tmp/tb_obs.vcd"); $dumpvars(0, tb_observer);
        #100; rst_n = 1;
        repeat (4) @(posedge clk);
        check(obs_ptr === 8'd0, "obs_ptr=0 after reset");

        // ---------------- EDGE mode ----------------
        edge_mask = 8'h01; edge_cfg = 16'h0001;   // pin0 rising
        arm(2'b01);
        set_pins(8'h01, exp_ts);
        @(posedge clk); #1;                       // trigger edge
        wait_ptr(8'd1, n);
        check(obs_ptr === 8'd1, "EDGE: obs_ptr=1 after trigger");
        check(n <= 6, "EDGE: trigger->commit <= 6 cycles (T17)");
        $display("  info: EDGE commit latency n=%0d posedges", n);
        set_pins(8'h00, dummy_ts);
        repeat (4) @(posedge clk);
        // entry content via host read
        host_read(10'd0, b0); host_read(10'd1, b1);
        host_read(10'd2, b2); host_read(10'd3, b3); host_read(10'd4, b4);
        check({b0,b1,b2,b3} === exp_ts, "EDGE: entry0 ts");
        check(b4 === 8'h01, "EDGE: entry0 pins=0x01");

        // ---------------- PATTERN mode (1-cycle match -> 1 entry) ----------------
        obs_en = 0; repeat (2) @(posedge clk);
        pat_mask = 8'h06; pat_value = 8'h04;      // (pins&6)==4
        arm(2'b10);
        set_pins(8'h04, exp_ts);
        @(posedge clk); #1;                       // trigger edge
        set_pins(8'h00, dummy_ts);                // match held exactly 1 cycle
        wait_ptr(8'd2, n);
        check(obs_ptr === 8'd2, "PATTERN: obs_ptr=2");
        check(n <= 6, "PATTERN: commit <= 6 cycles");
        host_read(10'd5, b0); host_read(10'd6, b1);
        host_read(10'd7, b2); host_read(10'd8, b3); host_read(10'd9, b4);
        check({b0,b1,b2,b3} === exp_ts, "PATTERN: entry1 ts");
        check(b4 === 8'h04, "PATTERN: entry1 pins=0x04");

        // ---------------- PULSE mode, pin_sel=2 ----------------
        obs_en = 0; repeat (2) @(posedge clk);
        pin_sel = 3'd2;
        arm(2'b11);
        set_pins(8'h04, exp_ts);                  // pin2 rise
        @(posedge clk); #1;
        wait_ptr(8'd3, n);
        check(obs_ptr === 8'd3, "PULSE: obs_ptr=3 on pin2 edge");
        check(n <= 6, "PULSE: commit <= 6 cycles");
        set_pins(8'h00, dummy_ts);                // pin2 fall -> another edge
        @(posedge clk); #1;
        wait_ptr(8'd4, n);
        check(obs_ptr === 8'd4, "PULSE: falling edge also commits");
        repeat (4) @(posedge clk);

        // ---------------- watermark ----------------
        wmark = 8'd2;
        @(negedge clk); #1; obs_clr = 1;
        @(negedge clk); #1; obs_clr = 0;
        repeat (2) @(posedge clk);
        check(obs_ptr === 8'd0, "OBS_CLR: obs_ptr=0");
        obs_en = 0; repeat (2) @(posedge clk);
        edge_mask = 8'h01; edge_cfg = 16'h0001;
        arm(2'b01);
        begin
            reg wm_seen; wm_seen = 0;
            fork
                begin
                    repeat (2) begin
                        set_pins(8'h01, dummy_ts);
                        @(posedge clk); #1;
                        wait_ptr(obs_ptr + 8'd1, n);
                        set_pins(8'h00, dummy_ts);
                        repeat (2) @(posedge clk);
                    end
                end
                begin
                    to = 0;
                    while (!trace_wm && to < 120) begin @(negedge clk); #1; to = to + 1; end
                    wm_seen = trace_wm;
                end
            join
            check(wm_seen === 1'b1, "watermark strobe at ptr==wmark");
            check(obs_ptr === 8'd2, "obs_ptr=2 after 2 triggers");
        end

        // ---------------- saturation at 204 ----------------
        for (i = 0; i < 202; i = i + 1) begin
            set_pins(8'h01, dummy_ts);
            repeat (8) @(posedge clk);
            set_pins(8'h00, dummy_ts);
            repeat (2) @(posedge clk);
        end
        check(obs_ptr === 8'd204, "obs_ptr saturates at 204");
        // one more trigger -> trace_full strobe, ptr stays 204
        begin
            reg tf_seen; tf_seen = 0;
            fork
                begin
                    set_pins(8'h01, dummy_ts);
                    repeat (14) @(posedge clk);
                    set_pins(8'h00, dummy_ts);
                    repeat (2) @(posedge clk);
                end
                begin
                    to = 0;
                    while (!trace_full && to < 80) begin @(negedge clk); #1; to = to + 1; end
                    tf_seen = trace_full;
                end
            join
            check(tf_seen === 1'b1, "trace_full strobe when saturated");
            check(obs_ptr === 8'd204, "obs_ptr stays 204");
        end

        // ---------------- host read during capture (arbitration) ----------------
        @(negedge clk); #1; obs_clr = 1;
        @(negedge clk); #1; obs_clr = 0;
        repeat (2) @(posedge clk);
        obs_en = 0; repeat (2) @(posedge clk);
        edge_mask = 8'h01; edge_cfg = 16'h0001;
        arm(2'b01);
        set_pins(8'h01, exp_ts);                  // fire; read while committing
        host_read(10'd0, b0); host_read(10'd1, b1);
        host_read(10'd2, b2); host_read(10'd3, b3); host_read(10'd4, b4);
        check({b0,b1,b2,b3} === exp_ts, "host read during capture: ts intact");
        check(b4 === 8'h01, "host read during capture: pins intact");

        $display("done: %0d checks, %0s", nchecks, fail ? "FAIL" : "PASS");
        $finish;
    end

    initial begin
        #120000000;
        $display("FAIL: watchdog timeout");
        $finish;
    end
endmodule
