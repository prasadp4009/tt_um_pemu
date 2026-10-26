## What it does

TEMPO (Timing-Exact Multi-Protocol Observer) is a programmable serial-protocol
emulator. Instead of hard-wiring one protocol, the chip executes firmware
written in a 32-bit *timed* instruction set (TEMPO-32 ISA v0.2): every
instruction carries a 5-bit delay field, pin effects and pin sampling happen on
exact clock cycles, `WAIT` returns the number of cycles actually elapsed, and
`CAP` takes an atomic {timestamp, pins} snapshot. One engine therefore speaks
many protocols — the personality is the program, not the silicon.

Firmware images are included for **UART, SPI, I²C and 1-Wire**. Programs are
loaded at run time through a framed 2-wire host port (autobaud, ACK/NACK
framing; commands load and verify the program SRAM, move data through the
FIFOs, read the Observer trace, configure, GO/HALT, and report status), so
the chip can be re-purposed in-system without re-spinning anything.

Alongside the protocol engine sits an **independent Observer**: a separate
hardware block that watches the 8 protocol pins, timestamps every qualified
event with a 32-bit cycle counter, and records up to 204 timestamped entries
into its own trace SRAM — triggered by edge, pattern, pulse or watermark
conditions that firmware configures but cannot falsify. The protocol engine
has *no* data path to the trace SRAM (structurally checked), so the Observer
is a trustworthy on-chip logic analyser for the bus the engine is driving:
generate a protocol with the engine, characterise a peer with the Observer.

Target: 50 MHz clock (20 ns cycle = timestamp resolution). IHP 130 nm
SG13G2 (CMOS5L) via Tiny Tapeout, 6×4 tiles, 11,416 mapped cells including
the two foundry SRAM macros (256×32 program memory, 1024×8 trace memory).

## How it works

Three blocks, one contract: cycle-exact timing, no hidden stalls.

- **PE (protocol engine)** — single-cycle, non-pipelined core; 16 × 16-bit
  registers; 24 opcodes (pin ops, SLEEP/WAIT/CAP timing ops, ALU, branches,
  CALL/RET, host FIFO PUSH/PULL, observer config via MRS/MSR). Fetches from
  the 256×32 program SRAM. Per-instruction delay field (0–31 cycles) makes
  bit timing a compile-time property of the firmware.
- **Observer** — independent trigger + capture engine: 2-flop pin
  synchroniser, edge/pattern/pulse trigger qualifiers, prescaler, watermark
  event; writes 40-bit {timestamp[31:0], pins[7:0]} entries (5 bytes each)
  into the 1024×8 trace SRAM; host reads the trace back through the host port.
- **Host port** — 2-wire framed serial interface (RX in, TX out, autobaud
  from a sync byte) with ACK/NACK framing: LOAD_IMEM / VERIFY_IMEM (program
  load with read-back), RD/WR FIFO data, RD_TRACE, WR_CFG, GO, HALT,
  RD_STATUS.

Key ISA points (full spec: `docs/ISA_v0.2.md`, machine-readable:
`docs/isa_v0.2.yaml`):

| Field | Bits | Meaning |
|---|---|---|
| opcode | [31:26] | 24 opcodes, values 0–23 |
| delay | [25:21] | extra cycles (0–31) added to the instruction |
| operands | [20:0] | per-opcode fields |

`WAIT` waits for a configured pin condition with a programmable timeout and
writes the *elapsed cycles* to a register on exit (timeout sets a sticky
flag) — firmware can measure a peer, not just talk to it. `CAP` atomically
captures {cycle counter, synchronised pins} into a register pair.

## How to test

Simulation (no hardware needed):

- Tiny Tapeout cocotb test — loads the SPI firmware through the host port,
  verifies the read-back bit-exact, runs it, and checks the pins: one CS#
  pulse containing exactly 16 SCLK rising edges with MOSI = `0xA5, 0x3C`:
  `cd test && make -B`
- Full verification regression (independent of the TT test): 32 SymbiYosys
  formal proofs of the timing contract, an Icarus X-propagation check, four
  Verilator block benches (599 checks), and cycle-exact co-simulation of all
  four firmware images against the ISA golden model:
  `bash test/regress.sh`

Hardware validation was done on a Digilent Zybo (Zynq-7010) with the actual
`tt_um_pemu` top wrapped for FPGA (`fpga/`): SPI passed end-to-end at 50,
100 and 150 MHz; UART, I²C and 1-Wire passed load/verify/run/signature
checks at 50 and 100 MHz; fault injection on all four protocols produced a
fail, never a false pass. **Known anomaly:** SPI at exactly 125 MHz fails
deterministically (13/15 milestones, fail code 0x13) on the Zybo build —
reproduced on two builds, while 150 MHz passes, so it is not an fmax limit;
root cause is in the Zybo clocking/pin path, not the ASIC RTL (which is
specified and verified at 50 MHz).

## External hardware

- A host to drive the 2-wire port: any UART-capable controller (the port
  autobauds; a USB-UART bridge, a microcontroller, or the TT demo board's
  RP2040 all work) on `ui[0]` (RX) / `uo[0]` (TX).
- The device under test / peer bus on the 8 bidirectional protocol pins
  `uio[0..7]`, wired per the firmware's pin map (e.g. SPI image: SCLK=pin2,
  MOSI=pin3, CS#=pin5, MISO=pin0). Standard 3.3 V logic; open-drain buses
  (I²C, 1-Wire) need the usual external pull-ups.
- Validation only: Digilent Zybo Z7-10 for the FPGA build in `fpga/`.
