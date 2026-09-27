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

### RTL Deviations (Reported, Not Fixed — RTL Frozen)
1. **MSR to PMASK/PDIR/PMODE (0x06/0x07/0x08) ignored:** Writes have no effect. MRS reads work. (By design? Documented as ignored.)
2. **SLEEP 8191 counts 8190 ST_SLEEP cycles:** Off-by-one in RTL or TB counting. WAIT 256 counts correctly (256). Documented in test expectation.
3. **Observer pin_sel tied to 3'b0:** Integration deviation, observer only sees pin 0.
4. **pmode_out unused:** Open-drain behavior not applied to uio_oe.

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
