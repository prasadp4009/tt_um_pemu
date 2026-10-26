# TEMPO Firmware Phase — FIRMWARE.md

**Status: G3 GATE PASS** (2026-09-27). Four protocol firmware images,
assembled from YAML-derived encodings, verified bit-exact against the
cycle-exact ISA simulator golden model.

## Deliverables

| Protocol | Firmware | Test module | Words / 256 | Headroom | Sim cycles | Result |
|---|---|---|---|---|---|---|
| UART 115200 8N1 | `firmware/uart/uart.asm` | `firmware/tests/test_uart.py` | 119 | 137 | 46,225 | PASS |
| SPI master mode 0, 1 MHz | `firmware/spi/spi.asm` | `firmware/tests/test_spi.py` | 63 | 193 | 872 | PASS |
| I2C master 100 kHz | `firmware/i2c/i2c.asm` | `firmware/tests/test_i2c.py` | 199 | 57 | 52,796 | PASS |
| 1-Wire master (stretch) | `firmware/onewire/onewire.asm` | `firmware/tests/test_onewire.py` | 130 | 126 | 516,014 | PASS |

Artifacts per protocol: `.hex`, `.lst`, `.log`, `.vcd` in
`firmware/tests/out/`. VCDs are per-cycle (pins/pc/ts sampled every core
cycle) — the waves-first evidence for the RTL phase.

Tools (all in `firmware/tools/`, committed):
- `asm.py` — two-pass assembler derived from `isa_v0.2.yaml`. Enforces
  reserved_zero delays, LDI even-only (bit0 reserved), target9[8]=0,
  WAIT cfg8 composition. Rejects unknown mnemonics/operands.
- `sim.py` — cycle-exact PE golden model (T1–T17 adopted interpretations):
  2-FF input sync, open-drain resolution, 16×16 FIFOs, Observer, host-port
  model, per-cycle VCD. **Bug fixed this phase:** WAIT edge modes never
  fired (wait_prev latch order); now check-then-latch, T8-exact elapsed,
  pinned by a selftest regression (commit `86cbacb`).
- `tb.py` — tbengy-style test-module runner (`build/peer/check`), plus the
  tools self-test (pin round-trip, WAIT timeout/elapsed, edge-mode
  regression, FIFOs, CALL/RET, 5-word decode spot-check).
- `ISA_CHEATSHEET.md` — worker contract (pinout, R_ONE idiom, host
  commands, cycle math).

## Measured vs theory/spec

**UART** (434 cycles/bit): TX bit cell 434 exact; byte pitch 4349 ×3, zero
deviation; RX first-sample offset +1 from ideal mid-bit (CAP-calibrated);
sample spacing 434 exact; back-to-back margin ±216; break → EVT2+0xFFFE;
TX underrun → 0xFFFD, no hang. Zero warnings.

**SPI** (50 cycles/bit): SCLK period 50 ×14, zero deviation; duty 25/25;
cycles/byte 407 = 400+7 theory; MISO `~MOSI` loopback (`0xA5→0x5A`,
`0x3C→0xC3`); CS# brackets SCLK; N=0 → 3-cycle pulse, no SCLK. Zero warnings.

**I2C** (500 cycles/bit nominal): 73 data clocks at exactly 499c
(= 100.2 kHz); high 248 / low 251; stretch 2000c tolerated (master WAIT
2001c < 4096 timeout, no abort); NACK-on-address → 0xFFE0 + STOP + EVT1.
Spec gates over all 92 highs / 90 lows: t_HIGH ≥ 200c ✓ (min 247),
t_LOW ≥ 235c ✓ (min 242), t_BUF ≥ 235c ✓ (270, 261). Zero warnings.

**1-Wire**: reset 480.02 µs, presence 30/120 µs, write-1 6 µs, write-0
61 µs, read sample at 15.02 µs, slot 70 µs — all inside DS18B20 windows
to the cycle. Scratchpad demo reads 25.0625 °C. No-device → 0x0000 +
EVT1 + TIMEOUT sticky. Zero warnings.

## G3 gate checklist

- [x] All four images assemble from YAML-derived encodings (`asm.py` only).
- [x] Bit-exact simulator tests pass (deterministic; UART ran 3× identical).
- [x] Measured timing compared with theory/spec (tables above + per-image headers).
- [x] No dependence on unspecified ISA behavior: no tsel 2/3 anywhere
      (one tsel=0, rest tsel=1); T17 pressure points documented below.
- [x] Each image fits 256-word IMEM (headroom 57–193 words).
- [x] Five-instruction re-encoding spot-check passes per image
      (reserved bits zero).
- [x] Exact per-cycle waveforms available (`tests/out/*.vcd`).
- [x] Q4 enforced: no PE-side trace-SRAM access in any image
      (Observer recipes are host-side only, in headers).

## T17 pressure points (documented, none blocking)

- UART: longest single WAIT 4096 (tsel=1); ~2-frame break rule = two
  chained tsel=1 waits (8192 total), never one long wait.
- 1-Wire: presence-end wait (up to 12000c) = 4 chained tsel=1 WAITs with
  W1C TIMEOUT clears between windows.
- I2C: all SCL waits tsel=1 (≤4096); 2000c stretch fits with margin.
- SPI: no WAIT at all (SLEEP-only timing).
- No firmware consumes a WAIT elapsed value from a tsel>1 wait.

## Findings & coordinator decisions

1. **WAIT edge-mode sim bug** (found by 1-Wire, hit UART too): fixed in
   `sim.py`, T8-exact, regression-pinned. Both firmwares keep their
   level-mode workarounds (semantically identical); headers updated.
2. **UART break threshold = ≥ 8192 cycles** (two chained tsel=1 windows),
   superseding the brief's "6000": the brief's numbers were mutually
   inconsistent; longest legitimate low run is 3906c (9×434), so 8192
   discriminates cleanly with no T17 exposure.
3. **I2C: 3 data-integrity bugs** found by the test author (never-tested
   firmware): wr_byte sent bits[15:8] (missing shl-by-8 align); ackbit and
   mackbit clobbered Z between flag-set and flag-use. All fixed, verified.
4. **I2C: t_LOW/t_BUF violations on ACK-family clocks** (found during
   bring-up): 9th-clock lows were 149–206c (< 235c spec min); bus-free
   was 130c. Padded per subroutine (ackbit SL2, pulse250 tail, nack_abort
   entry, i2c_start first-clock low, i2c_stop bus-free). All phases now
   spec-compliant (min low 242c, t_BUF 261/270c).
5. **SPI: R_ONE idiom glitch** — stock `pdir 0xFF` drives CS# low ~6c at
   boot (phantom CS# pulse seen by peer). Fixed: commit idle levels
   before enabling drivers. Pattern documented for RTL bring-up.
6. **1-Wire: r1 clobber** — `ow_read_byte` clobbered the demo's loop
   counter (infinite loop, FIFO overrun). Counter moved to r6; register
   map added to header.
7. **I2C image is 199 words** (brief target was ≤150; hard limit 256 —
   fits with 57 headroom). Timing pads cost ~10 words.

## Open / deferred

- 1-Wire ROM search deferred (~40+ words, would break the 150 target);
  SKIP ROM covers the single-drop demo.
- SPI mode 3 omitted (~20 words over budget); `0x0003` returns 0xFFFF
  (unsupported), documented.
- UART break-length peer drives 14000c (≥ 8192 rule); a 6000c low is
  correctly treated as a garbled byte, not a break.

## Next phase (RTL) inputs

- `firmware/tools/sim.py` is the golden model — RTL waves diff against
  `tests/out/*.vcd`.
- `firmware/{uart,spi,i2c,onewire}/*.hex` are the first RTL test programs.
- `_phase5/tbengy_skeleton/` holds the tbengy-generated SV TB scaffold
  (TT port list to be adapted).
