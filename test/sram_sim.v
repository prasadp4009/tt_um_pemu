/*
 * sram_sim.v -- SIM-ONLY behavioral models of the two IHP SRAM macros.
 *
 * *** SIMULATION ONLY -- NEVER FOR SYNTHESIS ***
 *
 * These models replicate the FUNCTIONAL (non-timing) behavior of the PDK
 * Verilog models for RM_IHPSG13_1P_256x32_c2_bm_bist (IMEM) and
 * RM_IHPSG13_1P_1024x8_c2_bm_bist (trace), minus the `specify` timing
 * blocks and $stop checks that Verilator cannot parse:
 *   - synchronous 1P SRAM, 1-cycle registered read latency
 *   - read  := A_MEN & A_REN  -> DOUT <= mem[ADDR] next edge
 *   - write := A_MEN & A_WEN  -> mem[ADDR] <= (mem & ~BM) | (DIN & BM)
 *   - WEN & REN               -> write-through (DOUT gets the written word)
 *   - A_DLY / BIST ports are accepted and ignored (BIST tied off in the DUT)
 *
 * The DUT instantiates the real PDK macros (same module names); simulators
 * pick these models by compiling sram_sim.v INSTEAD of the PDK Verilog.
 * Yosys synthesis treats the macros as blackboxes (see test/synth/).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none

// ----------------------------------------------------------------------
// IMEM: 256 x 32
// ----------------------------------------------------------------------
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */  // A_DLY/BIST tie-offs: accepted, ignored
module RM_IHPSG13_1P_256x32_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [7:0]  A_ADDR,
    input  wire [31:0] A_DIN,
    input  wire        A_DLY,
    output wire [31:0] A_DOUT,
    input  wire [31:0] A_BM,
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_EN,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [7:0]  A_BIST_ADDR,
    input  wire [31:0] A_BIST_DIN,
    input  wire [31:0] A_BIST_BM
);
    reg [31:0] memory [0:255];
    reg [31:0] dr_r;

    // X-free init for Verilator (PDK functional model inits to X).
    integer i;
    initial begin
        dr_r = 32'd0;
        for (i = 0; i < 256; i = i + 1) memory[i] = 32'd0;
    end

    wire [31:0] wdata = (memory[A_ADDR] & ~A_BM) | (A_DIN & A_BM);

    always @(posedge A_CLK) begin
        if (A_MEN && A_WEN) begin
            memory[A_ADDR] <= wdata;
            if (A_REN) dr_r <= wdata;      // write-through
        end else if (A_MEN && A_REN) begin
            dr_r <= memory[A_ADDR];
        end
    end

    assign A_DOUT = dr_r;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */


// ----------------------------------------------------------------------
// Trace: 1024 x 8
// ----------------------------------------------------------------------
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */  // A_DLY/BIST tie-offs: accepted, ignored
module RM_IHPSG13_1P_1024x8_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [9:0]  A_ADDR,
    input  wire [7:0]  A_DIN,
    input  wire        A_DLY,
    output wire [7:0]  A_DOUT,
    input  wire [7:0]  A_BM,
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_EN,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [9:0]  A_BIST_ADDR,
    input  wire [7:0]  A_BIST_DIN,
    input  wire [7:0]  A_BIST_BM
);
    reg [7:0] memory [0:1023];
    reg [7:0] dr_r;

    integer i;
    initial begin
        dr_r = 8'd0;
        for (i = 0; i < 1024; i = i + 1) memory[i] = 8'd0;
    end

    wire [7:0] wdata = (memory[A_ADDR] & ~A_BM) | (A_DIN & A_BM);

    always @(posedge A_CLK) begin
        if (A_MEN && A_WEN) begin
            memory[A_ADDR] <= wdata;
            if (A_REN) dr_r <= wdata;      // write-through
        end else if (A_MEN && A_REN) begin
            dr_r <= memory[A_ADDR];
        end
    end

    assign A_DOUT = dr_r;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */


`default_nettype wire
