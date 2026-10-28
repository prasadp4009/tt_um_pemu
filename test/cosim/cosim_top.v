/*
 * cosim_top.v -- Co-simulation DUT wrapper (NOT for synthesis).
 *
 * Instantiates tt_um_pemu_pe + tt_um_pemu_observer + the two IHP SRAM
 * functional models, wired exactly as in src/tt_um_pemu.v, but WITHOUT the
 * host block. The testbench owns the FIFOs (Python/Verilog model) and the
 * program port is tied idle; IMEM is preloaded hierarchically by the TB.
 *
 * Idle tie-offs (per tt_um_pemu.v integration):
 *   prog_mode=0, prog_wen=0, prog_ren=0, ena=1,
 *   evt_clr=0, halt_req=0, cfg_dirty_set=0,
 *   observer pin_sel=0, host_rd_en=0.
 * tx_empty/rx_full are TB-driven from the FIFO models.
 */
`default_nettype none

module cosim_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  pins_in,
    output wire [7:0]  pins_out,
    output wire [7:0]  pins_oe,
    output wire [15:0] pmode_out,
    input  wire [15:0] rx_data,
    input  wire        rx_empty,
    output wire        rx_pull,
    output wire [15:0] tx_data,
    input  wire        tx_full,
    output wire        tx_push,
    input  wire        tx_empty,
    input  wire        rx_full,
    output wire [7:0]  obs_ptr,
    output wire        pe_halted
);
    // PE <-> IMEM macro
    wire [8:0]  imem_addr;
    wire [7:0]  imem_men, imem_wen, imem_ren;
    wire [31:0] imem_din, imem_dout;
    wire [31:0] imem_bm;

    // PE <-> observer
    wire [31:0] pe_cycles;
    wire [7:0]  pe_pins_sync;
    wire        pe_obs_en;
    wire        pe_trig_wr_strobe;
    wire [1:0]  pe_trig_mode;
    wire [7:0]  pe_pat_mask;
    wire [7:0]  pe_pat_value;
    wire [7:0]  pe_edge_mask;
    wire [15:0] pe_edge_cfg;
    wire [7:0]  pe_wmark;
    wire [7:0]  pe_prescaler;
    wire        pe_obs_clr;
    wire [7:0]  obs_ptr_w;
    wire        obs_trace_full;
    wire        obs_trace_wm;

    // Observer <-> trace macro
    wire [9:0] tmem_addr;
    wire       tmem_men, tmem_wen, tmem_ren;
    wire [7:0] tmem_din, tmem_dout;
    wire [7:0] tmem_bm;

    // PE events (unobserved, tied)
    wire [3:0] evt_code_nc;
    wire       evt_pulse_nc;
    wire       pe_running_nc;
    wire       timeout_sticky_nc, config_err_nc;
    wire [31:0] prog_dout_nc;

    assign obs_ptr   = obs_ptr_w;
    assign pe_halted = u_pe.pe_halted;

    tt_um_pemu_pe u_pe (
        .clk           (clk),
        .rst_n         (rst_n),
        .ena           (1'b1),
        .prog_mode     (1'b0),
        .prog_addr     (9'b0),
        .prog_din      (32'b0),
        .prog_wen      (1'b0),
        .prog_ren      (1'b0),
        .prog_dout     (prog_dout_nc),
        .imem_addr     (imem_addr),
        .imem_men      (imem_men),
        .imem_wen      (imem_wen),
        .imem_ren      (imem_ren),
        .imem_din      (imem_din),
        .imem_dout     (imem_dout),
        .imem_bm       (imem_bm),
        .pins_out      (pins_out),
        .pins_oe       (pins_oe),
        .pins_in       (pins_in),
        .pmode_out     (pmode_out),
        .tx_data       (tx_data),
        .tx_push       (tx_push),
        .tx_full       (tx_full),
        .rx_data       (rx_data),
        .rx_pull       (rx_pull),
        .rx_empty      (rx_empty),
        .evt_code      (evt_code_nc),
        .evt_pulse     (evt_pulse_nc),
        .evt_clr       (16'b0),
        .obs_ptr       (obs_ptr_w),
        .trace_full    (obs_trace_full),
        .trace_wm      (obs_trace_wm),
        .cycles        (pe_cycles),
        .pins_sync     (pe_pins_sync),
        .obs_en        (pe_obs_en),
        .trig_wr_strobe(pe_trig_wr_strobe),
        .trig_mode     (pe_trig_mode),
        .pat_mask      (pe_pat_mask),
        .pat_value     (pe_pat_value),
        .edge_mask     (pe_edge_mask),
        .edge_cfg      (pe_edge_cfg),
        .wmark         (pe_wmark),
        .prescaler     (pe_prescaler),
        .obs_clr       (pe_obs_clr),
        .halt_req      (1'b0),
        .cfg_dirty_set (1'b0),
        .tx_empty      (tx_empty),
        .rx_full       (rx_full),
        .timeout_sticky(timeout_sticky_nc),
        .config_err    (config_err_nc),
        .pe_running    (pe_running_nc),
        .pe_halted     ()
    );

    tt_um_pemu_observer u_obs (
        .clk           (clk),
        .rst_n         (rst_n),
        .ena           (1'b1),
        .cycles        (pe_cycles),
        .pins_sync     (pe_pins_sync),
        .obs_en        (pe_obs_en),
        .trig_wr_strobe(pe_trig_wr_strobe),
        .trig_mode     (pe_trig_mode),
        .pin_sel       (3'b0),
        .edge_mask     (pe_edge_mask),
        .edge_cfg      (pe_edge_cfg),
        .pat_mask      (pe_pat_mask),
        .pat_value     (pe_pat_value),
        .wmark         (pe_wmark),
        .prescaler     (pe_prescaler),
        .obs_clr       (pe_obs_clr),
        .tmem_addr     (tmem_addr),
        .tmem_men      (tmem_men),
        .tmem_wen      (tmem_wen),
        .tmem_ren      (tmem_ren),
        .tmem_din      (tmem_din),
        .tmem_dout     (tmem_dout),
        .tmem_bm       (tmem_bm),
        .host_rd_en    (1'b0),
        .host_rd_addr  (10'b0),
        .host_rd_data  (),
        .host_rd_ack   (),
        .obs_ptr       (obs_ptr_w),
        .trace_full    (obs_trace_full),
        .trace_wm      (obs_trace_wm)
    );

    RM_IHPSG13_1P_512x32_c2_bm_bist u_imem (
        .A_CLK      (clk),
        .A_MEN      (imem_men[0]),
        .A_WEN      (imem_wen[0]),
        .A_REN      (imem_ren[0]),
        .A_ADDR     (imem_addr),
        .A_DIN      (imem_din),
        .A_DOUT     (imem_dout),
        .A_BM       (imem_bm),
        .A_DLY      (1'b1),
        .A_BIST_EN  (1'b0),
        .A_BIST_CLK (1'b0),
        .A_BIST_MEN (1'b0),
        .A_BIST_WEN (1'b0),
        .A_BIST_REN (1'b0),
        .A_BIST_ADDR(9'b0),
        .A_BIST_DIN (32'b0),
        .A_BIST_BM  (32'b0)
    );

    RM_IHPSG13_1P_1024x8_c2_bm_bist u_tmem (
        .A_CLK      (clk),
        .A_MEN      (tmem_men),
        .A_WEN      (tmem_wen),
        .A_REN      (tmem_ren),
        .A_ADDR     (tmem_addr),
        .A_DIN      (tmem_din),
        .A_DOUT     (tmem_dout),
        .A_BM       (tmem_bm),
        .A_DLY      (1'b1),
        .A_BIST_EN  (1'b0),
        .A_BIST_CLK (1'b0),
        .A_BIST_MEN (1'b0),
        .A_BIST_WEN (1'b0),
        .A_BIST_REN (1'b0),
        .A_BIST_ADDR(10'b0),
        .A_BIST_DIN (8'b0),
        .A_BIST_BM  (8'b0)
    );

endmodule
`default_nettype wire
