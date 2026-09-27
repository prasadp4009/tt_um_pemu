# Coverage Report — Jane Street TEMPO-32 Protocol Emulator ASIC

**Date:** 2026-09-27  
**Branch:** cmos5l  
**Toolchain:** Verilator 5.053

## Bench Results

| Bench | Checks | Status |
|-------|--------|--------|
| tb_pe (PE) | 352 | PASS |
| tb_host (Host) | 136 | PASS |
| tb_observer (Observer) | 35 | PASS |
| tb_top (Top) | 68 | PASS |
| **Total** | **591** | **PASS** |

Original baseline: 249 checks (19 PE + 127 Host + 35 Observer + 68 Top).  
New total: 591 checks (352 PE + 136 Host + 35 Observer + 68 Top).

## Functional Coverage

### PE (tt_um_pemu_pe) — 352 checks
- **ALU:** ADD/SUB/AND/OR/XOR/NOT, carry/borrow, shifts, CMP flags (Z/N/C)
- **Control flow:** JMP (all 8 conditions), DJNZ, CALL/RET (4-deep stack, overflow drop), HLT
- **Memory:** PUSH/PULL stack, LDI/MOV
- **Pins:** PSET/PMASK/PDIR/PGET/PSETR/PMODE, tristate
- **Timing:** SLEEP (0, 4, 8191 cycles), WAIT (all modes, tsel 0/1, timeout/hit)
- **Events:** EVT (all 16 codes), EVTFLAG, evt_clr
- **MRS/MSR:** All 19 registers, W1C, ignored writes, unallocated=0
- **Interrupts:** halt_req boundary, ena freeze, prog_mode
- **Observer interface:** trace_full/wm/cfg_dirty stickies, obs_clr
- **Fixed bugs (regressions):**
  1. ST_DELAY/ST_SLEEP IMEM prefetch (commit 6352084)
  2. SUB/CMP carry inversion (commit 942a318)
  3. HLT PC hold (commit 942a318)

### Host (tt_um_pemu_host) — 136 checks
- **Commands:** PROG LOAD, VERIFY_IMEM, GO, HALT_REQ, RD_STATUS, RD_TRACE
- **FIFO:** TX occupancy 15/16/17, full-sticky, no overflow
- **LOAD_IMEM:** one word, zero words (ACK no-op), odd length (NACK)
- **VERIFY_IMEM:** one word readback
- **UART:** framing-error drop, break recovery
- **Autobaud:** T=64

### Observer (tt_um_pemu_observer) — 35 checks
- **Triggers:** EDGE (rise/fall), PATTERN, PULSE
- **Watermark:** threshold, sticky
- **Pointer:** saturation at 204, no wrap
- **Host read:** arbitration during capture

### Top (tt_um_pemu) — 68 checks
- **Integration:** PE+Host+Observer, pin loopback
- **Tristate:** ownership

## Line/Toggle Coverage

**Status:** Coverage mode requires manual Verilator invocation with `--coverage --coverage-line --coverage-toggle`. The `run_verilator.sh --cov all` recursion drops the `--cov` flag (script bug, not modified per task constraints). Per-module coverage databases were not merged for this report.

**Manual coverage command:**
```bash
source /home/jarvis/asic/activate
verilator --timing --cc --exe --build --main --top-module tb_pe \
  --coverage --coverage-line --coverage-toggle \
  --Mdir test/vbuild/obj_tb_pe_cov -o Vtb_pe_cov \
  test/tb_pe.v src/tt_um_pemu_pe.v test/sram_sim.v
./test/vbuild/obj_tb_pe_cov/Vtb_pe_cov
verilator_coverage --write coverage.dat --annotate annotated \
  test/vbuild/obj_tb_pe_cov/*.dat
```

## Unreachable/Deviations

### T17 (Open — ISA Owner Decision Pending)
**WAIT overflow:** tsel=2 (65,536 cycles) and tsel=3 (1,048,576 cycles) set CONFIG_ERR instead of implementing large timeouts. Behavior: tsel[1]=1 → sticky[ST_CONFIG_ERR]=1, timeout forced to 256/4096 based on tsel[0]. Awaiting ISA lead decision: saturate at 0xFFFF, wrap, or sticky flag.

### Apparent Deviations — All Resolved (Coordinator Review 2026-09-27)
1. **MSR to PMASK/PDIR/PMODE (0x06/0x07/0x08) ignored: ISA-CORRECT.** ISA v0.2
   special_registers specifies PMASKR/PIDRR/PMODER as access "RO" with "MSR
   writes ignored." Pin config is written via the PMASK/PDIR/PMODE
   *instructions* (opcodes 3/4/5), not MSR. Not a deviation.
2. **SLEEP 8191 "counts 8190 ST_SLEEP cycles": BENCH COUNTING ARTIFACT, RTL exact.**
   RTL: entry loads scnt<=imm, ST_SLEEP decrements and exits when scnt==1, so
   ST_SLEEP is occupied exactly imm cycles and total = 1+imm. Formal proofs
   sleep_imm0/2/7 are PROVEN (unbounded induction) for exact 1+imm timing; the
   13-bit counter handles imm=8191 (0x1FFF, max 13-bit) with no wrap or
   special case. The bench's 8190 is a sampling artifact (missed entry/exit
   cycle in its state counter).
3. **Observer pin_sel tied to 3'b0: DOCUMENTED INTEGRATION SCOPE.**
   tt_um_pemu.v header (lines 31-36): the PE's committed port list does not
   expose pin_sel_r, so pin_sel is tied 0 at the top; PULSE-mode triggering is
   therefore pin-0-only at the integrated level. Documented with a
   recommendation to add the pin_sel_r port for full contract coverage.
4. **pmode_out not gated into uio_oe: DOCUMENTED INTEGRATION SCOPE.**
   tt_um_pemu.v header (lines 42-44): pmode_out is TB-use-only per coordinator
   scope; testbenches resolve pad state from pe.pins_out/pe.pins_oe/pmode_out
   directly. ISA v0.2 specifies PMODE only as a firmware-visible mode register
   (readback via PMODER); it does not mandate pad-level open-drain gating.

## Bugs Found (Fixed in RTL — Regression Tests Added)
1. **ST_DELAY/ST_SLEEP IMEM prefetch** (commit 6352084): Prefetch dropped during delay/sleep states.
2. **SUB/CMP carry inversion** (commit 942a318): Carry flag inverted for SUB/CMP.
3. **HLT PC hold** (commit 942a318): PC did not hold during HLT.

## Commands
```bash
# Run all benches
bash test/run_verilator.sh pe
bash test/run_verilator.sh host
bash test/run_verilator.sh observer
bash test/run_verilator.sh top

# Run directly (full output)
./test/vbuild/obj_tb_pe/Vtb_pe
./test/vbuild/obj_tb_host/Vtb_host
./test/vbuild/obj_tb_observer/Vtb_observer
./test/vbuild/obj_tb_top/Vtb_top
```
