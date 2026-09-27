# TEMPO PE Formal Verification (ISA v0.2 Timing)

SymbiYosys proofs for ISA v0.2 timing properties. No RTL modifications.

## Method

Yosys does not support hierarchical references (`dut.sig`) or SystemVerilog
`bind` in the formal flow. Internal signals are observed via yosys `expose`,
which adds them as output ports to the DUT module:

```
read_verilog <dut>
hierarchy -top tt_um_pemu_pe
proc
memory_map          # convert regs/retstack memories to flops
expose <signals>    # add as output ports
read_verilog -formal -sv <harness>
prep -top formal_top
```

The harness instantiates the DUT with the exposed ports connected to `h_*`
wires, which are used in the properties.

## Binding Table

| Harness wire | DUT signal | Type | Description |
|--------------|------------|------|-------------|
| h_exec_active | exec_active | wire | Base cycle active |
| h_opcode | opcode | wire [5:0] | Instruction opcode |
| h_dly | dly | wire [4:0] | Instruction delay field |
| h_instr | instr | wire [31:0] | Current instruction word |
| h_state | state | reg [2:0] | FSM state (0=PRIME,1=BASE,2=DELAY,3=WAIT,4=SLEEP) |
| h_pc | pc | reg [7:0] | Program counter |
| h_tick_en | tick_en | wire | Timestamp tick enable |
| h_sync0, h_sync1 | sync0, sync1 | reg [7:0] | 2-FF input synchronizer |
| h_pin_drv | pin_drv | reg [7:0] | Pin drive register |
| h_pmask | pmask | reg [7:0] | Pin mask (reset 0xFF) |
| h_ts | ts | reg [31:0] | Timestamp counter |
| h_cts_hi | cts_hi | reg [15:0] | CAP timestamp high |
| h_cts_pins | cts_pins | reg [7:0] | CAP sampled pins |
| h_ecnt | ecnt | reg [12:0] | WAIT elapsed counter |
| h_wait_hit | wait_hit | wire | WAIT hit condition |
| h_w_entry_hit | w_entry_hit | wire | WAIT entry hit |
| h_sticky | sticky | reg [4:0] | Sticky flags (bit0=TIMEOUT) |
| h_regs3 | regs[3] | reg [15:0] | Register 3 (via memory_map) |
| h_regs6 | regs[6] | reg [15:0] | Register 6 (via memory_map) |
| h_regs7 | regs[7] | reg [15:0] | Register 7 (via memory_map) |
| h_pins_sync | pins_sync | port [7:0] | Synchronized pins output |

## SRAM Model

The formal ROM models a 1-cycle latency SRAM: `imem_dout = rom_word(addr_q)`
where `addr_q` is the previous cycle's `imem_addr`. This matches the DUT's
expected SRAM interface timing.

## Results (2026-09-27, re-run after PE datapath change + extended + induction)

PROVEN = full unbounded proof (sby prove mode: base case + induction step,
smtbmc/z3). BOUNDED(n) = BMC to depth n, no failure. Zero failures anywhere.

| Proof | Description | Depth | Status |
|-------|-------------|-------|--------|
| sync2 | 2-FF synchronizer correctness | 20 | PROVEN |
| lat_pset_d0 | PSET d=0 latency (1 cycle) | 20 | PROVEN |
| lat_pset_d3 | PSET d=3 latency (4 cycles) | 25 | PROVEN |
| lat_pset_d31 | PSET d=31 latency (32 cycles) | 60 | PROVEN |
| lat_pget_d3 | PGET d=3 latency | 25 | PROVEN |
| lat_ldi_d2 | LDI d=2 latency | 25 | PROVEN |
| lat_add_d1 | ADD d=1 latency | 20 | PROVEN |
| lat_sub_d1 | SUB d=1 latency | 20 | PROVEN |
| lat_jmp_taken_d0 | JMP taken d=0 latency | 20 | PROVEN |
| lat_jmp_ntaken_d0 | JMP not-taken d=0 latency | 20 | PROVEN |
| pin_effect_pset_d3 | PSET commits pin_drv=0xA5 | 30 | BOUNDED(30) * |
| sample_pget_d3 | PGET samples to regs[3] | 30 | PROVEN |
| wait_entry | WAIT entry hit/no-hit | 30 | PROVEN |
| wait_loop | WAIT 256-cycle timeout, sticky[0] | 275 | see note ** |
| nostall_seq | Sequential d=0 has no stall | 25 | PROVEN |
| nostall_jmp | JMP d=0 has no stall | 25 | PROVEN |
| cap_atomic | CAP atomic commit | 30 | PROVEN |
| sleep_imm0 | SLEEP imm=0 (1 cycle) | 30 | PROVEN |
| sleep_imm2 | SLEEP imm=2 (3 cycles) | 30 | PROVEN |
| sleep_imm7 | SLEEP imm=7 (8 cycles) | 30 | PROVEN |
| carry_sub | CMP: C=1 iff a>=b (regression: inverted-carry bug) | 30 | PROVEN |
| carry_sub2 | ADDSUB-sub via shared adder: C=1 iff a>=b | 30 | PROVEN |
| carry_add | ADD: C=1 iff a+b > 0xFFFF | 30 | PROVEN |
| hlt_hold_pc | HLT holds PC, halted asserts (regression) | 30 | PROVEN |
| prefetch_delay | ST_DELAY: imem_addr==pc (regression: 6352084) | 30 | PROVEN |
| prefetch_wait | ST_WAIT: imem_addr==pc+1 | 40 | PROVEN |
| prefetch_sleep | ST_SLEEP: imem_addr==pc | 30 | PROVEN |
| illegal_opcode | opcode>=24: NOP + CONFIG_ERR, pc advances | 30 | PROVEN |
| fifo_tx | TX FIFO: full at exactly 16, accept iff not full, count relation, write integrity | 40 | PROVEN |
| fifo_rx | RX FIFO: same + read-mux exact | 40 | PROVEN |
| obs_wm | Watermark fires exactly on commit reaching wmark; single-cycle strobe | 70 | PROVEN |
| obs_wm_zero | wmark=0 (disabled): strobe never fires | 40 | PROVEN |

* pin_effect_pset_d3 is a bounded-temporal property (commit exactly N cycles
  after issue) - not inductive from an arbitrary state, so induction correctly
  reports UNKNOWN; BMC to 30 covers the full PSET d=3 window (4 cycles).
** wait_loop induction was still running at last update; BMC BOUNDED(275)
  covers the full 256-cycle WAIT timeout window.

## Note on X-freedom (no_x)

A formal `$isunknown` proof was attempted but yosys smtbmc mis-evaluates
`$isunknown` on wires in this flow (verified with a minimal reproducer:
asserting no-X on a wire driven by a defined flop FAILS with an all-defined
VCD trace). X-freedom is instead checked by `test/xcheck_pe.v` - Icarus
4-state simulation, mixed-opcode program, random pins, 600 cycles: PASS,
no X on pc/state/imem_addr/instr/pin_drv/flag_c/ts after reset.

## SLEEP/T1 Specification Tension

ISA v0.1 §2.2.1 states "every insn = 1+d" (latency rule). SLEEP is specified
as "waits exactly 1+imm13" with the d-field reserved_zero (d=0). These conflict
formally: 1+d = 1 cycle, but 1+imm13 can exceed 1 cycle.

The proofs check SLEEP as specified (exactly 1+imm13), per the task requirement.
The RTL implements: imm=0 → 1 cycle (no SLEEP state); imm>0 → 1+imm cycles
(1 base + imm in ST_SLEEP). This matches the 1+imm13 specification.

The tension (documented, not resolved): the ISA should explicitly exempt SLEEP
from the 1+d rule, or reword §2.2.1 as "except WAIT and SLEEP".

## WAIT Semantics (verified)

- `tsel=0` (instr[13]=0) means 256 cycles; `tsel=1` means 4096 cycles.
- `instr[14]=1` sets CONFIG_ERR (unsupported tsel[1] handling).
- Entry hit (w_entry_hit=1): immediate success, stays in BASE, regs[rd]=0.
- No entry hit: enters ST_WAIT, waits for hit or timeout.
- Timeout: writes 256 to regs[rd], sets sticky[0]=TIMEOUT.
- WAIT pin in instr[20:18], polarity in instr[17], mode in instr[16:15],
  rd in instr[12:9].

## Opcode Map (from RTL)

PSET=0, PSETR=1, PGET=2, PMASK=3, PDIR=4, PMODE=5, SLEEP=6, WAIT=7, CAP=8,
MOV=9, LDI=10, PUSH=11, PULL=12, MRS=13, MSR=14, ADDSUB=15, ALU2=16,
SHIFT=17, CMP=18, JMP=19, DJNZ=20, CALLRET=21, HLT=22, EVT=23.

ADDSUB: instr[8]=0 → ADD, instr[8]=1 → SUB.
