`default_nettype none
module formal_top (input wire clk);
    reg [3:0] rst_cnt = 4'd0;
    wire rst_n = (rst_cnt == 4'd8);
    always @(posedge clk) if (rst_cnt != 4'd8) rst_cnt <= rst_cnt + 4'd1;
    reg [9:0] cyc = 10'd0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 10'd1;
    reg [7:0] pins_sync_r = 8'd0;
    always @(posedge clk) pins_sync_r <= $anyseq;
    reg [31:0] cyc_cnt = 32'd0;
    always @(posedge clk) cyc_cnt <= cyc_cnt + 32'd1;
    wire [7:0] h_obs_ptr;
    wire h_trace_wm;
    tt_um_pemu_observer dut (
        .clk(clk), .rst_n(rst_n), .ena(1'b1),
        .cycles(cyc_cnt), .pins_sync(pins_sync_r),
        .trig_mode(2'b01), .trig_wr_strobe(1'b0),
        .edge_mask(8'h01), .edge_cfg(16'h0001),
        .pat_mask(8'd0), .pat_value(8'd0), .pin_sel(3'd0),
        .wmark(8'd5), .prescaler(8'd0), .obs_en(1'b1), .obs_clr(1'b0),
        .obs_ptr(h_obs_ptr), .trace_full(), .trace_wm(h_trace_wm),
        .tmem_addr(), .tmem_men(), .tmem_ren(), .tmem_wen(),
        .tmem_din(), .tmem_bm(), .tmem_dout(8'd0),
        .host_rd_en(1'b0), .host_rd_addr(10'd0),
        .host_rd_data(), .host_rd_ack()
    );

    // watermark fires exactly on the commit that reaches wmark (5)
    always @(posedge clk) assert (!rst_n || cyc < 12 ||
        !((h_obs_ptr == $past(h_obs_ptr) + 8'd1) && h_obs_ptr == 8'd5) || h_trace_wm);
    // no spurious strobe: fire implies ptr just reached wmark
    always @(posedge clk) assert (!rst_n || cyc < 12 || !h_trace_wm ||
        ($past(h_obs_ptr) + 8'd1 == 8'd5 && h_obs_ptr == 8'd5));
    // single-cycle strobe
    always @(posedge clk) assert (!rst_n || cyc < 12 || !h_trace_wm || !$past(h_trace_wm));

endmodule
`default_nettype wire
