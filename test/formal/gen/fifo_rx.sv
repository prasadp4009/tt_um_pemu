`default_nettype none
module formal_top (input wire clk);
    reg [3:0] rst_cnt = 4'd0;
    wire rst_n = (rst_cnt == 4'd8);
    always @(posedge clk) if (rst_cnt != 4'd8) rst_cnt <= rst_cnt + 4'd1;
    reg [9:0] cyc = 10'd0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 10'd1;
    reg [15:0] tx_data_r = 16'd0;
    always @(posedge clk) tx_data_r <= $anyseq;
    reg tx_push_r = 1'b0;
    always @(posedge clk) tx_push_r <= $anyseq;
    reg rx_pull_r = 1'b0;
    always @(posedge clk) rx_pull_r <= $anyseq;
    reg hp_rx_r = 1'b1;
    always @(posedge clk) hp_rx_r <= $anyseq;
    wire [4:0] h_tx_cnt, h_rx_cnt;
    wire [3:0] h_tx_wptr, h_tx_rptr, h_rx_wptr, h_rx_rptr;
    wire h_tx_push_ok, h_tx_pop_ok, h_rx_push_ok, h_rx_pop_ok;
    wire h_tx_full, h_tx_empty, h_rx_empty, h_rx_full;
    wire [15:0] h_rx_data;
    wire h_rx_fw_en;
    wire [15:0] h_rx_fw_data;
    wire [15:0] h_tx_mem0, h_rx_mem0;
    wire [15:0] h_tx_mem1, h_rx_mem1;
    wire [15:0] h_tx_mem2, h_rx_mem2;
    wire [15:0] h_tx_mem3, h_rx_mem3;
    wire [15:0] h_tx_mem4, h_rx_mem4;
    wire [15:0] h_tx_mem5, h_rx_mem5;
    wire [15:0] h_tx_mem6, h_rx_mem6;
    wire [15:0] h_tx_mem7, h_rx_mem7;
    wire [15:0] h_tx_mem8, h_rx_mem8;
    wire [15:0] h_tx_mem9, h_rx_mem9;
    wire [15:0] h_tx_mem10, h_rx_mem10;
    wire [15:0] h_tx_mem11, h_rx_mem11;
    wire [15:0] h_tx_mem12, h_rx_mem12;
    wire [15:0] h_tx_mem13, h_rx_mem13;
    wire [15:0] h_tx_mem14, h_rx_mem14;
    wire [15:0] h_tx_mem15, h_rx_mem15;
    wire [15:0] h_tx_mem_arr [0:15];
    wire [15:0] h_rx_mem_arr [0:15];
    assign h_tx_mem_arr[0] = h_tx_mem0;
    assign h_rx_mem_arr[0] = h_rx_mem0;
    assign h_tx_mem_arr[1] = h_tx_mem1;
    assign h_rx_mem_arr[1] = h_rx_mem1;
    assign h_tx_mem_arr[2] = h_tx_mem2;
    assign h_rx_mem_arr[2] = h_rx_mem2;
    assign h_tx_mem_arr[3] = h_tx_mem3;
    assign h_rx_mem_arr[3] = h_rx_mem3;
    assign h_tx_mem_arr[4] = h_tx_mem4;
    assign h_rx_mem_arr[4] = h_rx_mem4;
    assign h_tx_mem_arr[5] = h_tx_mem5;
    assign h_rx_mem_arr[5] = h_rx_mem5;
    assign h_tx_mem_arr[6] = h_tx_mem6;
    assign h_rx_mem_arr[6] = h_rx_mem6;
    assign h_tx_mem_arr[7] = h_tx_mem7;
    assign h_rx_mem_arr[7] = h_rx_mem7;
    assign h_tx_mem_arr[8] = h_tx_mem8;
    assign h_rx_mem_arr[8] = h_rx_mem8;
    assign h_tx_mem_arr[9] = h_tx_mem9;
    assign h_rx_mem_arr[9] = h_rx_mem9;
    assign h_tx_mem_arr[10] = h_tx_mem10;
    assign h_rx_mem_arr[10] = h_rx_mem10;
    assign h_tx_mem_arr[11] = h_tx_mem11;
    assign h_rx_mem_arr[11] = h_rx_mem11;
    assign h_tx_mem_arr[12] = h_tx_mem12;
    assign h_rx_mem_arr[12] = h_rx_mem12;
    assign h_tx_mem_arr[13] = h_tx_mem13;
    assign h_rx_mem_arr[13] = h_rx_mem13;
    assign h_tx_mem_arr[14] = h_tx_mem14;
    assign h_rx_mem_arr[14] = h_rx_mem14;
    assign h_tx_mem_arr[15] = h_tx_mem15;
    assign h_rx_mem_arr[15] = h_rx_mem15;
    tt_um_pemu_host dut (
        .clk(clk), .rst_n(rst_n), .ena(1'b1),
        .hp_rx(hp_rx_r), .hp_tx(),
        .tx_data(tx_data_r), .tx_push(tx_push_r), .tx_full(h_tx_full),
        .rx_data(h_rx_data), .rx_pull(rx_pull_r), .rx_empty(h_rx_empty),
        .evt_code(4'd0), .evt_pulse(1'b0),
        .prog_mode(), .prog_addr(), .prog_din(), .prog_wen(),
        .prog_ren(), .prog_dout(32'd0),
        .host_rd_en(), .host_rd_addr(), .host_rd_data(8'd0), .host_rd_ack(1'b0),
        .pe_running(1'b0), .pe_halted(1'b0), .obs_ptr(8'd0),
        .trace_full(1'b0), .trace_wm(1'b0),
        .halt_req(), .tx_empty(h_tx_empty), .rx_full(h_rx_full),
        .timeout_sticky(1'b0), .config_err(1'b0),
        .tx_cnt(h_tx_cnt), .tx_wptr(h_tx_wptr), .tx_rptr(h_tx_rptr),
        .tx_push_ok(h_tx_push_ok), .tx_pop_ok(h_tx_pop_ok),
        .rx_cnt(h_rx_cnt), .rx_wptr(h_rx_wptr), .rx_rptr(h_rx_rptr),
        .rx_fw_en(h_rx_fw_en), .rx_fw_data(h_rx_fw_data),
        .rx_push_ok(h_rx_push_ok), .rx_pop_ok(h_rx_pop_ok),
        .\tx_mem[0] (h_tx_mem0), .\rx_mem[0] (h_rx_mem0),
        .\tx_mem[1] (h_tx_mem1), .\rx_mem[1] (h_rx_mem1),
        .\tx_mem[2] (h_tx_mem2), .\rx_mem[2] (h_rx_mem2),
        .\tx_mem[3] (h_tx_mem3), .\rx_mem[3] (h_rx_mem3),
        .\tx_mem[4] (h_tx_mem4), .\rx_mem[4] (h_rx_mem4),
        .\tx_mem[5] (h_tx_mem5), .\rx_mem[5] (h_rx_mem5),
        .\tx_mem[6] (h_tx_mem6), .\rx_mem[6] (h_rx_mem6),
        .\tx_mem[7] (h_tx_mem7), .\rx_mem[7] (h_rx_mem7),
        .\tx_mem[8] (h_tx_mem8), .\rx_mem[8] (h_rx_mem8),
        .\tx_mem[9] (h_tx_mem9), .\rx_mem[9] (h_rx_mem9),
        .\tx_mem[10] (h_tx_mem10), .\rx_mem[10] (h_rx_mem10),
        .\tx_mem[11] (h_tx_mem11), .\rx_mem[11] (h_rx_mem11),
        .\tx_mem[12] (h_tx_mem12), .\rx_mem[12] (h_rx_mem12),
        .\tx_mem[13] (h_tx_mem13), .\rx_mem[13] (h_rx_mem13),
        .\tx_mem[14] (h_tx_mem14), .\rx_mem[14] (h_rx_mem14),
        .\tx_mem[15] (h_tx_mem15), .\rx_mem[15] (h_rx_mem15)
    );

    always @(posedge clk) assert (!rst_n || cyc < 12 || h_rx_empty == (h_rx_cnt == 5'd0));
    always @(posedge clk) assert (!rst_n || cyc < 12 || h_rx_full == (h_rx_cnt == 5'd16));
    always @(posedge clk) assert (!rst_n || cyc < 12 || h_rx_push_ok == (h_rx_fw_en && h_rx_cnt < 5'd16));
    always @(posedge clk) assert (!rst_n || cyc < 12 || h_rx_cnt <= 5'd16);
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        $past(h_rx_push_ok,1) || $past(h_rx_pop_ok,1) || h_rx_cnt == $past(h_rx_cnt,1));
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        !$past(h_rx_push_ok,1) || $past(h_rx_pop_ok,1) || h_rx_cnt == $past(h_rx_cnt,1) + 5'd1);
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        $past(h_rx_push_ok,1) || !$past(h_rx_pop_ok,1) || h_rx_cnt == $past(h_rx_cnt,1) - 5'd1);
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        !$past(h_rx_push_ok,1) || !$past(h_rx_pop_ok,1) || h_rx_cnt == $past(h_rx_cnt,1));
    always @(posedge clk) assert (!rst_n || cyc < 13 || !$past(h_rx_push_ok,1) ||
        h_rx_mem_arr[$past(h_rx_wptr,1)] == $past(h_rx_fw_data,1));
    // read mux exact: empty reads 0, else mem[rptr]
    always @(posedge clk) assert (!rst_n || cyc < 12 ||
        h_rx_data == (h_rx_cnt == 5'd0 ? 16'h0 : h_rx_mem_arr[h_rx_rptr]));

endmodule
`default_nettype wire
