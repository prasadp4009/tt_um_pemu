/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNDRIVEN */
// sram_bb.v -- lint/synth blackboxes for the two IHP SRAM macros.
//
// The DUT instantiates the real PDK macro module names. For Verilator lint
// and Yosys synthesis these empty stubs stand in (the PDK Verilog cannot be
// parsed by Verilator and has no synth view). For functional simulation use
// test/sram_sim.v instead -- never compile both in the same run.
module RM_IHPSG13_1P_256x32_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [7:0]  A_ADDR,
    input  wire [31:0] A_DIN,
    output wire [31:0] A_DOUT,
    input  wire [31:0] A_BM,
    input  wire        A_DLY,
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [7:0]  A_BIST_ADDR,
    input  wire [31:0] A_BIST_DIN,
    input  wire [31:0] A_BIST_BM,
    input  wire        A_BIST_EN
);
endmodule

module RM_IHPSG13_1P_1024x8_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [9:0]  A_ADDR,
    input  wire [7:0]  A_DIN,
    output wire [7:0]  A_DOUT,
    input  wire [7:0]  A_BM,
    input  wire        A_DLY,
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [9:0]  A_BIST_ADDR,
    input  wire [7:0]  A_BIST_DIN,
    input  wire [7:0]  A_BIST_BM,
    input  wire        A_BIST_EN
);
endmodule
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNUSEDSIGNAL */
