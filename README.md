![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# TEMPO — Timing-Exact Multi-Protocol Observer

**A programmable protocol-emulator ASIC with an independent on-chip logic
analyser, for the Jane Street Protocol Emulator ASIC Competition**
(Tiny Tapeout, IHP 130 nm SG13G2 / CMOS5L, 6×4 tiles, submission deadline
18 January 2027).

TEMPO does not hard-wire a protocol. It executes firmware in a 32-bit
*timed* instruction set (TEMPO-32 ISA v0.2) in which timing is part of the
program: every instruction carries a delay field, pin effects and sampling
land on exact cycles, `WAIT` returns the cycles actually elapsed, and `CAP`
atomically snapshots {timestamp, pins}. Change the program, change the
protocol — no re-spin.

Next to the engine sits the **Observer**, an independent hardware trace
block. It watches the same 8 protocol pins, timestamps events with a 32-bit
cycle counter, and records them into its own trace SRAM under firmware-set
triggers. The engine has **no data path to the trace memory** (a structural
invariant, checked in the testbench), so the Observer can be trusted to
characterise the bus — including the engine's own output, and a peer's.

> One-line version: *the debugger's chip* — a protocol generator and a
> protocol characteriser on the same die, with a formally specified timing
> contract.

## Quick facts

| | |
|---|---|
| Clock | 50 MHz (20 ns cycle = timestamp resolution) |
| Area | 11,416 mapped cells total (Yosys/IHP SG13G2, incl. the 2 SRAM macro instances); 184,657 µm² in the TT flow report |
| Tiles | 6×4 (Tiny Tapeout, IHP CMOS5L) |
| Program memory | 256 × 32-bit SRAM macro (RM_IHPSG13_1P_256x32) |
| Trace memory | 1024 × 8 SRAM macro (RM_IHPSG13_1P_1024x8) = 204 entries × {timestamp[31:0], pins[7:0]} |
| Registers | 16 × 16-bit GPRs; 20 special registers (MRS/MSR) |
| FIFOs | TX and RX, 16 × 16-bit each, via PUSH/PULL |
| Host port | 2-wire framed serial (autobaud, ACK/NACK), 10 commands |
| Protocols (firmware) | UART, SPI, I²C, 1-Wire |
| License | Apache-2.0 |

## The ISA in 60 seconds

Word format: `[31:26] opcode · [25:21] delay (0–31 cycles) · [20:0] operands`.
24 opcodes: `PSET PSETR PGET PMASK PDIR PMODE` (pins), `SLEEP WAIT CAP`
(timing/measurement), `MOV LDI` (data), `PUSH PULL` (host FIFOs),
`MRS MSR` (special registers incl. Observer config), `ADD/SUB AND/OR/XOR
SHL/SHR CMP` (ALU + flags), `JMP DJNZ CALL/RET`, `HLT`, `EVT`.

The two instructions that make this a measurement instrument, not just a
bit-banger:

- **`WAIT cfg, rd`** — wait for a configured pin condition (edge/level with
  mask), with a programmable timeout; on exit `rd` holds the **elapsed
  cycles**. Autobaud, period and pulse-width measurement are firmware
  idioms, not features.
- **`CAP rd`** — atomically capture {32-bit cycle counter, synchronised
  pins} for timestamped sampling under program control.

Full specification: [docs/ISA_v0.2.md](docs/ISA_v0.2.md) ·
machine-readable encoding (single source of truth):
[docs/isa_v0.2.yaml](docs/isa_v0.2.yaml) ·
architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
firmware notes: [docs/FIRMWARE.md](docs/FIRMWARE.md).

## Pinout

| Pin | Name | Direction | Function |
|---|---|---|---|
| `ui[0]` | HP_RX | in | Host port receive (2-wire framed serial, autobaud) |
| `ui[1..7]` | — | in | Unused (tied off internally) |
| `uo[0]` | HP_TX | out | Host port transmit |
| `uo[1..7]` | — | out | Tied to 0 |
| `uio[0..7]` | PIN0–PIN7 | bidir | Protocol pins: driven/sampled by the PE under firmware control (direction per-pin via `PDIR`, open-drain modes via `PMODE`); also watched by the Observer |

Example firmware pin map (SPI image): SCLK = PIN2, MOSI = PIN3, CS# = PIN5,
MISO = PIN0.

## Host port

Frames are `[CMD][LEN][DATA…]` → `[ACK][DATA…]` over the 2-wire port
(ACK_OK = 0xA5, NACK_BUSY = 0x5A, NACK_ERR = 0x5B; send a 0x00 sync byte
first for autobaud). Commands: `LOAD_IMEM` (0x01), `VERIFY_IMEM` (0x02),
`WR_CFG` (0x03), `RD_CFG` (0x04), `WR_RXFIFO` (0x05), `RD_TXFIFO` (0x06),
`RD_TRACE` (0x07), `RD_STATUS` (0x08), `GO` (0x09), `HALT_REQ` (0x0A).
Program images up to 256 words are loaded in frames of at most 63 words
(the 8-bit LEN field counts bytes). While a program runs, the host can
stream data through the FIFOs and read back the Observer trace.

## Firmware

Four images, each verified cycle-exact against the ISA golden model
(co-simulation) and run on FPGA hardware:

| Image | Words (of 256) | Source/hex |
|---|---|---|
| SPI | 71 | `test/cosim/hex/spi.hex` |
| UART | 125 | `test/cosim/hex/uart.hex` |
| I²C | 209 | `test/cosim/hex/i2c.hex` |
| 1-Wire | 132 | `test/cosim/hex/onewire.hex` |

## Verification

The timing contract is the product, so it is verified like one. All of the
following are independent of the Tiny Tapeout template test:

- **Formal** — 32 SymbiYosys proofs (per-opcode latency/pin-effect,
  prefetch, FIFO, CAP atomicity, Observer watermark, no-X): all pass.
- **Block benches** — four Verilator benches (PE, host, Observer, top):
  599 checks, all pass. Lint clean under `-Wall` with two reviewed,
  instance-specific waivers (`test/lint_waivers.vlt`).
- **X-check** — Icarus 4-state run: no X propagation after reset.
- **Co-simulation** — all four firmware images executed cycle-exactly
  against the cycle-accurate ISA golden model.
- **FPGA** — the real `tt_um_pemu` top on a Digilent Zybo (Zynq-7010):
  SPI end-to-end PASS at 50/100/150 MHz; UART/I²C/1-Wire PASS
  (load/verify/run/signature) at 50/100 MHz; fault injection on all four
  protocols fails loudly, never a false pass.
  **Known anomaly (FPGA only):** SPI at exactly 125 MHz fails
  deterministically (13/15 milestones, fail code 0x13), reproduced across
  two builds; 150 MHz passes, so it is not an fmax limit — the failure is
  in the Zybo clocking/pin path. The ASIC target is 50 MHz, where
  everything passes.
- **Synthesis** — Yosys + IHP SG13G2: 11,416 cells, 0 unmapped, both SRAM
  macros as blackboxes (`test/synth/tempo_synth.ys`).

Run it yourself:

```sh
bash test/regress.sh          # formal + xcheck + benches + co-sim
cd test && make -B             # Tiny Tapeout cocotb test (loads SPI fw, checks pins)
```

Coverage detail: [test/COVERAGE.md](test/COVERAGE.md).

## Repository layout

- `src/` — RTL: `tt_um_pemu.v` (top), `tt_um_pemu_pe.v` (engine),
  `tt_um_pemu_observer.v` (Observer), `tt_um_pemu_host.v` (host port)
- `docs/` — datasheet source (`info.md`), architecture, ISA spec (md + yaml)
- `test/` — TT cocotb test, Verilator benches, formal proofs, co-sim,
  synthesis scripts, `regress.sh`
- `fpga/` — Zybo validation: TT-wrapper top, firmware loader (case-ROM
  generated by `gen_fw_rom.py <proto>` — run it before rebuilding for a
  different protocol), Vivado build/test TCL

## Status & known open items

- T17 (ISA lead decision): `WAIT` elapsed-count behaviour on very long
  timeouts (16-bit result, timeouts to 64K/1M cycles) — behaviour on
  overflow is the one encoding question still open in v0.2.
- TRACE_WM clear semantics: the ISA text labels STATUS[12] TRACE_WM
  "sticky/W1C"; the RTL clears it via the OBS_CLR strobe (MSR OBS_CTL)
  only — a STATUS W1C write does not clear bit 12. Docs and RTL to be
  unified before submission (either is implementable; the contract must
  say one thing).
- Observer `PIN_SEL` at the top level is tied to source 0 (the PE does not
  export its `pin_sel` register; see the header of `src/tt_um_pemu.v`).
  EDGE/PATTERN trigger modes are unaffected; PULSE triggering is limited
  to source 0.
- Hardening (LibreLane P&R, DRC/LVS, Tiny Tapeout precheck) runs in GitHub
  CI via the `gds` workflow on push.

## Authorship & AI disclosure

Designed by **Prasad Pandit** (solo entry), with **Jarvis, an AI agent,
as teammate**: architecture exploration, RTL/verification implementation
and test campaigns were executed agentically under the author's direction
and review, with every claim above backed by a runnable check in this
repository. AI tool use is disclosed here as the competition rules
provide for.

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that makes it easier and cheaper
to get designs manufactured on real silicon: https://tinytapeout.com
