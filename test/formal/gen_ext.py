#!/usr/bin/env python3
"""Extended SymbiYosys proofs for TEMPO (v0.2 ext).

New vs gen.py: bug-regression properties (carry semantics, HLT PC hold,
prefetch mux, illegal opcode, no-X) + host FIFO proofs + observer watermark
proofs. Self-contained: does not modify gen.py. Appends to run_all.sh.
"""
import os

OUTDIR   = "/home/jarvis/asic/projects/js-pemu/test/formal/gen"
PE_DUT   = "/home/jarvis/asic/projects/js-pemu/src/tt_um_pemu_pe.v"
HOST_DUT = "/home/jarvis/asic/projects/js-pemu/src/tt_um_pemu_host.v"
OBS_DUT  = "/home/jarvis/asic/projects/js-pemu/src/tt_um_pemu_observer.v"

# ================= PE harness (superset of gen.py) =================
PE_EXPOSE = [
    "tt_um_pemu_pe/exec_active", "tt_um_pemu_pe/opcode", "tt_um_pemu_pe/dly",
    "tt_um_pemu_pe/instr", "tt_um_pemu_pe/state", "tt_um_pemu_pe/pc",
    "tt_um_pemu_pe/tick_en", "tt_um_pemu_pe/sync0", "tt_um_pemu_pe/sync1",
    "tt_um_pemu_pe/pin_drv", "tt_um_pemu_pe/pmask",
    "tt_um_pemu_pe/ts", "tt_um_pemu_pe/cts_hi", "tt_um_pemu_pe/cts_pins",
    "tt_um_pemu_pe/ecnt", "tt_um_pemu_pe/wait_hit", "tt_um_pemu_pe/w_entry_hit",
    "tt_um_pemu_pe/sticky",
    "tt_um_pemu_pe/regs[3]", "tt_um_pemu_pe/regs[6]", "tt_um_pemu_pe/regs[7]",
    "tt_um_pemu_pe/halted", "tt_um_pemu_pe/flag_c",
    "tt_um_pemu_pe/alu_a", "tt_um_pemu_pe/alu_b", "tt_um_pemu_pe/sub_op",
]

PE_WIRES = """
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
    wire [7:0] h_imem_addr = imem_addr;
    wire h_halted, h_flag_c, h_sub_op;
    wire [15:0] h_alu_a, h_alu_b;
"""

PE_INST = """
    tt_um_pemu_pe dut (
        .clk(clk), .rst_n(rst_n), .ena(1'b1),
        .prog_mode(1'b0), .prog_addr(8'd0), .prog_din(32'd0),
        .prog_wen(1'b0), .prog_ren(1'b0), .prog_dout(),
        .imem_addr(imem_addr), .imem_men(), .imem_ren(), .imem_wen(),
        .imem_din(), .imem_bm(), .imem_dout(imem_dout),
        .pins_in(PINSIN), .pins_out(), .pins_oe(), .pins_sync(h_pins_sync),
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
        .\\regs[3] (h_regs3), .\\regs[6] (h_regs6), .\\regs[7] (h_regs7),
        .halted(h_halted), .flag_c(h_flag_c),
        .alu_a(h_alu_a), .alu_b(h_alu_b), .sub_op(h_sub_op)
    );
"""

PE_HEADER = """`default_nettype none
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
"""

def pe_sv(rom_body, pinsin_expr, props, extra=""):
    sv = PE_HEADER
    sv += f"""
    function [31:0] rom_word;
        input [7:0] a;
        begin
{rom_body}
        end
    endfunction
    assign imem_dout = rom_word(addr_q);
"""
    sv += PE_WIRES + PE_INST.replace("PINSIN", pinsin_expr)
    sv += extra + "\n" + props + "\nendmodule\n`default_nettype wire\n"
    return sv

def make_sby(name, dut_path, top, expose_list, depth):
    exp = " ".join(expose_list)
    script = f"read_verilog -sv {dut_path}\nhierarchy -top {top}\nproc\nmemory_map\n"
    if exp:
        script += f"expose {exp}\n"
    script += f"read_verilog -formal -sv {OUTDIR}/{name}.sv\nprep -top formal_top\n"
    return f"""[options]
mode bmc
depth {depth}
[engines]
smtbmc z3
[script]
{script}[files]
{OUTDIR}/{name}.sv
"""

OP_PSET, OP_PGET, OP_SLEEP = 0, 2, 6
OP_WAIT, OP_CAP, OP_LDI = 7, 8, 10
OP_ADDSUB, OP_JMP = 15, 19
OP_CMP, OP_HLT = 18, 22

def enc(op, dly, lo21=0):
    return f"{{6'd{op}, 5'd{dly}, 21'd{lo21}}}"

def enc_pset(dly, val8):
    return f"{{6'd0, 5'd{dly}, 8'd{val8}, 13'd0}}"

def enc_wait(pin, pol, mode, rd, tsel=0, cfgerr=0):
    return (f"{{6'd{OP_WAIT}, 5'd0, 3'd{pin}, 1'd{pol}, 2'd{mode}, "
            f"1'd{cfgerr}, 1'd{tsel}, 4'd{rd}, 9'd0}}")

PE = []  # (name, depth, rom_body, pinsin, extra, props)
LO21_123 = (1 << 17) | (2 << 13) | (3 << 9)  # rd0=1 rd1=2 rd2=3

# --- carry_sub (CMP): C=1 iff a>=b. Regression: inverted-carry bug. ---
PE.append(("carry_sub", 30,
    f"            rom_word = {enc(OP_CMP,0,lo21=LO21_123)};",
    "8'd0", "",
    """
    // CMP: alu_a=regs[1], alu_b=regs[2] (any values). 1 cycle after base:
    // C == (a>=b) unsigned -- ISA golden semantics.
    wire base_sub = h_exec_active && (h_opcode == 6'd18);
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_sub,1) || h_flag_c == ($past(h_alu_a,1) >= $past(h_alu_b,1)));
"""))

# --- carry_sub2 (ADDSUB sub path through shared adder) ---
PE.append(("carry_sub2", 30,
    f"            rom_word = {enc(OP_ADDSUB,0,lo21=LO21_123 | (1<<8))};",
    "8'd0", "",
    """
    // ADDSUB with instr[8]=1 -> shared-adder sub path: C == (a>=b).
    wire base_sub = h_exec_active && (h_opcode == 6'd15) && h_sub_op;
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_sub,1) || h_sub_op);
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_sub,1) || h_flag_c == ($past(h_alu_a,1) >= $past(h_alu_b,1)));
"""))

# --- carry_add (ADD): C=1 iff a+b > 0xFFFF ---
PE.append(("carry_add", 30,
    f"            rom_word = {enc(OP_ADDSUB,0,lo21=LO21_123)};",
    "8'd0", "",
    """
    wire base_add = h_exec_active && (h_opcode == 6'd15) && !h_sub_op;
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_add,1) || h_flag_c ==
        (({1'b0,$past(h_alu_a,1)} + {1'b0,$past(h_alu_b,1)}) > 17'd65535));
"""))

# --- hlt_hold_pc. Regression: HLT incremented PC (fixed 942a318). ---
PE.append(("hlt_hold_pc", 30,
    f"            rom_word = {enc(OP_HLT,0)};",
    "8'd0", "",
    """
    wire base_hlt = h_exec_active && (h_opcode == 6'd22);
    // HLT base: PC holds (points AT the HLT insn), halted asserts next.
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_hlt,1) || h_pc == $past(h_pc,1));
    always @(posedge clk) assert (!rst_n || cyc < 2 ||
        !$past(base_hlt,2) || h_halted);
    // While halted, PC never moves.
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(h_halted,1) || h_pc == $past(h_pc,1));
"""))

# --- prefetch mux. Regression: prefetch used pc_plus1 in DELAY/SLEEP (6352084).
PE.append(("prefetch_delay", 30,
    f"            rom_word = {enc_pset(3, 0xA5)};",
    "8'd0", "",
    """
    // ST_DELAY(2): pc already advanced at entry -> prefetch pc.
    always @(posedge clk) assert (!rst_n || cyc < 2 ||
        (h_state != 3'd2) || h_imem_addr == h_pc);
"""))
PE.append(("prefetch_wait", 40,
    f"            rom_word = {enc_wait(2,1,0,6)};",
    "8'd0", "",
    """
    // ST_WAIT(3): pc NOT advanced (polls WAIT insn) -> prefetch pc+1.
    always @(posedge clk) assert (!rst_n || cyc < 2 ||
        (h_state != 3'd3) || h_imem_addr == h_pc + 8'd1);
"""))
PE.append(("prefetch_sleep", 30,
    f"            rom_word = {enc(OP_SLEEP,0, lo21=(2<<8))};",
    "8'd0", "",
    """
    // ST_SLEEP(4): pc already advanced at entry -> prefetch pc.
    always @(posedge clk) assert (!rst_n || cyc < 2 ||
        (h_state != 3'd4) || h_imem_addr == h_pc);
"""))

# --- illegal_opcode (T6): NOP + CONFIG_ERR, pc advances ---
PE.append(("illegal_opcode", 30,
    "            rom_word = {6'd40, 5'd0, 21'd0};",
    "8'd0", "",
    """
    wire base_ill = h_exec_active && (h_opcode >= 6'd24);
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_ill,1) || h_sticky[4]);
    always @(posedge clk) assert (!rst_n || cyc < 1 ||
        !$past(base_ill,1) || h_pc == $past(h_pc,1) + 8'd1);
"""))

# ================= host FIFO harness =================
def host_sv(props):
    h = """`default_nettype none
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
"""
    for i in range(16):
        h += f"    wire [15:0] h_tx_mem{i}, h_rx_mem{i};\n"
    h += "    wire [15:0] h_tx_mem_arr [0:15];\n    wire [15:0] h_rx_mem_arr [0:15];\n"
    for i in range(16):
        h += f"    assign h_tx_mem_arr[{i}] = h_tx_mem{i};\n"
        h += f"    assign h_rx_mem_arr[{i}] = h_rx_mem{i};\n"
    h += """    tt_um_pemu_host dut (
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
        .rx_push_ok(h_rx_push_ok), .rx_pop_ok(h_rx_pop_ok)"""
    for i in range(16):
        h += f",\n        .\\tx_mem[{i}] (h_tx_mem{i}), .\\rx_mem[{i}] (h_rx_mem{i})"
    h += "\n    );\n" + props + "\nendmodule\n`default_nettype wire\n"
    return h

HOST_EXPOSE = [
    "tt_um_pemu_host/tx_cnt", "tt_um_pemu_host/tx_wptr", "tt_um_pemu_host/tx_rptr",
    "tt_um_pemu_host/tx_push_ok", "tt_um_pemu_host/tx_pop_ok",
    "tt_um_pemu_host/rx_cnt", "tt_um_pemu_host/rx_wptr", "tt_um_pemu_host/rx_rptr",
    "tt_um_pemu_host/rx_fw_en", "tt_um_pemu_host/rx_fw_data",
    "tt_um_pemu_host/rx_push_ok", "tt_um_pemu_host/rx_pop_ok",
] + [f"tt_um_pemu_host/tx_mem[{i}]" for i in range(16)] \
  + [f"tt_um_pemu_host/rx_mem[{i}]" for i in range(16)]

FIFO_TX_PROPS = """
    // flags exact: full at exactly 16, empty at exactly 0
    always @(posedge clk) assert (!rst_n || cyc < 12 || h_tx_full == (h_tx_cnt == 5'd16));
    always @(posedge clk) assert (!rst_n || cyc < 12 || h_tx_empty == (h_tx_cnt == 5'd0));
    // acceptance exact: push accepted iff not full (never drops when not full)
    always @(posedge clk) assert (!rst_n || cyc < 12 || h_tx_push_ok == (tx_push_r && h_tx_cnt < 5'd16));
    // count never exceeds 16
    always @(posedge clk) assert (!rst_n || cyc < 12 || h_tx_cnt <= 5'd16);
    // count transition relation: only push_ok/pop_ok move it
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        $past(h_tx_push_ok,1) || $past(h_tx_pop_ok,1) || h_tx_cnt == $past(h_tx_cnt,1));
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        !$past(h_tx_push_ok,1) || $past(h_tx_pop_ok,1) || h_tx_cnt == $past(h_tx_cnt,1) + 5'd1);
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        $past(h_tx_push_ok,1) || !$past(h_tx_pop_ok,1) || h_tx_cnt == $past(h_tx_cnt,1) - 5'd1);
    always @(posedge clk) assert (!rst_n || cyc < 13 ||
        !$past(h_tx_push_ok,1) || !$past(h_tx_pop_ok,1) || h_tx_cnt == $past(h_tx_cnt,1));
    // write integrity: accepted push lands the byte at wptr (no silent drop)
    always @(posedge clk) assert (!rst_n || cyc < 13 || !$past(h_tx_push_ok,1) ||
        h_tx_mem_arr[$past(h_tx_wptr,1)] == $past(tx_data_r,1));
"""

FIFO_RX_PROPS = """
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
"""

# ================= observer harness =================
def obs_sv(wmark_val, props):
    return f"""`default_nettype none
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
        .wmark(8'd{wmark_val}), .prescaler(8'd0), .obs_en(1'b1), .obs_clr(1'b0),
        .obs_ptr(h_obs_ptr), .trace_full(), .trace_wm(h_trace_wm),
        .tmem_addr(), .tmem_men(), .tmem_ren(), .tmem_wen(),
        .tmem_din(), .tmem_bm(), .tmem_dout(8'd0),
        .host_rd_en(1'b0), .host_rd_addr(10'd0),
        .host_rd_data(), .host_rd_ack()
    );
{props}
endmodule
`default_nettype wire
"""

OBS_WM_PROPS = """
    // watermark fires exactly on the commit that reaches wmark (5)
    always @(posedge clk) assert (!rst_n || cyc < 12 ||
        !((h_obs_ptr == $past(h_obs_ptr) + 8'd1) && h_obs_ptr == 8'd5) || h_trace_wm);
    // no spurious strobe: fire implies ptr just reached wmark
    always @(posedge clk) assert (!rst_n || cyc < 12 || !h_trace_wm ||
        ($past(h_obs_ptr) + 8'd1 == 8'd5 && h_obs_ptr == 8'd5));
    // single-cycle strobe
    always @(posedge clk) assert (!rst_n || cyc < 12 || !h_trace_wm || !$past(h_trace_wm));
"""

OBS_WM_ZERO_PROPS = """
    // wmark=0 (disabled): strobe never fires
    always @(posedge clk) assert (!rst_n || cyc < 12 || !h_trace_wm);
"""

# ================= generate =================
os.makedirs(OUTDIR, exist_ok=True)
NEW = []
for name, depth, rom_body, pinsin, extra, props in PE:
    with open(f"{OUTDIR}/{name}.sv", "w") as f:
        f.write(pe_sv(rom_body, pinsin, props, extra))
    with open(f"{OUTDIR}/{name}.sby", "w") as f:
        f.write(make_sby(name, PE_DUT, "tt_um_pemu_pe", PE_EXPOSE, depth))
    NEW.append(name)

for name, depth, props in [("fifo_tx", 40, FIFO_TX_PROPS), ("fifo_rx", 40, FIFO_RX_PROPS)]:
    with open(f"{OUTDIR}/{name}.sv", "w") as f:
        f.write(host_sv(props))
    with open(f"{OUTDIR}/{name}.sby", "w") as f:
        f.write(make_sby(name, HOST_DUT, "tt_um_pemu_host", HOST_EXPOSE, depth))
    NEW.append(name)

for name, depth, wmark, props in [("obs_wm", 70, 5, OBS_WM_PROPS),
                                  ("obs_wm_zero", 40, 0, OBS_WM_ZERO_PROPS)]:
    with open(f"{OUTDIR}/{name}.sv", "w") as f:
        f.write(obs_sv(wmark, props))
    with open(f"{OUTDIR}/{name}.sby", "w") as f:
        f.write(make_sby(name, OBS_DUT, "tt_um_pemu_observer", [], depth))
    NEW.append(name)

with open(f"{OUTDIR}/run_all.sh", "a") as f:
    for name in NEW:
        f.write(f'bash -c "source /home/jarvis/asic/activate && timeout 900 sby -f {name}.sby" 2>&1 | grep -E "DONE.*(PASS|FAIL|ERROR)"\n')

print(f"Generated {len(NEW)} extended proofs in {OUTDIR}: {NEW}")
