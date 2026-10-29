# SWD (ARM Serial Wire Debug, DP) — Tarang stretch campaign result

**Verdict: PROVEN** (golden + RTL co-sim, protocol-specific wire checker)

## Deliverables (files only — no commits, no pushes)

| File | What |
|---|---|
| `firmware/swd/swd.asm` (+ `swd.hex`, `swd.lst`) | SWD master firmware, **111 words / 256** |
| `firmware/tests/test_swd.py` | Golden test: SWD DP target model + protocol-specific checker |
| `firmware/tests/record_swd.py` | COS1 recorder with the target peer active during recording |
| local scratch `stretch_cosim/swd/` (not committed) | Co-sim tree (copies of `src/`, `test/sram_sim.v`, `test/cosim/`) |
| starklabs repo (additive, untracked only) | `test/cosim/hex/swd.hex`, `test/cosim/traces/swd_trace.bin` (md5 `44153f11c8284d73264557cc3fe0151e`, 404,187 B) |

## Protocol implementation

- Pin map: **pin0 = SWCLK** (PE out, idle low), **pin1 = SWDIO** (bidirectional, push-pull when driven). PMASK 0x03.
- **SWCLK = 32 cycles/bit = 1.5625 MHz** at the 50 MHz core (16c low + 16c high within every clocked phase).
- Host cmd `0x0001`: line reset → DP IDCODE read request → turnaround → ACK → 32-bit data → parity → turnaround back. PUSHes `{ACK, IDCODE_lo, IDCODE_hi, parity_ok}`, `evt 0`, loops. Cmd `0x00FF` = HLT; unknown → PUSH 0xFFFF.
- Request wire bits LSB-first: `1,0,1,0,0,1,0,1` = start=1, APnDP=0, RnW=1, A[2]=0, A[3]=0, parity=1 (XOR of APnDP/RnW/A2/A3), stop=0, park=1 (byte 0xA5 LSB-first).
- RX sampling: target presents each bit at the SWCLK falling commit; firmware PGET runs in the last low-phase cycles and, through the 2-FF synchronizer, samples the physical line ~2 cycles before the rising commit — late in the low phase, bit stable since the fall. Bit accounting runs in the high phase. This survived RTL co-sim, which models the synchronizer independently.
- Line-reset disambiguation (documented in the test): the request start bit is itself a 1, so the wire shows **57 consecutive ones** (56 reset + start) before the first 0 (APnDP). The target model syncs on that first 0 after a ≥50-one run; the checker verifies the exact 57-run.
- Phase boundaries stretch SWCLK high by a few setup cycles (38c rise-to-rise at the 3 `rx_bits` call boundaries: RET + result-store + count setup + CALL + init = +6). SWD is fully static, so this is protocol-legal; all intra-phase periods are exactly 32c.

## Golden test — PASS (checker output, quoted)

```
[PASS] swd cycles=3340 halted=True
boot R_ONE rise present (SWDIO=0), excluded from decode
SWCLK rising edges decoded: 102 (+1 boot)
line reset OK: 56 SWCLK with SWDIO=1 (57 ones incl. request start bit, >= 50 required)
request OK: wire bits [1, 0, 1, 0, 0, 1, 0, 1] = start1 APnDP0 RnW1 A2=0 A3=0 parity1 stop0 park1 (byte 0xA5 LSB-first)
ACK OK: wire bits [1, 0, 0] -> ACK value 1 (OK)
data OK: 32 wire bits LSB-first = 0x2ba01477
parity OK: wire bit 0 == even parity of 0x2BA01477 (popcount 14 even)
turnaround-1 OK: 1 SWCLK, SWDIO driven by neither side
turnaround-2 OK: 1 SWCLK, SWDIO driven by neither side
no SWDIO contention in 3340 ticks (PE and target never drive simultaneously)
reset phase: SWCLK period 32c x55 (32c = 1.5625 MHz at 50 MHz core)
request phase: SWCLK period 32c x7
RX stream (ACK+data+parity): period 32c, 38c at the 3 rx_bits call boundaries (+6 setup)
total SWCLK cycles (rises) == decoded bits == 102
PUSH words OK: ACK=0x0001 IDCODE_lo=0x1477 IDCODE_hi=0x2BA0 parity_ok=1
PE halted after 3340 cycles
```

The checker re-decodes the transaction **from the wire history alone** (physical pin snapshots + per-tick drive log): reset length, request bits, both turnarounds (exactly 1 SWCLK, SWDIO undriven by both sides), ACK value, data content, parity, PUSHed words, zero contention at any of 3340 ticks, and total SWCLK rising edges == decoded bit count (102). The target model independently parses the request and raises on any malformed bit/parity, so a firmware request bug fails the run itself, not only the checker.

- Firmware size: **111 / 256 words**
- Golden cycles: **3340** total for init + one IDCODE transaction + halt command

## RTL co-sim — PASS

Recorded with `record_swd.py` (peer target active; 3340 ticks, COS1 format byte-identical via `record_cosim.dump_record`). Run in the starklabs scratch tree:

```
trace: N=3340 halted=1 final_pc=23 init_rx=2
COSIM PASS: 3340 cycles verified, halted=1
** test_cosim.test_replay  PASS  66941.00 ns **
** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

Every RTL cycle matched the golden record (pins, regs, flags, FIFOs, observer state).

## Sanity baseline note

`tools/tb.py selftest` PASSes. `tests/test_spi.py` (pre-existing) currently FAILs only its strict timing assertions — SCLK byte-gap 58c vs the expected 57c, cycles/byte 408 vs 407 — while all its functional checks (MOSI/MISO bytes, TX words, CS# windows) pass. Cause: the committed `spi.log` predates the RXNE race-fix commit (`4c768a6`) that added one wait cycle to the SPI byte loop; the test's expected constants were not updated. This is a stale-expectation issue in the SPI test, unrelated to SWD; it was not modified (out of scope).

## Zybo / real-hardware needs (not run — HW is a separate gate)

- A real SWD target, e.g. any Cortex-M dev board (STM32 Nucleo/Blue Pill, nRF52, RP2040) with its SWD header exposed: wire Tarang pin0→SWCLK, pin1→SWDIO, plus common GND; target powered at 3.3 V logic (Tarang pin levels must match the target's VTref — do not drive a 1.8 V target at 3.3 V).
- Real-world SWDIO practice differs from this firmware: debuggers normally put a **~100 Ω series resistor** on SWDIO (and the line is shared through it) because real targets begin driving with less strict turnaround separation. This firmware is push-pull both ways and relies on the verified 1-clock released turnaround; on real hardware keep the resistor, keep leads short, and be prepared to lengthen the turnaround (the DP samples with its own timing margins at 1.56 MHz, which is slow by SWD standards and should be forgiving).
- The on-chip IDCODE of a real target will differ from the modeled 0x2BA01477 (that's a Cortex-M3 DP IDCODE); the checker/firmware are value-agnostic except for the modeled scenario — firmware computes parity from whatever it receives and reports ACK verbatim.
- Not covered, by design of the task: AP accesses, WAIT/FAULT ACK handling, overrun mode, SWD-to-JTAG switching sequence, multidrop — DP IDCODE read only.

## Verdict

**PROVEN** — SWD DP IDCODE read works cycle-exact in the golden model with a wire-level protocol checker (ACK=OK, data=0x2BA01477, parity verified, no contention) and replays cycle-exact against the RTL (co-sim 3340/3340 ticks PASS).
