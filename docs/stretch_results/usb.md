# USB 1.1 Low-Speed (device TX + RX experiment) — TEMPO stretch campaign

**Verdict: TX PROVEN (golden model + independent spec decoder + RTL co-sim).
RX: loop PROVEN cycle-feasible standalone in the golden model; GAP for integration — the combined image exceeds the 256-word IMEM limit (accounting below).**

## Deliverables (files only, no commits/pushes)

| File | What |
|---|---|
| `firmware/usb/usb.asm` (+ `usb.hex`, `usb.lst`) | Product TX firmware, **243 / 256 words** (13 headroom) |
| `firmware/usb/usb_rx_experiment.asm` | Standalone RX experiment image, **63 words** |
| `firmware/tests/test_usb.py` | Golden test with independent USB 1.1 decoder/checker |
| `firmware/tests/test_usb_rx.py` | RX experiment test (DATA0 + IN token) |
| `firmware/tests/record_usb.py` | COS1 trace recorder (mirrors `tools/record_cosim.py`) |
| starklabs repo (additive, untracked) | `test/cosim/hex/usb.hex`, `test/cosim/traces/usb_trace.bin` |
| local scratch (not committed) | `stretch_cosim/usb/` (co-sim run tree) |

## Pin map & protocol

- pin0 = D+, pin1 = D-, both push-pull outputs for TX. LS idle **J = pins 0x02**
  (D+ = 0, D- = 1 — the LS pull-up is on D-), **K = 0x01**, **SE0 = 0x00**.
- NRZI (data 0 = transition, 1 = no transition), bit-stuff a 0 after six
  consecutive 1s (stuffing continues through the CRC field), bytes LSB-first,
  CRCs transmitted MSB-first of the complemented remainder (spec §8.3.5).
- Host cmd `0x0001`, args: N (≤ 8), then N payload byte-words → SETUP token
  (SYNC 0x80, PID 0x2D, ADDR = 0x05, ENDP = 0, CRC5, EOP), ~10 bit-times of J,
  DATA0 (SYNC, PID 0xC3, payload, CRC16, EOP), then PUSH status 0, evt 0.
  Cmd `0x0002` in this image is a stub (PUSH 0xFFFF) — see RX accounting.
  Cmd `0x00FF` = HLT.

## The timing problem & the firmware architecture

LS bit = 666.67 ns = **33.333 cycles** at 50 MHz. The firmware emits every bit
cell from a single cycle-counted loop: cell = 33 cycles, +1 on every 3rd cell
(phase counter) → 33, 33, 34 repeating, average exactly 33.333. Between two
PSETRs there is a fixed 28-cycle budget (loop head 15c + tail 13c); every
field transition (SYNC→PID→field→CRC→EOP, byte→byte) is padded to the same
budget, so edges can only land on the dithered grid. All NRZI/stuff/CRC
computation for the next bit happens inside the current bit's window.

CRC: the spec's MSB-first LFSR is maintained in **reflected** form inside
the firmware (rc = bit-reverse of the spec state, poly 0xA001, `rc >>= 1`
with fb = rc-LSB XOR bit — proven equivalent in Python over 200 random
trials). The transmit value is then `~rc` emitted LSB-first, so one loop
serves bytes and CRC alike. The checker's decoder implements the spec form
independently (below), so the two genuinely cross-verify.

Bring-up bugs worth recording (all caught by the independent decoder):
1. EOP stage flag originally lived in the bytes-left register — the token
   EOP clobbered it and the data packet took the CRC path after byte 0.
2. The CRC-field transition was 2 cycles short after the reflected-CRC
   redesign shrank the loop head from 17c to 15c.
3. The 8th-byte (N=8) exit path was 1 cycle short — first visible as an
   edge 1 cycle early in the CRC region, only on the N=8 path.

## Golden test + independent decoder — TX evidence

`python3 tools/tb.py run tests/test_usb.py` → **PASS** (payload
[0xFF, 0x3C, 0xFF, 0xA5], N=4). The decoder works only from the raw per-tick
D+/D- history: segments packets on idle-J → SYNC, anchors a 33.333-cycle
grid at each packet's first SYNC edge, center-samples, NRZI-decodes,
de-stuffs (asserting stuff bits exist where required and no 7 consecutive
1s occur), reassembles bytes LSB-first, and verifies PID/fields/payload/
CRC5/CRC16 by the spec residue method, EOP widths, and return to J idle.

Transcript excerpts (verbatim):

```
firmware image = 243 words (limit 256)
decoder: 2 packets, max edge deviation from ideal 33.33c grid = 1 cycle(s) (20 ns)
token: 34 cells on wire, 32 bits after de-stuff, 1 stuff bit, EOP SE0 width = 66 cycles
token bytes (LSB-first reassembly): ['0x80', '0x2d', '0x5', '0xd0']
token: PID SETUP (0x2D) OK, ADDR=5, ENDP=0
token CRC5 residue = 01100 (spec: 01100)
data: 66 cells on wire, 64 bits after de-stuff, 2 stuff bits, EOP SE0 width = 66 cycles
data bytes: ['0x80', '0xc3', '0xff', '0x3c', '0xff', '0xa5', '0x8e', '0x48']
data payload OK: ['0xff', '0x3c', '0xff', '0xa5']
data CRC16 residue = 1000000000001101 (spec: 1000000000001101)
bus in J idle at end
TX status word OK: [0x0000]
PE halted after 3871 cycles
```

- **Max edge deviation from the ideal 33.333c grid: 1 cycle = 20 ns**
  (the dither bound; LS spec bit period tolerance is ±1.5% ≈ ±10 ns on an
  average basis — the dithered average is exact, edge jitter is the
  expected PSETR-grid quantization).
- Payload sweep (scratch validation, decoder PASS, deviation ≤ 1 cycle in
  every case): N=1 [00], [FF]; N=2 [A5 5A]; N=5 all-FF (8 stuff bits);
  N=8 all-FF (12 stuff bits), all-00, mixed [12 34 56 78 9A BC DE F0],
  ascending 1..8; 6 random payloads (seed 42, N=1..8); and a crafted case
  [3F FF 55] whose CRC ends on exactly six 1s — the mandatory stuff bit
  before EOP is emitted and verified.
- Cosmetic note: at boot there is a ~10-cycle transient on pin0 and a
  1-cycle SE0-looking state before the firmware drives J. The decoder
  ignores it (requires ≥ 5 J samples before accepting a packet); on real
  hardware the D- pull-up holds the bus at J regardless.

## RTL co-sim

Trace recorded with `tests/record_usb.py` (COS1, scenario
[0x0001, 4, FF 3C FF A5, 0x00FF]): **3871 ticks**, 468,438 bytes.
Run in local scratch tree `stretch_cosim/usb/test/cosim` (not committed):

```
trace: N=3871 halted=1 final_pc=27 init_rx=7
COSIM PASS: 3871 cycles verified, halted=1
** TESTS=1 PASS=1 FAIL=0 **
```

The RTL matches the golden model cycle-for-cycle for the whole
transaction. Hex + trace also copied (additive, untracked) into the real
repo at `test/cosim/hex/usb.hex` and `test/cosim/traces/usb_trace.bin`.

## RX — honest assessment

**The architecture doc (§5.5) predicted NRZI RX would likely not fit at
33 cycles/bit. The experiment refutes the cycle half of that prediction
and confirms a different blocker: words.**

### What was built

`usb_rx_experiment.asm` (63 words, standalone image): WAIT on the D+
rising edge (J→K = SYNC start), then a PGET sample-at-cell-center loop —
NRZI via XOR with the previous sample, ones-countdown de-stuffing, byte
assembly by shift + OR-0x80, PUSH each de-stuffed byte, on an SE0 sample
PUSH status 0, evt 0, HLT. Every loop path is padded to exactly
33 cycles (+1 on dither wrap): bit-0 store path, bit-1 store path,
stuff-drop path, and byte-complete path are all instruction-counted
equal (the two failures found en route were a bit-1 path 1 cycle long —
fall-through pads — and a stuff path 2 cycles short).

### RX evidence (golden model)

`tests/test_usb_rx.py` → **PASS**, and a 7-case scratch sweep, all exact:

```
DATA0 [FF FF]      -> [0x80, 0xC3, 0xFF, 0xFF, 0xFF, 0xFF] + status 0   PASS
DATA0 [A5 3C]      -> [0x80, 0xC3, 0xA5, 0x3C, 0x85, 0x0E] + status 0   PASS
DATA0 [00 00]      -> [0x80, 0xC3, 0x00, 0x00, 0xFE, 0x4F] + status 0   PASS
IN token ADDR=5    -> [0x80, 0x69, 0x05, 0xD0] + status 0               PASS
DATA0 4x[FF]       -> 8 stream bytes + status 0                         PASS
DATA1-ish 3-byte   -> 7 stream bytes + status 0                         PASS
DATA0 6x[FF]       -> 10 stream bytes + status 0 (~90 cells)            PASS
```

Calibration margin: shifting the first-sample alignment (prologue sleep)
over **CAL 0..26 all decode correctly** — a 27-cycle-wide window, i.e. the
loop tolerates nearly a full bit-cell of initial phase error (the WAIT
edge-sync plus the exactly-balanced loop preserves phase thereafter).

### RX accounting — why it is still a GAP

| Item | Words |
|---|---|
| Product TX firmware (`usb.asm`) | 243 |
| RX experiment image (standalone) | 63 |
| Shared init/cmd-dispatch if merged (est.) | −15 |
| **Combined estimate** | **≈ 291 > 256** |

RX does not fit in the product image: TX alone leaves 13 words, and the
receiver needs ~48 unique words beyond shared init. Closing the gap would
require shrinking TX (e.g., dropping the N≤8 unrolled payload path or the
SETUP token) — a product decision, not an experiment fix. Per-bit cycle
budget is **not** the blocker: the RX loop costs exactly 33/34 cycles per
bit on every path (measured deltas 31–35 before final balancing, 33/34
after), within the 33.333 average with the dither tail.

Caveat: RX is proven in the golden model against an ideal peer (clean
edges, exact dither, 2-FF synchronizer modeled). Real-bus jitter,
metastability, and a host's actual inter-packet timing are unvalidated —
that needs hardware (below).

## Zybo HW needs

- USB connector breakout on the Zybo PMOD/GPIO pins for D+/D-:
  **68 Ω series resistors** on both lines and a **1.5 kΩ pull-up on D-**
  (this is what identifies a low-speed device to the host), V-USB style.
- A **real USB host or a USB protocol analyzer** to validate against:
  enumeration-level signaling, host jitter, and real EOP/reset behavior
  cannot be proven against the golden peer.
- Signal-integrity caveat: GPIO-driven LS over PMOD wiring is marginal —
  LS's slow edge-rate spec helps, but series resistance, short stubs, and
  ground pairing matter; treat first HW bring-up as a signaling experiment,
  not a compliance test. The firmware drives LS levels (3.3 V CMOS) with
  no slew control.

## Sanity note

Pre-existing, unrelated: `test_spi.py` fails by 1 cycle in its SCLK
period check (58 vs 57 cycles at a byte boundary) on the untouched repo
HEAD — all SPI functional checks pass; not caused by and not affected by
this work. `test_i2c.py` passes; `test_uart.py` passes except one TX
underrun sub-check.
