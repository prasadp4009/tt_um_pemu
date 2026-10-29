# Tarang Stretch-Protocol Tests — USB LS, 10BASE-T, JTAG, SWD, PS/2, CAN

**Date:** 2026-10-27 (run overnight into 10-28 CDT) · **Chip:** tt_um_pemu (Tarang), repo HEAD `e99ff28` (full TT flow GREEN)
**Method:** the project's own pipeline for every protocol — firmware in Tarang assembly
(`firmware/tools/asm.py`) → golden-model test with a **protocol-specific checker/decoder**
(`firmware/tests/test_<proto>.py` via `tools/tb.py` against the cycle-exact golden model
`sim.py`) → COS1 golden trace (`record_<proto>.py`) → **cycle-exact RTL co-sim replay** on
starklabs (`test/cosim`, Icarus). A verdict of PROVEN requires the checker to decode the
actual wire protocol and verify content (bytes, CRCs, parity, state sequences) — a generic
harness pass does not count. Per-protocol evidence files: `stretch_results/<proto>.md`.
**No hardware (Zybo) tests were run in this pass; no commits, no pushes.**

## Verdict summary

| Protocol | Verdict | Firmware | Golden cycles | Co-sim (RTL replay) |
|---|---|---|---|---|
| JTAG | ✅ **PROVEN** | 169 / 256 words | 3,013 | ✅ PASS, 3,013 cycles |
| SWD | ✅ **PROVEN** | 111 / 256 words | 3,340 | ✅ PASS, 3,340 cycles |
| PS/2 | ✅ **PROVEN** | 216 / 256 words | 149,336 | ✅ PASS, 31,831 ticks (recorded scenario) |
| CAN 2.0A @ 1 Mb/s | ✅ **PROVEN** (TX + ACK + arbitration; DLC ≤ 2, see §5) | 255 / 256 words | 6,366 | ✅ PASS, 3,504 (TX) + 300 (arbitration) |
| USB low-speed TX | ✅ **PROVEN** | 243 / 256 words | 3,871 | ✅ PASS, 3,871 cycles |
| USB low-speed RX | ⚠️ **PARTIAL** — loop proven standalone, does not fit alongside TX (word budget, §6) | 63 words standalone; TX+RX ≈ 291 > 256 | 7/7 packet types decoded | golden-model only |
| 10BASE-T Ethernet | ❌ **NOT FEASIBLE** on the ASIC (analysis, §7) | — | — | — |
| 10BASE-T via external PHY | ✅ feasible as a *system* (PHY does the Ethernet, §7) | — | — | — |

## 1. Feasibility math at the nominal 50 MHz / 20 ns cycle (written before coding)

| Protocol | Rate | Bit period | Cycles/bit | Grid | Mechanism / notes |
|---|---|---|---|---|---|
| JTAG | host-clocked (ran ≤1.52 MHz) | — | 33–37 per TCK | exact | firmware generates TCK; target samples on edges |
| SWD | host-clocked (ran 1.5625 MHz) | 640 ns | 32 | exact | firmware generates SWCLK |
| PS/2 | 10–16.7 kHz, device-clocked | 60–100 µs | 3,000–5,000 | async | WAIT-edge/level sync; open-drain via PMODE |
| CAN | 1 Mb/s | 1 µs | **50** | exact integer | SLEEP-timed bits; sample point inside the bit cell |
| USB LS | 1.5 Mb/s | 666.67 ns | **33⅓** | **fractional** | 33/34-cycle dither (33,33,34 → avg exactly 33.333); edge placement error ≤ 1 cycle = 20 ns |
| 10BASE-T | 10 Mb/s Manchester | 100 ns bit / 50 ns half-bit | 5 / **2.5** | **fractional, unrepresentable** | exact Manchester needs a 100 MHz grid; ASIC slow-corner fmax = **43.61 MHz** (§7) |

All cycle math is at the nominal 50 MHz. The competition imposes no clock target; the green
run's STA slow-corner ceiling (43.61 MHz) is a separate, pre-existing caveat on the nominal
rate itself, not on any result below (all co-sims run the RTL at 50 MHz).

**ISA facts the tests relied on** (from ISA v0.2): `PGET` samples the synchronized pin
vector (2-FF synchronizer = 2-cycle architectural latency, T5); `PDIR`/`PMODE` give native
open-drain emulation ({open_drain, pull_up} per pin — the I2C mechanism); `WAIT` waits on a
pin level/edge and returns elapsed cycles; ALU + `CMP`/`JMP` cover in-firmware CRCs.
**There is no branch-on-pin instruction** — branch-on-sample is a composite
`PGET → AND → JMP` (~4 cycles). §5 measures what that costs in practice.

## 2. JTAG — ✅ PROVEN

Firmware `firmware/jtag/jtag.asm` (169 words); pins 0=TCK (idle low), 1=TMS, 2=TDI, 3=TDO
(never driven — checker asserts `pdir` bit3 == 0 on all 3,013 cycles). TB target: faithful
16-state TAP, 4-bit IR (0b0001=IDCODE, 0b1111=BYPASS), IDCODE `0x1BA00477`.

Checker (re-walks the TAP from the wire alone) excerpts:

```
wire walk: 83 TCK rises, TAP transitions all legal per 1149.1 table, 2 reset landings in TLR, final wire state RTI
Shift-DR episodes: 32 clocks (IDCODE) + 8 clocks (BYPASS), no extra clocks
wire-decoded IDCODE = 0x1ba00477 == target IDCODE (LSB-first, sampled pre-rise in low phase)
BYPASS: TDI 0xA5 in, captured 0x4a out == [capture 0 | TDI delayed 1 bit] -- IR+DR paths both proven
TX words OK: IDCODE low=0x0477 high=0x1BA0, BYPASS captured=0x004A
```

RTL co-sim: `COSIM PASS: 3013 cycles verified, halted=1`.

**Zybo HW would additionally need:** a real 3.3 V JTAG target (TCK/TMS/TDI/TDO + common
GND; 1.8 V targets need level shifting; VTREF sensing and nTRST/nSRST are not implemented
and not required), the logical→physical pin mapping for the board build, and the checker's
expected IDCODE set to the target's datasheet value.

## 3. SWD — ✅ PROVEN

Firmware `firmware/swd/swd.asm` (111 words); pin0=SWCLK (idle low), pin1=SWDIO
(bidirectional push-pull); SWCLK 32 cycles/bit = 1.5625 MHz. Sequence: 56-bit line reset →
IDCODE request → 1-clock turnaround → ACK → 32-bit data → parity → turnaround back.
RX sampling is PGET late in the low phase, calibrated against the 2-FF synchronizer.

Checker (decodes from wire history alone) excerpts:

```
line reset OK: 56 SWCLK with SWDIO=1 (57 ones incl. request start bit, >= 50 required)
request OK: wire bits [1, 0, 1, 0, 0, 1, 0, 1] (byte 0xA5 LSB-first)
ACK OK: wire bits [1, 0, 0] -> ACK value 1 (OK)
data OK: 32 wire bits LSB-first = 0x2ba01477
parity OK: wire bit 0 == even parity of 0x2BA01477 (popcount 14 even)
no SWDIO contention in 3340 ticks
PUSH words OK: ACK=0x0001 IDCODE_lo=0x1477 IDCODE_hi=0x2BA0 parity_ok=1
```

RTL co-sim: `COSIM PASS: 3340 cycles verified, halted=1`.

**Zybo HW would additionally need:** a real Cortex-M SWD target (SWCLK/SWDIO + common GND,
VTref 3.3 V match); real-world SWDIO practice adds a ~100 Ω series resistor — this firmware
is push-pull and relies on the verified released turnaround.

## 4. PS/2 — ✅ PROVEN (both directions)

Firmware `firmware/ps2/ps2.asm` (216 words); pin0=CLK, pin1=DATA, both open-drain +
pull-up (PMODE 0x000F). Firmware sequences on CLK *levels* (looped tsel=1 WAITs, per the
T17 rule) so no device edge can be missed. Convention, stated in the firmware header and
applied in both directions: transmitter changes DATA while CLK is high, receiver samples
on the falling edge; host→device frames end with the device-driven ACK bit (12th clock).

Checker (decodes all frames from per-cycle wire history) excerpts:

```
rx frame1 data == 0x1C (wire-decoded)
rx frame2 parity bit == 1 is WRONG on the wire (even total) — and firmware status was 0x0001   [deliberate bad-parity frame, correctly flagged]
tx frame data == 0xED (wire-decoded)
tx ACK bit == 0 on wire (12th clock)
inhibit: CLK low for 6002 cycles before RTS (spec >= 5000c)
open-drain invariant: PE never drove CLK/DATA high push-pull in 149336 logged cycles (violations: [])
35/35 expected CLK falling edges
```

Golden PASS: 149,336 cycles, TX words `[0x1C, 0x0000, 0x1C, 0x0001, 0x0000]`. RTL co-sim
(recorded scenario: one receive at the fast spec end, 16.67 kHz): `COSIM PASS: 31831 cycles
verified, halted=1`. The checker caught one real firmware bug during bring-up (inhibit
merging into the previous frame's final clock-low phase) — fixed before the pass.

**Zybo HW would additionally need:** a real PS/2 keyboard or GPIO peer; **5 V warning** —
PS/2 is 5 V open-collector and the ASIC is 3.3 V, not 5 V-tolerant: pull up to 3.3 V only
(or a BSS138 level shifter), external 2–10 kΩ pull-ups, keyboard powered at 5 V separately.

## 5. CAN 2.0A — ✅ PROVEN (TX + ACK + arbitration loss), with a stated DLC cap

Firmware `firmware/can/can.asm` (**255 / 256 words**); pin0=TXD (1=recessive, 0=dominant),
pin1=RXD (bus level). TB bus model: wired-AND — bus is dominant if the firmware *or* the
peer drives dominant. Bit rate **1 Mb/s = exactly 50 cycles/bit**; CRC-15 (poly 0x4599)
computed **in firmware** over the destuffed stream; bit stuffing implemented in the TX
path; ACK slot sampled at the in-cell sample point.

Independent CAN monitor (written from the spec, shares no code with the firmware) excerpts:

```
[PASS] can cycles=6366
frame0 ID=0x123 DLC=2 data FF00 CRC wire=0x33ea == recomputed
frame1 ID=0x7FF CRC 0x272f match
stuff rule verified (no 6-in-a-row, SOF..CRC)
all 45 bus-edge deltas exact multiples of 50 cycles
TX words [0, 0, 0xFFA0]     (ACK seen, ACK seen, ARB_LOST)
```

**Arbitration, measured:** the peer drove dominant during the first recessive ID bit of
0x155. The firmware detected the loss and had TXD recessive for every cycle from the next
bit cell on: sample at cell cycle 20/50, abort decision **11 cycles after the sample
point**, **19 cycles before the next bit cell**. So the composite branch-on-sample
(`PGET → AND → JMP`) is *not* the bottleneck at CAN rates — the sample point sits at cycle
20 rather than the textbook ~75% point because per-bit CRC + stuffing + arbitration
bookkeeping consumes the rest of the cell. That is the honest characterization: the ISA
supports CAN arbitration with margin, at a firmware-chosen sample point.

**DLC cap (stated limitation):** DLC ≤ 2. Reason: Tarang has no data RAM — the destuffed
bit stream must live in a GPR across SOF..DLC while the CRC accumulates, and a full
DLC 0..8 implementation did not fit the remaining words at 255/256. Longer frames are a
firmware-size problem, not a timing or ISA-semantics problem.

RTL co-sim: TX scenario `COSIM PASS: 3504 cycles verified`; arbitration scenario
`COSIM PASS: 300 cycles verified`.

**Zybo HW would additionally need:** a 3.3 V CAN transceiver board (e.g., SN65HVD230) —
Tarang's side is logic-level TXD/RXD only — plus a second CAN node or analyzer to ACK and
to arbitrate against.

## 6. USB low-speed — TX ✅ PROVEN; RX ⚠️ PARTIAL (integration gap: words, not cycles)

**TX.** Firmware `firmware/usb/usb.asm` (243 words): SETUP token (ADDR 5, ENDP 0) +
DATA0 (N ≤ 8 host-supplied payload bytes), ~10-bit idle-J gap. One cycle-counted bit loop
serves all fields on the 33/34 dither grid (average exactly 33.333 cycles/bit); CRC5 and
CRC16 are computed in firmware (CRC16 kept in reflected form, poly 0xA001, transmitted as
`~rc` LSB-first).

Independent USB LS decoder (works from raw D+/D− history only: SYNC detect, per-packet
grid anchor, NRZI decode, de-stuffing with assertions, spec LFSR residue checks — shares
nothing with the firmware's CRC implementation):

```
token CRC5 residue 01100 ✓
data CRC16 residue 1000000000001101 ✓
EOP SE0 = 66 cycles (both packets)
payload recovered exactly
max edge deviation from ideal grid = 1 cycle (20 ns)
```

Golden PASS 3,871 cycles; a 14-payload sweep (N=1..8, all-FF with 12 stuff bits, a crafted
EOP-stuff case, random payloads) also passes. RTL co-sim: `COSIM PASS: 3871 cycles
verified, halted=1`. Three bring-up bugs were each caught by the decoder (EOP clobbering
bytes-left, one CRC transition 2 cycles short, N=8 exit 1 cycle short) — the checker is
load-bearing, as intended.

**RX — the §5.5 prediction was half wrong.** ARCHITECTURE.md §5.5 predicted NRZI RX would
likely not fit the 33-cycle bit budget. A standalone experiment
(`firmware/usb/usb_rx_experiment.asm`, 63 words) with a fully path-balanced
PGET sample-at-center loop **does** hold the 33.333-cycle grid and decoded **7/7 packet
types exactly** (DATA0 with 2-byte and FF-heavy payloads, IN token, up to ~90 cells), with
a 27-cycle-wide first-sample calibration window. The blocker is not cycles — it is words:
TX (243) + RX (63) − ~15 shared ≈ **291 > 256**. RX therefore stays out of the product
image (cmd 0x0002 is a stub returning 0xFFFF) and is proven at golden-model level only.
Closing this gap needs either a smaller TX image or an IMEM extension — an ISA-revision
(v0.3) conversation, not a firmware trick.

**Zybo HW would additionally need:** a USB breakout with 68 Ω series resistors and the
1.5 kΩ pull-up on D− (V-USB style), a real USB host or protocol analyzer to enumerate
against, and tolerance for the signal-integrity caveat of GPIO-driven low-speed signaling.

## 7. 10BASE-T Ethernet — ❌ NOT FEASIBLE on the ASIC (analysis only)

Full analysis: `stretch_results/ethernet.md`. Three independent, individually sufficient
grounds:

1. **Representability.** Manchester needs edges on a 50 ns half-bit grid; the pin contract
   (ARCHITECTURE.md §2.2; ISA T1/T3/T11) places edges only on the 20 ns cycle grid, and
   50 ns is not on it (2.5 cycles). Dithering 2/3-cycle half-bits bounds edge displacement
   at ±10 ns = 20 ns peak-to-peak deterministic jitter, which alone exceeds the 802.3
   transmitter jitter limits (±5.5 ns with TPM, ±8.0 ns without — TI SNLA266B) by
   1.82× / 1.25× before any clock or pad jitter. Dither also leaves ≤ ~3 cycles/bit for
   *all* MAC work (CRC-32, CSMA/CD, preamble) against proven Tarang protocol mappings at
   50–500 cycles/bit.
2. **Clock ceiling.** Green-run STA (run 40575084383, FINAL_STATS.md §5): slow corner
   (1.08 V / 125 °C) WNS −2.933 ns on the 20 ns period → **fmax = 1 / 22.933 ns =
   43.61 MHz** (typ 68.21 MHz, fast 88.35 MHz; all 131 slow-corner violators from the
   single net `u_imem/A_DOUT[18]`). Even the nominal 50 MHz sits above the slow-corner
   ceiling; the 100 MHz grid exact Manchester requires is 2.29× out of reach.
3. **No analog PHY.** 10BASE-T transmit is a differential waveform template
   (2.2–2.8 V peak into 100 Ω, bounded common-mode) through 1:1 magnetics with a
   common-mode choke, plus 100 ns link-integrity pulses every 16 ms ± 8 ms; receive needs
   a slicer with squelch. Tarang's pins are single-ended digital GPIO with fixed
   thresholds — the analog side does not exist on-chip, for TX or RX.

Escape hatches, closed: faster ASIC clock (STA, above); FPGA at 100 MHz (exact 5-cycle
half-bits — demonstrates ISA timing scaling only, still fails the analog side:
**FPGA-only curiosity**); other 10M variants (10BASE-T1L PAM3 @ 7.5 MBd, T1S DME @
25 MBd — both worse). **External PHY is the one real route:** Tarang drives a PHY's digital
interface — MII at 10 Mb/s is a 2.5 MHz nibble clock = 400 ns = 20 cycles/nibble, and an
SPI MAC/PHY (ENC28J60 class) is easier still — so *Tarang + external PHY* is a legitimate
system-level capability, **provided the claim is stated honestly: the PHY chip performs
the Ethernet line coding; the ISA does not.**

## 8. What the ISA learned (campaign-level findings)

- **The binding constraint is instruction memory, not timing.** Three of six protocols
  landed within 45 words of the 256-word IMEM limit (CAN 255, USB TX 243, PS/2 216), and
  both scoped gaps trace to words: CAN's DLC ≤ 2 cap and USB RX's non-integration
  (≈291 words combined). No protocol failed on cycle budget.
- **Branch-on-sample exists and suffices — as a composite.** No dedicated instruction,
  but `PGET → AND → JMP` decided a CAN arbitration loss 11 cycles after the sample point
  with 19 cycles of margin inside a 50-cycle bit. At USB-LS rates the same composite is
  *not* what limits RX (a balanced sample loop holds the grid); words are.
- **§5.5 corrections for the architecture doc:** USB RX is cycle-feasible (contra the
  "likely not" prediction); CAN arbitration is practical with a firmware-early sample
  point (cycle 20/50); 10BASE-T "not feasible" is confirmed and strengthened
  (fmax computed exactly: 43.61 MHz; dither jitter quantified against the 802.3 limits).
- **Process note (pre-existing, not from this campaign):** `firmware/tests/test_spi.py`
  currently fails one stale timing assertion by exactly 1 cycle (SCLK period 58 vs 57,
  byte 408 vs 407) on unmodified files — a leftover expectation from the earlier RXNE
  race fix in spi.asm. All functional SPI checks pass. Flagged by four independent
  workers during sanity runs; left untouched here.

## 9. Files (all additive, uncommitted)

Local (masters): `firmware/{jtag,swd,ps2,can,usb}/` (`.asm` + `.hex` + `.lst`;
plus `usb/usb_rx_experiment.asm`), `firmware/tests/test_{jtag,swd,ps2,can,usb,usb_rx}.py`,
`firmware/tests/record_{jtag,swd,ps2,can,usb}.py`, `stretch_results/{jtag,swd,ps2,can,usb,ethernet}.md`.

Author's local working copy (untracked, additive only, not committed to this repo):
`test/cosim/hex/{jtag,swd,ps2,can,usb}.hex`,
`test/cosim/traces/{jtag,swd,ps2,can,usb}_trace.bin` (CAN adds a second arbitration
trace). Scratch build trees (local, not committed): `stretch_cosim/{jtag,swd,ps2,can,usb}/`.
