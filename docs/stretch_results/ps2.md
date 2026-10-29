# PS/2 (host side) — TEMPO stretch-protocol result

**Verdict: PROVEN** — firmware + protocol-specific wire checker + golden
test + RTL co-sim all pass. Files only; no commits, no pushes.

## Deliverables

| File | What |
|---|---|
| `firmware/ps2/ps2.asm` (+ `ps2.hex`, `ps2.lst`) | PS/2 host firmware, **216 words / 256** |
| `firmware/tests/test_ps2.py` | Golden test: keyboard model + wire-level checker |
| `firmware/tests/record_ps2.py` | COS1 recorder with keyboard peer (mirrors `tools/record_cosim.py`, reuses `dump_record`) |
| local scratch `stretch_cosim/ps2/` (not committed) | Co-sim tree (copies of `src/`, `test/sram_sim.v`, `test/cosim/`) |
| starklabs repo (additive, untracked) | `test/cosim/hex/ps2.hex`, `test/cosim/traces/ps2_trace.bin` |

Sanity first: `test_i2c.py` PASS (52805 cycles, all checks). Note:
`test_spi.py` currently FAILs by a pre-existing 1-cycle drift (SCLK
period 58 vs 57 at the byte boundary, cycles/byte 408 vs 407) —
unrelated to PS/2, present before this work.

## Pin map & electrical discipline

- **pin0 = CLK, pin1 = DATA**, both **open-drain + pull-up** via PMODE
  (`{od=1, pu=1}` per pin, PMODE = 0x000F), PMASK=PDIR=0x03.
- PSET bit 0 = drive low, PSET bit 1 = release (Hi-Z); line highs come
  only from the pull-ups — same discipline as the I2C firmware.
- R_ONE deviation (deliberate): r15=1 is materialized with
  `ldi r15,2 / djnz` instead of the pin-based R_ONE idiom, because the
  pin idiom drives pin0 high push-pull at boot and would break the
  open-drain invariant on pins 0/1.

## Convention (stated once, firmware + model agree, matches PS/2 spec)

In **both** directions the transmitter changes DATA only while CLK is
high, and the receiver samples DATA on the **falling edge** of CLK.
Device generates the clock in both directions. Host->device frame ends
with stop bit, then the device drives DATA low for a 12th (ACK) clock.
Firmware sequences on CLK *levels* (WAIT level high → WAIT level low,
tsel=1 looped, TIMEOUT sticky cleared per iteration) so no falling
edge can be missed in WAIT turnaround; PGET samples right after the
low-level WAIT returns (2-cycle synchronizer delay is negligible vs
the 2083-cycle half cell).

## Host commands

- `0x0001` receive one frame → PUSH byte, PUSH status
  (0=ok, 1=parity error, 2=framing start/stop, 4=clock timeout).
- `0x0002` + arg byte → inhibit/RTS/device-clocked transmit →
  PUSH status (0=ACK seen, 1=no ACK, 4=timeout).
- `0x00FF` → HLT. Unknown commands ignored.

## Golden test (`tools/tb.py run tests/test_ps2.py`) — PASS

Device clock modeled at **12.00 kHz** (bit cell 4167 cycles @50 MHz,
CLK high 2084c / low 2083c). Host stream:
`[0x0001, 0x0001, 0x0002, 0xED, 0x00FF]`.
**149,336 cycles** total, zero sim warnings, no stickies, EVT0 raised.
TX words: `[0x001C, 0x0000, 0x001C, 0x0001, 0x0000]` — receive #1 OK,
receive #2 parity-flagged with byte kept, transmit ACK OK.

Checker excerpts (decoded from the per-cycle `pins_phys` wire history,
not from firmware outputs):

```
[PASS] CLK falling edges on wire = 35 (want 35 = 11 rx + 11 rx + 1 inhibit + 12 tx clocks)
[PASS] rx frame1 data == 0x1C (wire-decoded 0x1C)
[PASS] rx frame1 parity bit == 0 (odd parity correct)
[PASS] rx frame1 stop bit == 1
[PASS] rx frame2 parity bit == 1 is WRONG on the wire (even total) -- and firmware status was 0x0001
[PASS] tx frame data == 0xED (wire-decoded 0xED)
[PASS] tx parity bit == 1 (odd parity correct for 0xED)
[PASS] tx ACK bit == 0 on wire (device ACK, 12th clock)
[PASS] keyboard model falling-edge samples == wire decode [0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1]
[PASS] inhibit: CLK low for 6002 cycles before RTS (spec >= 5000c = 100 us)
[PASS] inhibit CLK-low run total = 6104 cycles
[PASS] open-drain invariant: PE never drove CLK/DATA high push-pull in 149336 logged cycles (violations: [])
[PASS] PMODE: pins 0/1 are {open_drain=1, pull_up=1} whenever driven
```

Two real bugs were caught and fixed during bring-up (both instructive):
1. Odd LDI immediates (`ldi ...,0x0001`) rejected by the assembler —
   replaced with the r15 idiom.
2. The transmit inhibit initially *merged into the previous frame's
   final clock low phase* on the wire (no distinct inhibit edge —
   checker counted 34 falls, not 35). Fix: firmware waits for bus
   idle-high (`wf_high`) before driving CLK low. Inhibit is now a
   clean, separately measurable 6002-cycle hold before RTS.

## RTL co-sim — PASS

Recorded scenario (compact): single receive `[0x0001, 0x00FF]`, keyboard
sends 0x1C with correct odd parity at the **fast end of the PS/2 spec,
16.67 kHz** (bit cell 3000 cycles), recorded with the keyboard peer
attached via `tests/record_ps2.py`.

```
ps2: 31831 ticks, 3851598 bytes -> ps2_trace.bin (md5 df219c0ac8be63087a0d61d9c56ebd2f)
COSIM PASS: 31831 cycles verified, halted=1   (test_cosim.test_replay PASS, 636761 ns)
```

31,831 ticks is in line with the existing 1-Wire trace (28,050 ticks).
Hex md5 `aac758755ab841755d2006d51121f9af`, identical in scratch and in
the repo copy. Repo status: only untracked additive files added
(`test/cosim/hex/ps2.hex`, `test/cosim/traces/ps2_trace.bin`); no
tracked edits, no commit, no push.

## Zybo HW needs (not attempted — what a real hookup requires)

- A real PS/2 keyboard (or a PS/2-speaking microcontroller as a device
  stand-in) wired to two FPGA GPIOs mapped to logical pins 0/1.
- **Voltage care — the important part:** PS/2 is a **5 V open-collector**
  bus; the TEMPO ASIC / Zybo fabric is **3.3 V and NOT 5 V-tolerant**.
  Because the bus is open-collector, the safe hookup is: pull-ups to
  **3.3 V** (not 5 V) on CLK and DATA at the host side — most PS/2
  keyboards tolerate 3.3 V pull-ups since they only ever pull down —
  plus the keyboard's own 5 V supply for power only. Where tolerance
  is uncertain, use a proper bidirectional level shifter (e.g.
  BSS138-based) or a 5 V-tolerant buffer. Never connect a bus pulled
  up to 5 V directly to the pins.
- External pull-up resistors (~2–10 kΩ to 3.3 V) — do not rely solely
  on the FPGA's internal pull-ups for a cable-length bus.
- Firmware assumes the device clock stays within ~10–16.7 kHz and the
  WAIT-loop budgets (8 × 4096 cycles per phase) cover the slowest
  spec half-cell by >7×; a real keyboard's idle gaps between frames
  are handled by the per-command (not per-frame) waits.

Verdict summary: **PROVEN** — golden test PASS (149,336 cycles, all
wire-checker assertions green, bad parity demonstrably flagged),
RTL co-sim PASS (31,831 cycles verified, halted=1), firmware 216/256 words.
