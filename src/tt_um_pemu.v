/*
 * tt_um_pemu.v -- TEMPO-32 Protocol Emulator ASIC top level (Tiny Tapeout).
 *
 * Worker D (integration), Phase 6. Integrates the three committed blocks
 * with the two foundry SRAM macros:
 *   - tt_um_pemu_pe       : TEMPO-32 PE core (Worker A)
 *   - tt_um_pemu_observer : trace observer (Worker B)
 *   - tt_um_pemu_host     : 2-wire host port (Worker C, amended Worker D)
 *   - RM_IHPSG13_1P_256x32_c2_bm_bist  : IMEM  (256x32, program store)
 *   - RM_IHPSG13_1P_1024x8_c2_bm_bist  : trace (1024x8, observer entries)
 *
 * Pin map (tt_um_* standard):
 *   ui_in[0]  -> host hp_rx          uo_out[0] -> host hp_tx
 *   ui_in[7:1] unused                uo_out[7:1] = 0
 *   uio[i]    <-> pe.pins_out[i] / pe.pins_oe[i] / pe.pins_in[i]
 *                 (pmode_out is TB-use-only per coordinator scope)
 *
 * Structural invariants (checked by test/tb_top.v + scripts/q4_check.sh):
 *   - Q4: NO data path between the PE and the trace SRAM. The PE only sees
 *     obs_ptr (read-only pointer), trace_full and trace_wm event strobes
 *     from the observer; the trace macro's data/address/enable lines are
 *     driven ONLY by the observer. (PE pins feed the observer's pin
 *     sampler, which is a control/monitoring path, not trace-data access.)
 *   - prog_mode discipline: the host deasserts prog_wen >= 1 cycle before
 *     dropping prog_mode (its FSM sequences LOAD_IMEM writes through
 *     S_LDW with wen pulsed only there).
 *   - A_DLY=1 on both macros (mandatory per SRAM_TRIAL.md); all BIST
 *     controls/data/address tied 0.
 *
 * Known integration deviations (coordinator-visible):
 *   - PIN_SEL: the observer requires pin_sel[2:0]; the PE's committed port
 *     list does not expose pin_sel_r (only the authorized prog_ren input
 *     was added). pin_sel is tied 3'b0 here. PULSE-mode triggering is
 *     therefore limited to pulse source 0; EDGE/PATTERN modes are
 *     unaffected (they use pins_sync + masks only). A PE output amendment
 *     for pin_sel_r is recommended for full contract coverage.
 *   - RD_STATUS[1] (TRACE_FULL) reflects the observer's 1-cycle trace_full
 *     strobe as a level (Worker C port semantics); the sticky firmware-
 *     visible latch is PE STATUS[3]. The strobe fires once per trigger
 *     ignored due to saturation, so the bit is observable under sustained
 *     triggers while full.
 *   - pmode_out (open-drain mode) is not gated into uio_oe (coordinator
 *     scope: pmode_out is TB-use-only); testbenches resolve the pad state
 *     from pe.pins_out/pe.pins_oe/pe.pmode_out directly.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

module tt_um_pemu (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // ------------------------------------------------------------------
    // Unused TT inputs
    // ------------------------------------------------------------------
    wire _unused = &{ui_in[7:1], 1'b0};

    // ------------------------------------------------------------------
    // PE <-> host program port
    // ------------------------------------------------------------------
    wire        prog_mode;
    wire [7:0]  prog_addr;
    wire [31:0] prog_din;
    wire        prog_wen;
    wire        prog_ren;
    wire [31:0] prog_dout;

    // ------------------------------------------------------------------
    // PE <-> IMEM macro
    // ------------------------------------------------------------------
    wire [7:0]  imem_addr;
/* verilator lint_off UNUSEDSIGNAL */  // PE replicates enables x8; bit 0 drives the macro
    wire [7:0]  imem_men, imem_wen, imem_ren;
/* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] imem_din, imem_dout;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] imem_bist_dout_nc; // BIST disabled; macro output unused
    wire [7:0]  tmem_bist_dout_nc; // BIST disabled; macro output unused
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] imem_bm;

    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // PE <-> observer control/status
    // ------------------------------------------------------------------
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

    wire [7:0]  obs_ptr;
    wire        obs_trace_full;   // 1-cycle strobe -> PE STATUS[3] + host RD_STATUS[1]
    wire        obs_trace_wm;     // 1-cycle strobe -> PE sticky_trace_wm

    // ------------------------------------------------------------------
    // Observer <-> trace macro
    // ------------------------------------------------------------------
    wire [9:0]  tmem_addr;
    wire        tmem_men, tmem_wen, tmem_ren;
    wire [7:0]  tmem_din, tmem_dout;
    wire [7:0]  tmem_bm;

    // ------------------------------------------------------------------
    // Host <-> observer trace-read port
    // ------------------------------------------------------------------
    wire        host_rd_en;
    wire [9:0]  host_rd_addr;
    wire [7:0]  host_rd_data;
    wire        host_rd_ack;

    // ------------------------------------------------------------------
    // PE <-> host FIFOs / events / control
    // ------------------------------------------------------------------
    wire [15:0] tx_data, rx_data;
    wire        tx_push, tx_full, rx_pull, rx_empty;
    wire [3:0]  evt_code;
    wire        evt_pulse;
    wire        halt_req;
    wire        tx_empty, rx_full;
    wire        timeout_sticky, config_err;
    wire        pe_running, pe_halted;

    // ------------------------------------------------------------------
    // PE protocol pins
    // ------------------------------------------------------------------
    wire [7:0]  pe_pins_out;
    wire [7:0]  pe_pins_oe;
    wire [7:0]  pe_pins_in;
    /* verilator lint_off UNUSED */
    wire [15:0] pmode_out_unused;    // TB-use-only (pad resolution model)
    /* verilator lint_on UNUSED */

    assign pe_pins_in = uio_in;
    assign uio_out    = pe_pins_out;
    assign uio_oe     = pe_pins_oe;

    // ------------------------------------------------------------------
    // Host 2-wire port
    // ------------------------------------------------------------------
    wire hp_rx, hp_tx;
    assign hp_rx    = ui_in[0];
    assign uo_out   = {7'b0, hp_tx};

    // ------------------------------------------------------------------
    // RD_STATUS live trace_wm: OBS_PTR >= WMARK, WMARK=0 -> 0
    // ------------------------------------------------------------------
    wire trace_wm_live = (pe_wmark != 8'd0) && (obs_ptr >= pe_wmark);

    // ------------------------------------------------------------------
    // PE core
    // ------------------------------------------------------------------
    tt_um_pemu_pe u_pe (
        .clk           (clk),
        .rst_n         (rst_n),
        .ena           (ena),
        .prog_mode     (prog_mode),
        .prog_addr     (prog_addr),
        .prog_din      (prog_din),
        .prog_wen      (prog_wen),
        .prog_ren      (prog_ren),
        .prog_dout     (prog_dout),
        .imem_addr     (imem_addr),
        .imem_men      (imem_men),
        .imem_wen      (imem_wen),
        .imem_ren      (imem_ren),
        .imem_din      (imem_din),
        .imem_dout     (imem_dout),
        .imem_bm       (imem_bm),
        .pins_out      (pe_pins_out),
        .pins_oe       (pe_pins_oe),
        .pins_in       (pe_pins_in),
        .pmode_out     (pmode_out_unused),
        .tx_data       (tx_data),
        .tx_push       (tx_push),
        .tx_full       (tx_full),
        .rx_data       (rx_data),
        .rx_pull       (rx_pull),
        .rx_empty      (rx_empty),
        .evt_code      (evt_code),
        .evt_pulse     (evt_pulse),
        .evt_clr       (16'b0),          // D3 deferred: host clears via FIFO read
        .obs_ptr       (obs_ptr),
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
        .halt_req      (halt_req),
        .cfg_dirty_set (1'b0),          // D3 deferred: config-change event unused
        .tx_empty      (tx_empty),
        .rx_full       (rx_full),
        .timeout_sticky(timeout_sticky),
        .config_err    (config_err),
        .pe_running    (pe_running),
        .pe_halted     (pe_halted)
    );

    // ------------------------------------------------------------------
    // Observer (trace engine)
    // NOTE: pin_sel tied 0 -- PE port list does not expose pin_sel_r
    // (integration deviation, see header).
    // ------------------------------------------------------------------
    tt_um_pemu_observer u_obs (
        .clk       (clk),
        .rst_n     (rst_n),
        .ena       (ena),
        .cycles    (pe_cycles),
        .pins_sync (pe_pins_sync),
        .obs_en    (pe_obs_en),
        .trig_wr_strobe (pe_trig_wr_strobe),
        .trig_mode (pe_trig_mode),
        .pin_sel   (3'b0),
        .edge_mask (pe_edge_mask),
        .edge_cfg  (pe_edge_cfg),
        .pat_mask  (pe_pat_mask),
        .pat_value (pe_pat_value),
        .wmark     (pe_wmark),
        .prescaler (pe_prescaler),
        .obs_clr   (pe_obs_clr),
        .tmem_addr (tmem_addr),
        .tmem_men  (tmem_men),
        .tmem_wen  (tmem_wen),
        .tmem_ren  (tmem_ren),
        .tmem_din  (tmem_din),
        .tmem_dout (tmem_dout),
        .tmem_bm   (tmem_bm),
        .host_rd_en  (host_rd_en),
        .host_rd_addr (host_rd_addr),
        .host_rd_data (host_rd_data),
        .host_rd_ack  (host_rd_ack),
        .obs_ptr   (obs_ptr),
        .trace_full(obs_trace_full),
        .trace_wm  (obs_trace_wm)
    );

    // ------------------------------------------------------------------
    // Host port
    // ------------------------------------------------------------------
    tt_um_pemu_host u_host (
        .clk         (clk),
        .rst_n       (rst_n),
        .ena         (ena),
        .hp_rx       (hp_rx),
        .hp_tx       (hp_tx),
        .tx_data     (tx_data),
        .tx_push     (tx_push),
        .tx_full     (tx_full),
        .rx_data     (rx_data),
        .rx_pull     (rx_pull),
        .rx_empty    (rx_empty),
        .evt_code    (evt_code),
        .evt_pulse   (evt_pulse),
        .prog_mode   (prog_mode),
        .prog_addr   (prog_addr),
        .prog_din    (prog_din),
        .prog_wen    (prog_wen),
        .prog_ren    (prog_ren),
        .prog_dout   (prog_dout),
        .host_rd_en  (host_rd_en),
        .host_rd_addr(host_rd_addr),
        .host_rd_data(host_rd_data),
        .host_rd_ack (host_rd_ack),
        .pe_running  (pe_running),
        .pe_halted   (pe_halted),
        .obs_ptr     (obs_ptr),
        .trace_full  (obs_trace_full),
        .trace_wm    (trace_wm_live),
        .halt_req    (halt_req),
        .tx_empty    (tx_empty),
        .rx_full     (rx_full),
        .timeout_sticky(timeout_sticky),
        .config_err  (config_err)
    );

    // ------------------------------------------------------------------
    // IMEM macro: RM_IHPSG13_1P_256x32_c2_bm_bist
    // Bit 0 of the replicated PE enables drives the scalar macro control.
    // ------------------------------------------------------------------
    RM_IHPSG13_1P_256x32_c2_bm_bist u_imem (
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
        .A_BIST_ADDR(8'b0),
        .A_BIST_DIN (32'b0),
        .A_BIST_BM  (32'b0),
        .A_BIST_DOUT(imem_bist_dout_nc)
    );

    // ------------------------------------------------------------------
    // Trace macro: RM_IHPSG13_1P_1024x8_c2_bm_bist
    // ------------------------------------------------------------------
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
        .A_BIST_BM  (8'b0),
        .A_BIST_DOUT(tmem_bist_dout_nc)
    );

endmodule
`default_nettype wire
