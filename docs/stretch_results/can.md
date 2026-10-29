# CAN 2.0A stretch protocol — Tarang (tt_um_pemu)
Status: PROVEN — golden PASS + RTL co-sim PASS (both scenarios)
Plan:
- [x] can.asm (255/256 words, DLC cap 2 — see header for rationale)
- [x] test_can.py: independent CAN monitor + bus model (ACK + arbitration)
- [x] golden run via tb.py — PASS (below)
- [x] record_can.py + co-sim on starklabs scratch + copy hex/trace to repo test/cosim
- [x] HW needs (below)

## Golden results (tools/tb.py run tests/test_can.py)
```
[PASS] can cycles=6366 halted=True
bus edges: 45, all deltas exact multiples of 50 cycles
monitor frame0: ID=0x123 DLC=2 data=['0xff', '0x0'] CRC wire=0x33ea recomputed=0x33ea stuff_bits=4 ACK=dominant EOF/IFS=recessive
monitor frame1: ID=0x7ff DLC=0 data=[] CRC wire=0x272f recomputed=0x272f stuff_bits=3 ACK=dominant EOF/IFS=recessive
monitor arb: TXD recessive for all cycles from cell 4 on (no dominant drive after arbitration loss)
arb latency: sample@6339 abort-pc first seen @6350 -> decision 11 cycles after sample point, 19 cycles before next bit cell
TX words OK: [ack-status 0, ack-status 0, arb 0xFFA0]
firmware size: 255 words / 256
```
Scenario: cmd 0x0001 ID=0x123 DLC=2 data FF 00; cmd 0x0001 ID=0x7FF DLC=0
(all-ones ID exercises stuffing in the ID field); cmd 0x0002 ID=0x155 with
bus model driving dominant through the first recessive ID bit cell (cell 3).
Total golden cycles for all three commands + halt: 6366.

## Design facts
- Firmware: firmware/can/can.asm, 255/256 words. DLC CAP = 2 (no data RAM;
  the 16-bit data stream must live in a GPR across SOF..DLC while ID/DLC
  shifters + arb flag are live; 8-bit sreg homes can't reload a stream
  inside the 10-cycle inter-bit gap). All other fields are DLC-independent.
- Bit cell exactly 50 cycles (psetr-to-psetr) on every path: cell subroutine
  30c (run update 5c + CRC-15 update 12c branch-equalized + sample + arb
  combine), send_bit entry/ret, uniform I=10 inter-bit gap; stuff cells are
  full 50-cycle cells. Verified: all 45 bus-edge deltas are exact multiples
  of 50 cycles.
- CRC-15 (poly 0x4599, init 0) computed in firmware over destuffed SOF..data,
  kept left-aligned (poly constant 0x8B32). Monitor independently recomputed
  CRC matches on-wire CRC for both TX frames.
- Sample point: PGET at cell cycle 20 (sync-effective ~18). Placement is
  forced: per-bit run+CRC+stuff+arb bookkeeping is 27 fixed cycles of the
  30-cycle cell. Peer/monitor drives each cell for the full 50 cycles.
- Branch-on-sample characterization: Tarang has no branch-on-pin. Path is
  PGET -> in-cell AND-combine into r11 -> ID-loop CMP+JMP nz (~3-4 cycles,
  absorbed in gap padding). Measured arbitration sample->abort-decision
  latency: 11 cycles; decision lands 19 cycles before the next bit cell
  would start, and since the lost bit was sent recessive, TXD never drives
  dominant again (verified for every cycle from cell 4 on).
- R_ONE deviation: stock idiom fails on CAN because PGET returns the whole
  pin byte and RXD idles recessive (=1) -> byte is 0x03, not 0x01. Firmware
  corrects via sub 2 with a carry-based fixup for the bus-dominant case.
- Bug found during bring-up (fixed): revDLC loop tested the carry after a
  shift that clobbered it; DLC field went out as 0 until fixed.

## RTL co-sim — PASS (both scenarios)
Recorded with firmware/tests/record_can.py (bus peer active; COS1 format
byte-identical via record_cosim.dump_record). Run in the starklabs scratch
tree stretch_cosim/can/ (local scratch copy of repo src/, test/sram_sim.v,
test/cosim/; make SIM=icarus there). The co-sim TB replays the golden
pins_phys as RTL inputs each cycle, so the ACK drive is baked into the
trace and the RTL's ACK sample + status push are verified against golden.
```
trace: N=3504 halted=1 final_pc=28 init_rx=6
COSIM PASS: 3504 cycles verified, halted=1
** test_cosim.test_replay  PASS  70221.00 ns **
** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```
Arbitration scenario ([0x0002, 0x155, HLT], bus drives dominant in ID
cell 3, recorder arms the bus model on frame 0):
```
trace: N=300 halted=1 final_pc=28 init_rx=3
COSIM PASS: 300 cycles verified, halted=1
** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```
Every RTL cycle matched the golden record (pins, regs, flags, FIFOs,
observer state — including the WMARK/EDGE_CFG sregs used as byte/stream
storage). Copies placed in the real repo (additive, untracked, no commits):
test/cosim/hex/can.hex, test/cosim/traces/can_trace.bin,
test/cosim/traces/can_arb_trace.bin.

## Zybo HW needs
- Tarang side is logic-level only: pin0 TXD / pin1 RXD at 3.3 V.
- A 3.3 V CAN transceiver board, e.g. SN65HVD230 (VP230) breakout: TXD<-
  pin0, RXD->pin1, CANH/CANL to the bus, 120 ohm termination at each bus end.
- A second CAN node to ACK and to arbitrate against: a CAN analyzer
  (e.g. PCAN-USB / CANable) or an MCU board with CAN (e.g. STM32 + the
  same transceiver). The analyzer doubles as an independent on-wire
  monitor at 1 Mbit/s.
- Note: firmware DLC cap is 2 (see header); sample point is cell cycle 20
  of 50 (40%) — within CAN bit-timing tolerance for a 1 Mbit/s bus with
  short stubs, but not the customary 75-87.5% sample point; on real
  hardware with propagation delay, ACK/arbitration margins are thinner
  than a production CAN controller's. Fine for a bench loopback/demo.

## Verdict
PROVEN — CAN 2.0A TX with in-firmware CRC-15, bit stuffing, ACK handling
and ID-field arbitration loss all verified cycle-exact in the golden
model by an independent spec-written monitor (fields, CRC, stuff rule,
50-cycle cells), and replayed cycle-exact against the RTL in co-sim
(3504/3504 ticks TX scenario, 300/300 ticks arbitration scenario).
