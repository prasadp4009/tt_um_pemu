# JTAG (IEEE 1149.1 master) — stretch protocol result

**Verdict: PROVEN** — firmware + protocol-specific wire-decoding checker +
golden test PASS, and the RTL co-sim replay of the recorded golden trace
PASSes cycle-for-cycle.

## Deliverables (files only, no commits/pushes)

| Artifact | Path |
|---|---|
| Firmware | `firmware/jtag/jtag.asm` (assembled: `firmware/jtag/jtag.hex`, `.lst`) |
| Golden test + TAP target + checker | `firmware/tests/test_jtag.py` |
| COS1 recorder (peer-driven variant) | `firmware/tests/record_jtag.py` |
| Co-sim hex (starklabs repo, additive) | `test/cosim/hex/jtag.hex` (md5 `f10cec063437a48d4d9b40414f804d4d`) |
| Co-sim trace (starklabs repo, additive) | `test/cosim/traces/jtag_trace.bin` (md5 `046786fe58a138ab9cf47f4fbc686a92`) |

## Design

- **Pin map:** pin0 = TCK (out, idle low), pin1 = TMS (out), pin2 = TDI
  (out), pin3 = TDO (in — `pdir` bit3 is 0 for the entire image, so TDO
  contention is structurally impossible). Pins 4–7 unused/Hi-Z.
- **Sampling contract:** TMS/TDI driven while TCK low; target samples them
  on the TCK rising edge; target changes TDO on the falling edge; firmware
  samples TDO with `PGET` during the low phase, 12 cycles after the falling
  edge that produced that bit (≫ the 2-cycle synchronizer latency), i.e.
  before the rising edge that shifts it out. LSB-first throughout.
- **TCK rate:** ≤ 2 MHz bound respected. One `clock_bit` = 31 cycles +
  call. Measured rising→rising: 33 cycles in navigation/reset segments
  (1.52 MHz), 37 cycles in the IDCODE Shift-DR loop (1.35 MHz), 38 at the
  two setup boundaries; the overall measured max of 47 cycles is the
  inter-command host-loop turnaround, not a shift segment. TCK high =
  12 cycles. JTAG is static, so deterministic per-segment periods are
  spec-legal.
- **Host commands:** `0x0001` = IDCODE read: 5× TMS=1 → Test-Logic-Reset
  (works from any state), RTI → Select-DR → Select-IR → Capture-IR →
  Shift-IR with IDCODE opcode `0b0001` (4-bit IR), Update-IR → RTI →
  Select-DR → Capture-DR → Shift-DR 32 bits, Update-DR → RTI; PUSHes
  IDCODE low word then high word, `evt 0`. `0x0002` = BYPASS test: IR ←
  `0b1111`, Shift-DR 8 bits of TDI `0xA5`; the 1-bit bypass register
  captures 0, so the captured byte must be `0x4A` (pattern delayed by
  exactly one bit) — PUSHed as one word. `0x00FF` = HLT; unknown commands
  PUSH `0xFFFF`. One documented init deviation: R_ONE drives pin0 = TCK,
  emitting one spurious boot TCK edge (TLR → RTI); harmless because every
  command opens with the 5× TMS=1 reset.
- **Target model** (shared by test and recorder): faithful 16-state TAP,
  4-bit IR with capture pattern `0b1101`, opcode `0b0001` = IDCODE (also
  the TLR default), `0b1111` = BYPASS, all other opcodes act as BYPASS;
  IDCODE = `0x1BA00477`; DR = 32-bit IDCODE register or 1-bit bypass
  register (captures 0); TDO driven only in Shift states, Hi-Z otherwise.
- **Firmware size: 169 / 256 words. Golden run: 3013 cycles to HLT.**

## Evidence

Sanity first: tools selftest PASS. The SPI golden test's functional checks
all pass (MOSI/TX/CS/duty), but its byte-period assertions fail by exactly
1 cycle (measured 58 vs expected 57) on the *unmodified* SPI firmware —
a stale expectation from the earlier RXNE race fix; reported here, not
hidden, and unrelated to the JTAG work.

Golden test (`python3 tools/tb.py run tests/test_jtag.py`) — **PASS**.
Checker output, verbatim excerpts:

```
wire walk: 83 TCK rises, TAP transitions all legal per 1149.1 table, 2 reset landings in TLR, final wire state RTI
Shift-DR episodes: 32 clocks (IDCODE) + 8 clocks (BYPASS), no extra clocks
wire-decoded IDCODE = 0x1ba00477 == target IDCODE (LSB-first, sampled pre-rise in low phase)
BYPASS: TDI 0xA5 in, captured 0x4a out == [capture 0 | TDI delayed 1 bit] -- IR+DR paths both proven
Shift-IR: opcodes 0b0001 then 0b1111 shifted in, capture pattern 0b1101 shifted out both times
TX words OK: IDCODE low=0x0477 high=0x1BA0, BYPASS captured=0x004A
model bookkeeping agrees: IR latches [IDCODE, BYPASS], DR episodes [32, 8], final state RTI
TCK period: min=33 max=47 cycles overall; IDCODE Shift-DR 37c (1.35 MHz), 38c at the two setup boundaries; bound 25c (2 MHz) respected
TCK idle low at end
pdir bit3 == 0 on all 3013 cycles (TDO never driven by firmware, no contention)
PE halted after 3013 cycles
```

The checker is protocol-specific, not a smoke test: it re-walks the TAP
state machine **from the recorded pin history alone**, counts TCK clocks
inside each Shift-DR/Shift-IR episode, assembles the TDO/TDI bit streams
LSB-first from the wire, and only then compares them against the model
IDCODE, the IR capture pattern, and the 1-bit-delayed BYPASS expectation;
the firmware's PUSHed words must equal what the wire carried.

Co-sim: trace recorded with the TAP peer driving TDO during recording
(3013 ticks, COS1 format byte-identical to `tools/record_cosim.py`),
replayed in the local scratch tree `stretch_cosim/jtag/` (Icarus):

```
trace: N=3013 halted=1 final_pc=168 init_rx=3
COSIM PASS: 3013 cycles verified, halted=1
** test_cosim.test_replay   PASS **
** TESTS=1 PASS=1 FAIL=0 **
```

## What Zybo hardware testing would additionally need

- A real JTAG target on the bench (e.g. another FPGA/SoC board or an ARM
  MCU debug port) wired to the Tarang pins: TCK/TMS/TDI/TDO plus a common
  GND; the logical→physical pin (TT pinout / Zybo PMOD) mapping for the
  board build in use, and the host path to load this image and issue the
  RX-FIFO command words.
- Level check: Tarang I/O is 3.3 V logic. A 3.3 V target (most FPGA boards)
  connects directly; a 1.8 V target (many modern ARM SoCs) needs a level
  shifter on TCK/TMS/TDI and on TDO. Target VTREF is not sensed by this
  firmware (no spare pin assigned); nTRST/nSRST are not implemented —
  not required, since the 5× TMS=1 sequence performs the logic reset.
- The expected IDCODE in the checker is the test fixture's `0x1BA00477`;
  against a real target the checker's wire decode is unchanged, only the
  expected constant becomes that target's datasheet IDCODE. At ~1.5 MHz
  TCK, plain short jumper wires are electrically fine; keep TDO runs
  short to avoid ringing on the one input line.
