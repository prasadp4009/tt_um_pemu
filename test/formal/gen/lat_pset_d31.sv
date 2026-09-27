`default_nettype none
module formal_top (input wire clk);
    reg [3:0] rst_cnt = 4'd0;
    wire rst_n = (rst_cnt == 4'd8);
    always @(posedge clk) if (rst_cnt != 4'd8) rst_cnt <= rst_cnt + 4'd1;
    reg [9:0] cyc = 10'd0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 10'd1;
    reg [7:0] addr_q = 8'd0;
    wire [7:0] imem_addr;
    wire [31:0] imem_dout;
    always @(posedge clk) addr_q <= imem_addr;

    function [31:0] rom_word;
        input [7:0] a;
        begin
            rom_word = {6'd0, 5'd31, 21'd0};
        end
    endfunction
    assign imem_dout = rom_word(addr_q);

    wire h_exec_active;
    wire [5:0] h_opcode;
    wire [4:0] h_dly;
    wire [31:0] h_instr;
    wire [2:0] h_state;
    wire [7:0] h_pc;
    wire h_tick_en;
    wire [7:0] h_sync0, h_sync1;
    wire [7:0] h_pin_drv, h_pmask;
    wire [31:0] h_ts;
    wire [15:0] h_cts_hi;
    wire [7:0] h_cts_pins;
    wire [12:0] h_ecnt;
    wire h_wait_hit, h_w_entry_hit;
    wire [4:0] h_sticky;
    wire [15:0] h_regs3, h_regs6, h_regs7;
    wire [7:0] h_pins_sync;

    tt_um_pemu_pe dut (
        .clk(clk), .rst_n(rst_n), .ena(1'b1),
        .prog_mode(1'b0), .prog_addr(8'd0), .prog_din(32'd0),
        .prog_wen(1'b0), .prog_ren(1'b0), .prog_dout(),
        .imem_addr(imem_addr), .imem_men(), .imem_ren(), .imem_wen(),
        .imem_din(), .imem_bm(), .imem_dout(imem_dout),
        .pins_in(8'd0), .pins_out(), .pins_oe(), .pins_sync(h_pins_sync),
        .tx_data(), .tx_push(), .tx_full(1'b0),
        .rx_data(16'd0), .rx_pull(), .rx_empty(1'b1),
        .evt_code(), .evt_pulse(), .pe_running(), .pe_halted(),
        .timeout_sticky(), .config_err(), .cycles(),
        .trig_mode(), .trig_wr_strobe(), .edge_mask(), .edge_cfg(),
        .pat_mask(), .pat_value(), .wmark(), .prescaler(),
        .obs_en(), .obs_clr(), .obs_ptr(8'd0),
        .trace_full(1'b0), .trace_wm(1'b0), .pmode_out(),
        .evt_clr(16'd0), .halt_req(1'b0), .cfg_dirty_set(1'b0),
        .tx_empty(1'b1), .rx_full(1'b0),
        .exec_active(h_exec_active), .opcode(h_opcode), .dly(h_dly),
        .instr(h_instr), .state(h_state), .pc(h_pc),
        .tick_en(h_tick_en), .sync0(h_sync0), .sync1(h_sync1),
        .pin_drv(h_pin_drv), .pmask(h_pmask),
        .ts(h_ts), .cts_hi(h_cts_hi), .cts_pins(h_cts_pins),
        .ecnt(h_ecnt), .wait_hit(h_wait_hit), .w_entry_hit(h_w_entry_hit),
        .sticky(h_sticky),
        .\regs[3] (h_regs3), .\regs[6] (h_regs6), .\regs[7] (h_regs7)
    );


    wire base_lat = h_exec_active && (h_opcode == 6'd0) && (h_dly == 5'd31);
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_lat, 1) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 2 ||
        !$past(base_lat, 2) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 3 ||
        !$past(base_lat, 3) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 4 ||
        !$past(base_lat, 4) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 5 ||
        !$past(base_lat, 5) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 6 ||
        !$past(base_lat, 6) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 7 ||
        !$past(base_lat, 7) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 8 ||
        !$past(base_lat, 8) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 9 ||
        !$past(base_lat, 9) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 10 ||
        !$past(base_lat, 10) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 11 ||
        !$past(base_lat, 11) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 12 ||
        !$past(base_lat, 12) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        !$past(base_lat, 13) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 14 ||
        !$past(base_lat, 14) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 15 ||
        !$past(base_lat, 15) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 16 ||
        !$past(base_lat, 16) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 17 ||
        !$past(base_lat, 17) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 18 ||
        !$past(base_lat, 18) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 19 ||
        !$past(base_lat, 19) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 20 ||
        !$past(base_lat, 20) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 21 ||
        !$past(base_lat, 21) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 22 ||
        !$past(base_lat, 22) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 23 ||
        !$past(base_lat, 23) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 24 ||
        !$past(base_lat, 24) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 25 ||
        !$past(base_lat, 25) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 26 ||
        !$past(base_lat, 26) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 27 ||
        !$past(base_lat, 27) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 28 ||
        !$past(base_lat, 28) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 29 ||
        !$past(base_lat, 29) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 30 ||
        !$past(base_lat, 30) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 31 ||
        !$past(base_lat, 31) || !h_exec_active);
    always @(posedge clk) assert (!rst_n || cyc < 32 ||
        !$past(base_lat, 32) || h_exec_active);

endmodule
`default_nettype wire
