# Tarang — Architecture Proposal (Phase 1)

**T**iming-**E**xact **M**ulti-**P**rotocol **O**bserver — an entry for the
Jane Street Protocol Emulator ASIC Competition.

| | |
|---|---|
| Status | Phase-1 exploration: architecture only, **no RTL**. Nothing here is a commitment. |
| Date | 2026-09-26 |
| Target | IHP 130 nm CMOS5L via Tiny Tapeout, `tiles: "6x4"`, deadline 2027-01-18 |
| Author | Prasad Pandit |

**Reading guide.** Every number in this document is labeled:
`[cited]` = taken from a named source, `[derived]` = arithmetic on cited
numbers, `[est]` = engineering estimate (methodology given, must be replaced
by synthesis measurement). The single most important habit for this project:
*replace every `[est]` with a measurement at the first synthesis run.*

## 0. Constraints (recap, from the official announcement)

- Open-source, general-purpose **protocol emulator ASIC**: a tiny CPU whose
  ISA is built for reading pins, writing pins, counting cycles and hitting
  timing precisely, so UART / SPI / I2C (minimum) are **firmware, not fixed
  logic**. Must remain **reprogrammable after fabrication**.
- Stretch: low-speed USB, 10 Mbit Ethernet; also interesting: JTAG, SWD,
  PS/2, CAN.
- 6×4 tiles, about 0.7 mm² nominal area, roughly ~1 K logic cells/tile → **~24 K
  cells** `[cited: JS announcement]`. (Third-party flow facts put usable
  silicon at ≈ 0.75 mm² — see §0.1; keep both figures.) 8×4 is aspirational only — **design
  strictly to 6×4** (the cmos5l flow has no 8×4 key/DEF today `[cited: Loom
  tt_cmos5l_facts.md]`).
- Tiny Tapeout harness: 8 dedicated inputs (`ui_in`), 8 dedicated outputs
  (`uo_out`), 8 bidirectional (`uio`), plus `clk`, `rst_n`, `ena`.
- Judged on **unique functionality** AND **novel design and verification
  methodology**. Jane Street explicitly welcomes formal methods,
  constrained-random, and **AI-assisted verification**.
- Prize: tapeout of the most novel designs on the March 2027 CMOS5L shuttle;
  winners get chips + dev boards back. Build in public encouraged.

### 0.1 Verified physical facts (CMOS5L via Tiny Tapeout)

Sourced from the community fact sheet `tt_cmos5l_facts.md`
(thomasgilbert481/tt_um_loom, researched 2026-09-15 — the best
third-party reference found; re-verify against the flow before tapeout):

- 1×1 tile = 202.08 µm × 154.98 µm = **31,318 µm²** `[cited]`.
- 6×4 die = 1289.28 × 710.64 µm = 916,214 µm² incl. inter-tile gaps;
  **usable ≈ 24 × 31,318 = 751,632 µm²** `[derived]`.
- DFF `dfrbp_1` = 13.92 × 3.78 µm = **52.62 µm²** `[cited]` → at ~70%
  utilization, **≈ 400 DFFs/tile** `[derived]` — the number that kills
  flop-based memories (see §4).
- Routing: 5-metal stack; user logic routes up to **Metal4**
  (TopMetal1 is the mux/PDN spine) `[cited]`.
- SRAM: CMOS5L re-exports the SG13G2 `RM_IHPSG13_*` macros by symlink;
  **no separately characterized CMOS5L SRAM exists, and no CMOS5L SRAM
  tapeout has been published** `[cited]`. The `1024x8` macro "has been
  successfully taped out and tested" per Tiny Tapeout (on SG13G2), and a
  reference integration (`tt_um_urish_sram_test`) exists — but TT's own
  docs warn: *"Integrating the IHP SRAM macro at this stage is not
  trivial."* **This is our #1 flow risk (R1, §9).**
- Macro sizes (LEF `SIZE`, `[cited]`):

  | Macro | Size (µm) | Area | In tiles |
  |---|---|---|---|
  | `RM_IHPSG13_1P_256x16_c2_bm_bist` | 236.80 × 118.78 | 28,127 µm² | ~0.9 |
  | `RM_IHPSG13_1P_256x32_c2_bm_bist` | 416.64 × 118.78 | 49,489 µm² | ~1.6 |
  | `RM_IHPSG13_1P_1024x8_c2_bm_bist` | 146.88 × 336.46 | 49,419 µm² | ~1.6 |
  | `RM_IHPSG13_1P_1024x16_c2_bm_bist` | 236.80 × 336.46 | 79,674 µm² | ~2.5 |

  Note the `_bm_bist` suffix: these macros ship with **built-in self-test**
  — free post-silicon bring-up leverage (§7.8).
- Clock: TT IHP projects conventionally run at **50 MHz** `[cited:
  multiple tt_um_* info.md]`; the harness clock comes from the demo
  board. **Assume 50 MHz (20 ns/cycle); verify against the demo-board
  docs (R2, §9).** All firmware cycle math in §5 uses 50 MHz.

## 1. Architecture overview

**One sentence:** Tarang is a single-cycle, non-pipelined 32-bit timed-ISA
protocol engine (PE) paired with an independent hardware **Observer** —
a programmable, cycle-timestamped event-capture unit with its own trace
memory — sharing one pin fabric, one host port, and one cycle-exact
timing contract.

The PE speaks protocols. The Observer *listens* — it is an on-chip logic
analyzer. Together they cover both halves of Jane Street's stated use
case: *"a useful tool for hardware debugging and reverse engineering,
which is a good part of what we do."* Every surveyed competitor builds
the speaker; nobody builds the listener (§8).

### 1.1 Block diagram

```
                        ┌─────────────────────────────────────────────────┐
                        │            Tarang (tt_um_tempo, 6x4)             │
                        │                                                 │
  TT harness            │   ┌──────────┐    ┌──────────┐                  │
  ─────────             │   │  Host    │    │ Instr.   │                  │
  ui_in[7:0] ──────────►│   │  port    │───►│ SRAM     │                  │
  uio[7:6]   ◄─────────►│   │  FSM     │    │ 256x32   │    ┌──────────┐   │
  (HCLK/HDAT)           │   │ (PROG +  │    │ (IMEM)   │    │ Protocol │   │
                        │   │  RUN)    │    └────┬─────┘    │ Engine   │   │
  ena ─────────────────►│   └────┬─────┘         │ fetch    │ (PE)     │   │
  (0=PROG,1=RUN)        │        │          ┌─────▼─────┐    │ timed    │   │
  rst_n ───────────────►│        │          │ Decode / │◄───┤ ISA core │   │
  clk (50MHz) ─────────►│        │          │ control  │    │ 16x16    │   │
                        │   ┌────▼─────┐    │ (no pipe)│    │ GPR      │   │
                        │   │ Config   │    └────┬─────┘    │ ALU      │   │
                        │   │ regs     │         │          └────┬─────┘   │
                        │   │ (pinmux, │    ┌────▼───────────────▼─────┐   │
                        │   │  obsv,   │    │      Pin fabric          │   │
                        │   │  modes)  │    │  pin mux (8 logical →    │   │
                        │   └──────────┘    │  24 physical) + 2-FF     │   │
                        │                   │  synchronizers + OE      │   │
                        │   ┌──────────┐    └────┬───────────────┬─────┘   │
                        │   │ Observer │◄────────┘               │         │
                        │   │ (event   │  synchronized pins      │ pins    │
                        │   │ capture, │  (8 logical)            │         │
                        │   │ 32b ts)  │                         │         │
                        │   └────┬─────┘                         │         │
                        │        │ trace writes                  │         │
                        │   ┌────▼─────┐                         │         │
                        │   │ Trace    │                    ┌────▼─────┐   │
                        │   │ SRAM     │                    │ 24 phys  │──►│ uo_out[7:0]
                        │   │ 1024x8   │                    │ pins:    │   │ uio[7:0]
                        │   │ (204 evt)│                    │ ui_in[7:0]──►│ (to harness)
                        │   └──────────┘                    │ uio[7:0] │◄──│
                        └─────────────────────────────────────────────────┘
```

Data paths:
- **Program path (PROG mode, `ena=0`):** host → 2-wire host port
  (`uio[7]`=HCLK in, `uio[6]`=HDAT bidir) → host-port FSM → instruction
  SRAM + config registers. PE held in reset.
- **Run path (RUN mode, `ena=1`):** PE fetches from instruction SRAM every
  cycle, drives the pin fabric through the pin mux; host exchanges bytes
  with the PE through RX/TX FIFOs over the *same* 2-wire host port
  (frame protocol, §3.6); host reads Observer trace/status the same way.
- **Observe path (always in RUN):** synchronized logical pins → Observer
  trigger logic → timestamped `{ts[31:0], pins[7:0]}` entries → trace SRAM.

### 1.2 Design philosophy (what we refuse to do)

1. **No pipeline, no caches, no interrupts into the PE.** Timing is a pure
   function of (program, pin inputs) — PRU-style determinism, not
   IPC-chasing. Anything data-dependent is either bounded (WAIT has a
   timeout) or explicitly flagged (FIFO over/underrun stickies).
2. **Every timing claim is a checkable contract**, generated from the same
   ISA source as the RTL (§7.1). If firmware says a UART bit is 434
   cycles, that is provable, not hopeful.
3. **Debug is a first-class citizen.** The Observer exists because the
   chip's job is debugging other hardware; a debugger that cannot observe
   itself is a contradiction. On-chip trace > printf.
4. **Area honesty.** §4 budgets in µm² from cited cell areas, and the
   first synthesis run replaces all estimates — no exceptions.

## 2. ISA design — Tarang-32 (proposal v0.1)

### 2.1 Shape

- **Fixed 32-bit instruction words.** `[31:26]` opcode (64 majors),
  `[25:21]` per-instruction delay (0–31), `[20:0]` operand (format per
  opcode). Chosen over 16-bit after the PIO study: 16-bit cannot hold an
  8-bit pin mask *and* a useful delay field *and* a register specifier
  without multi-word hacks; 32-bit gives 16-bit immediates in a single
  word (LDI) and keeps fetch/decode trivially verifiable. Cost: IMEM
  macro 256×32 instead of 256×16 (+~21K µm² ≈ 0.7 tiles `[derived]`) —
  accepted (D2, §9.3).
- **16 GPRs × 16 bits** (R0–R15; 256 DFFs `[derived]`). 16-bit datapath:
  pin vectors are 8-bit, timestamps 32-bit (accessed as halves), cycle
  counts fit 16 bits for every mandatory protocol (I2C 100 kHz half-bit
  = 500 cycles; UART 115200 bit = 434 cycles @50 MHz).
- **Flags:** Z, N, C (from ALU/CMP), plus sticky HOST-visible flags:
  `TIMEOUT`, `TX_OVERRUN`, `RX_UNDERRUN`, `TRACE_FULL`, `CONFIG_ERR`.
  Stickies are W1C (write-1-to-clear) via MSR.

### 2.2 The cycle-exact contract (normative)

This is the section the formal proofs (§7.4) check. Every claim below
must hold in RTL, gate sim, and FPGA — or the ISA version bumps.

1. **Latency rule.** Every instruction occupies exactly **(1 + delay)**
   core cycles, where `delay = instr[25:21]`, *except* WAIT (#7 in the
   instruction table),
   which is data-dependent but bounded: `1 ≤ cycles ≤ 1 + timeout`.
2. **Pin-effect point.** PSET / PSETR / PDIR / PMODE take effect at the
   **end of the base cycle** (cycle 0); the `delay` cycles that follow run
   with pins stable. Two consecutive 1-cycle pin instructions therefore
   produce edges exactly 20 ns apart @50 MHz.
3. **Sample point.** PGET returns the synchronized pin vector captured at
   the **end of the base cycle**; the `delay` cycles follow.
4. **Synchronizer latency is architectural.** All pin inputs pass through
   2-FF synchronizers: the value PGET/CAP/Observer sees reflects the
   physical pins **2 core cycles earlier**, always. Firmware compensates
   with a constant — never a guess.
5. **No hidden cycles.** Instruction fetch is single-cycle from IMEM
   (single-port SRAM, PE is the only fetch client; the loader only writes
   IMEM in PROG mode while the PE is held in reset — no arbitration, no
   stalls).
6. **WAIT is the only timing-data-dependent instruction**, and it reports
   itself: it always writes the elapsed cycle count to Rd and sets
   TIMEOUT iff the timeout expired. Firmware can therefore *prove* its
   timing response instead of assuming it.

### 2.3 Instruction table (v0.1 — 24 opcodes of 64)

Operand byte layouts are per-opcode; `d` = delay field (shared).

**Pin / timing (the reason the chip exists):**

| # | Mnemonic | Operands | Semantics (all: 1+d cycles) |
|---|---|---|---|
| 0 | `PSET` | imm8 | `pins ← (pins & ~PMASK) \| (imm8 & PMASK)`; effect at end of cycle 0 |
| 1 | `PSETR` | Rs | `pins ← (pins & ~PMASK) \| (Rs[7:0] & PMASK)` |
| 2 | `PGET` | Rd | `Rd ← {8'b0, sync_pins[7:0]}` sampled end of cycle 0 |
| 3 | `PMASK` | imm8 | `PMASK ← imm8` (which pins PSET/PSETR affect; reset = 0xFF) |
| 4 | `PDIR` | imm8 | per-pin direction: 1 = drive, 0 = Hi-Z |
| 5 | `PMODE` | Rs | Rs[15:0] = 8× 2-bit pin modes: `{open_drain, pull_up}` per pin — **required for I2C** |
| 6 | `SLEEP` | imm13 | wait exactly `1 + imm13` cycles (imm13 ≤ 8191) |
| 7 | `WAIT` | cfg8, Rd | wait for pin condition; `Rd ← elapsed cycles`; TIMEOUT sticky iff timeout. `cfg8 = {pin[2:0], pol, mode[1:0], tsel[1:0]}`; mode ∈ {level, rising, falling, either}; timeout presets {256, 4K, 64K, 1M} cycles |
| 8 | `CAP` | Rd | atomically latch `{timestamp[31:0], pins[7:0]}`; `Rd ← timestamp[15:0]`; full snapshot in special regs `CTS_HI`, `CTS_PINS` (read via MRS) |

**Data movement:**

| # | Mnemonic | Operands | Semantics |
|---|---|---|---|
| 9 | `MOV` | Rd, Rs | `Rd ← Rs` |
| 10 | `LDI` | Rd, imm16 | `Rd ← imm16` (single word — the payoff of 32-bit ISA) |
| 11 | `PUSH` | Rs | TX FIFO ← Rs (to host). **Non-blocking**: if full, drop + set `TX_OVERRUN` sticky |
| 12 | `PULL` | Rd | Rd ← RX FIFO (from host). If empty, Rd ← 0 + set `RX_UNDERRUN` sticky |
| 13 | `MRS` | Rd, sreg | read special reg: `STATUS, CYCLES_LO/HI, CTS_HI, CTS_PINS, OBS_PTR, PMASKR…` |
| 14 | `MSR` | sreg, Rs | write special reg (W1C for stickies; observer config; timestamp prescaler) |

**ALU (16-bit):**

| # | Mnemonic | Operands | Semantics |
|---|---|---|---|
| 15 | `ADD/SUB` | Rd, Rs1, Rs2 | `Rd ← Rs1 ± Rs2`; Z/N/C |
| 16 | `AND/OR/XOR` | Rd, Rs1, Rs2 | bitwise; Z/N |
| 17 | `SHL/SHR` | Rd, Rs1, Rs2 | shift by Rs2[3:0]; C ← last bit shifted out |
| 18 | `CMP` | Rs1, Rs2 | `Rs1 − Rs2`, set Z/N/C, discard result |

**Control flow:**

| # | Mnemonic | Operands | Semantics |
|---|---|---|---|
| 19 | `JMP` | target9, cond4 | cond ∈ {AL, Z, NZ, C, NC, TMO, RXNE, TXNF}; PC ← target iff cond |
| 20 | `DJNZ` | Rs, target9 | `Rs ← Rs−1`; if Rs ≠ 0, PC ← target — **the bit-bang workhorse** |
| 21 | `CALL/RET` | target9 / — | 4-deep hardware return stack (32 DFFs `[derived]`); overflow sets sticky |
| 22 | `HLT` | — | halt PE (clocks gated); wake on host GO or reset |
| 23 | `EVT` | imm4 | raise host event flag `EVT[imm4]` (sticky; host clears) — firmware→host signaling |

40 opcode slots remain for stretch needs (e.g., CRC-assist, pattern-match
accelerators — deliberately deferred, §9.2).

### 2.4 Why this ISA, vs. the references Jane Street named

| | RP2040 PIO | TI Sitara PRU | Tarang-32 (this proposal) |
|---|---|---|---|
| Word / regs | 16-bit, 2 scratch + ISR/OSR | 32-bit, 32 GPRs | 32-bit, 16 GPRs × 16-bit |
| Timing model | **1 cycle + 5-bit delay/sideset** per insn | single-cycle, non-pipelined; timing by cycle-counting NOPs in SW | **1 + 5-bit delay** per insn (PIO's idea), non-pipelined (PRU's determinism) |
| Pin simultaneity | sideset: pin action concurrent w/ insn | direct R30/R31 pin regs | pin-effect point architecturally fixed (end of cycle 0); masked multi-pin via PMASK |
| Pin sampling subtlety | **known ambiguity**: sideset-vs-OUT effect ordering debated by users `[cited: RPi forum]` | clean (register read) | sample/effect points are *normative contract items* with formal proofs (§7.4) |
| Time measurement | none (no cycle readback) | cycle counter readable | **WAIT returns elapsed cycles; CAP gives atomic {ts, pins}** — measurement is ISA semantics, not a SW idiom |
| Trace / observe | none | none | **dedicated Observer engine + trace SRAM** (§3.5) |
| Clocking | fractional 16.8 divider per SM | fixed 200 MHz | single 50 MHz domain; integer prescaler only on timestamp |
| Program memory | 32 words shared per 4-SM block | 8–16 KB | 256×32 SRAM (private) |
| Host link | FIFOs + DMA + IRQ | shared mem + INTC | RX/TX FIFOs + 2-wire framed host port (§3.6) |
| Suitability for comp. | great inspiration; 32-word limit + sampling ambiguity are real | too big for 24K cells as-is | sized for the budget (§4) |

**What we steal:** PIO's per-instruction delay (the single best idea in
this design space — timing becomes *data*, readable off the listing);
PRU's no-pipeline determinism and memory-mapped pin registers.
**What we refuse:** PIO's ambiguous effect ordering (we fix the effect
point by contract), PRU's area (we are ~⅓ the size), and everyone's
missing listener (the Observer).

## 3. Microarchitecture

### 3.1 PE core (single-cycle, non-pipelined)

```
                  ┌──────────────────────────────────────────────┐
                  │  IMEM (256x32 SRAM, single port)              │
                  └──────────────┬───────────────────────────────┘
                                 │ 32b insn / cycle
                  ┌──────────────▼───────────────────────────────┐
                  │ PC (8b) → decode (combinational)              │
                  │   opcode[31:26]  delay[25:21]  operand[20:0]  │
                  └──────┬───────────────┬───────────────┬───────┘
                         │               │               │
              ┌──────────▼───┐   ┌───────▼──────┐  ┌─────▼────────┐
              │ Regfile      │   │ ALU 16b      │  │ Pin unit     │
              │ 16x16        │   │ ADD/SUB/     │  │ PSET/PSETR/  │
              │ 2R1W         │   │ AND/OR/XOR/  │  │ PGET/PMASK/  │
              │              │   │ SHL/SHR/CMP  │  │ PDIR/PMODE/  │
              └──────────┬───┘   └───────┬──────┘  │ SLEEP/WAIT/  │
                         │               │         │ CAP          │
                         └───────┬───────┴─────────┴──────────────┘
                                 │ writeback (end of cycle 0)
                          flags Z/N/C + stickies
```

- **Fetch:** PC → IMEM, 1 cycle. No branch predictor, no prefetch: a
  taken JMP/DJNZ/CALL/RET costs exactly its (1+d) cycles — the target is
  fetched next cycle. (Slightly slower than a pipelined core; infinitely
  more predictable. This is the trade, made deliberately.)
- **Delay counter:** 5-bit down-counter; when non-zero, the core holds
  PC/decode stable and counts. All state updates happen in cycle 0.
- **WAIT implementation:** combinational condition on synchronized pins;
  each cycle: if condition met → write elapsed count to Rd, advance PC;
  else if elapsed == timeout → set TIMEOUT sticky, Rd ← timeout,
  advance PC; else elapsed++. The elapsed counter *is* the delay
  counter reused — no extra datapath `[est]`.
- **HLT:** clock-gates the PE (not the Observer/timestamp — the listener
  keeps listening).

### 3.2 Pin fabric

8 **logical pins** L[7:0] (what firmware sees) → 24 **physical pins**
(`ui_in[7:0]` in-only, `uo_out[7:0]` out-only, `uio[7:0]` bidir) via a
per-logical-pin 5-bit select (24 pins + `GND`/`VCC`/status-source
constants). Per-logical-pin: direction (PDIR), 2-bit mode (PMODE:
push-pull / open-drain / +pull-up), output value, OE.

```
  PE pin unit ──► L[7:0] value/dir/mode ──► ┌─────────────────┐
                                            │ Pin mux         │
  sync_pins ◄── 2-FF synchronizers ◄──────── │ 8× (5b select,  │
  (to PGET/WAIT/Observer)                   │    OE logic,    │
                                            │    OD emulation)│
                                            └────────┬────────┘
                                          ┌─────────┼──────────┐
                                     ui_in[7:0] uo_out[7:0] uio[7:0]
```

- **Open-drain emulation** (for I2C): mode bit per pin; when set,
  "drive 1" becomes Hi-Z and "drive 0" drives low. Pull-up is a weak
  internal pull (or rely on external — document; internal weak pull
  costs 8 pull-up cells, keep as option).
- **Status-as-pin-source:** physical pins can also be muxed to
  `{TX_EMPTY, RX_FULL, TRACE_WM, EVT_ANY}` so the host can watch FIFO/
  trace state on a scope without the serial port. Costs 4× 32:1 mux
  inputs `[est: ~200 cells]`.
- **Illegal mappings** (output → `ui_in` pin; two logical pins → one
  physical pin) resolve to GND and set `CONFIG_ERR` sticky — fail
  visible, never silent.

### 3.3 FIFOs (host ↔ PE)

- **RX FIFO** (host→PE): 16 deep × 16 bit = 256 DFFs `[derived]`.
- **TX FIFO** (PE→host): 16 deep × 16 bit = 256 DFFs `[derived]`.
- Non-blocking semantics (§2.3): full/empty never stalls the PE —
  determinism is preserved, overflow is *reported* via stickies. (A
  stalling FIFO would inject data-dependent timing into every PUSH —
  exactly what the contract forbids.)
- Depth 16 is a proposal: deep enough to absorb host-port frame latency
  (~10 cycles/byte, §3.6), shallow enough to be cheap. Revisit after
  firmware profiling (open question Q3, §9.2).

### 3.4 Timestamp

32-bit free-running counter @50 MHz (20 ns LSB), 16-bit prescaler
(÷1/÷16/÷256/÷4096 via MSR) for long captures. At ÷1 it wraps every
~86 s; at ÷4096 every ~4 days. Reset: global `rst_n` only (never by
firmware — timestamps must be comparable across runs). Readable via
MRS `CYCLES_LO/HI`; the Observer latches it on every trigger.

### 3.5 Observer (the differentiator)

Independent of the PE (runs during HLT; configured via MSR or host):

```
  sync_pins[7:0] ──► ┌──────────────┐    ┌───────────────┐
                     │ Trigger      │    │ Trace writer  │──► Trace SRAM
  timestamp[31:0] ──► │ EDGE/PATTERN │───►│ {ts[31:0],    │    1024x8
                     │ /PULSE       │ fire│  pins[7:0]}   │    (204 entries)
                     └──────────────┘    └───────────────┘
  config: TRIG_MODE[1:0], PIN_SEL[2:0], MASK[7:0], VALUE[7:0], EDGE_MASK[7:0],
          WMARK[7:0], PRESCALER[1:0]   (all MSR-writable / host-writable)
```

- **EDGE:** fire when any pin in EDGE_MASK transitions (per-pin
  rising/falling/either via 2-bit sub-field — pack into two config
  writes; exact packing TBD in ISA v0.2).
- **PATTERN:** fire when `(pins & MASK) == VALUE` (protocol state
  detection, e.g. I2C START = SDA falling while SCL high).
- **PULSE:** arm on rising edge of PIN_SEL, fire on falling edge —
  firmware subtracts the two timestamps for pulse width in cycles.
  (Two entries per measurement; the alternative — hardware subtraction —
  saves firmware nothing and costs a subtractor. Deferred.)
- **Trace entry:** 40 bits = 5 SRAM bytes `{ts[31:0], pins[7:0]}`.
  1024×8 macro → **204 entries** `[derived]`. Write pointer readable
  (`OBS_PTR`); on full: stop + `TRACE_FULL` sticky (no silent overwrite —
  determinism again). Watermark → host event + optional status pin.
- **Reader:** host only (via host port `READ_TRACE`). PE cannot read
  trace (keeps the writer/reader pair trivially arbitratable; PE-side
  measurement uses WAIT/CAP instead). *Open question Q4: is PE-side
  trace read worth the arbitration?*

### 3.6 Host port (one FSM, two modes)

2-wire framed serial slave on `uio[7]`=HCLK (host-driven),
`uio[6]`=HDAT (bidir). Frame: `[CMD(8b)] [LEN(8b)] [DATA…] →
[ACK(8b)] [DATA…]`. Byte = 8 HCLK + 1 ACK slot ≈ 10 host clocks `[est]`.

| CMD | PROG (`ena=0`) | RUN (`ena=1`) |
|---|---|---|
| `LOAD_IMEM` | write {addr16, data…} to IMEM | *rejected* (PE running) |
| `VERIFY_IMEM` | read back IMEM | rejected |
| `WR_CFG` / `RD_CFG` | pin-mux, observer, prescaler | allowed (careful: live reconfig is firmware's business; host writes set a `CFG_DIRTY` note, not a fault) |
| `WR_RXFIFO` | — | push bytes to RX FIFO |
| `RD_TXFIFO` | — | pop bytes from TX FIFO |
| `RD_TRACE` | — | read trace entries + `OBS_PTR` |
| `RD_STATUS` | status byte | status byte |
| `GO` | release PE reset, PC←0 | — (already running) |
| `HALT_REQ` | — | request PE halt (clean stop) |

Status byte: `{PE_RUNNING, PE_HALTED, TIMEOUT, TX_EMPTY, RX_FULL,
TRACE_WM, TRACE_FULL, CONFIG_ERR}`.

**Why 2-wire serial, not parallel:** the TT pin budget (§3.7) cannot
spare 8+2 pins for a parallel load bus in PROG mode *and* keep them
useful in RUN mode. Serial costs ~400 cells `[est]` and 2 pins, at
~10 host-clocks/byte → loading 256×32b = 1 KB takes ~10K host clocks —
at a 1 MHz host bit-bang, ~80 ms. Irrelevant next to tapeout.

### 3.7 Pin budget (the hard truth of 8/8/8)

PROG mode (`ena=0`): `uio[7:6]` = host port; all other pins Hi-Z/ignored.
RUN mode (`ena=1`): `uio[7:6]` remain the host port (2 pins); the other
22 pins are protocol-mappable.

| Protocol | Pins needed | Fits? |
|---|---|---|
| UART (TX+RX) | 2 | ✅ (+ host port) |
| SPI master (SCLK/MOSI/MISO/CS) | 4 | ✅ |
| I2C (SDA/SCL, open-drain) | 2 | ✅ |
| SPI + UART concurrently | 6 | ✅ |
| JTAG (TCK/TMS/TDI/TDO) | 4 | ✅ |
| JTAG + UART console concurrently | 6 | ✅ |
| USB LS (D+/D−) | 2 | ✅ electrically (see §5.5 feasibility) |
| SWD (SWDIO/SWCLK) | 2 | ✅ |
| PS/2 (CLK/DATA) | 2 | ✅ |
| CAN (TX/RX to external transceiver) | 2 | ✅ (transceiver off-chip) |

No mandatory or stretch protocol exceeds the budget. The binding
constraint is *concurrent* protocols, not any single one.

### 3.8 Clocking / reset

- Single clock domain: TT `clk` (assume 50 MHz, R2). No internal
  dividers on the PE datapath — cycle-exactness must survive the flow
  untouched.
- Timestamp prescaler is a *counter enable*, not a derived clock
  (no generated-clock STA headaches).
- Reset: `rst_n` async-assert, sync-deassert (2-FF). PE reset is
  additionally gated by the host-port FSM in PROG mode.
- Input synchronizers: 2-FF on all 24 physical inputs (48 DFFs
  `[derived]`); the 2-cycle latency is architectural (§2.2.4).

## 4. Area budget (all `[est]` except where cited)

Method: state flops counted from the spec × 52.62 µm²/DFF `[cited]`;
combinational estimated by block with reference anchors (SERV bit-serial
RV32 ≈ 2 K cells; a 16-bit non-pipelined core + pin engine lands at
3–5 K instances). **First synthesis replaces everything below.**

### 4.1 Flop inventory

| Block | Bits | µm² `[derived]` |
|---|---|---|
| GPRs 16×16 | 256 | 13,471 |
| PC (8b) + delay ctr (5b) + WAIT ctr (20b) | 33 | 1,736 |
| PMASK/PDIR (8+8), PMODE (16), pin out reg (8) | 40 | 2,105 |
| TX/RX FIFOs 2×16×16 + ptrs (16) | 528 | 27,783 |
| Timestamp 32 + prescaler 16 | 48 | 2,526 |
| Observer cfg (~53) + state (~16) | 69 | 3,631 |
| Call stack 4×8 | 32 | 1,684 |
| Input synchronizers 24×2 | 48 | 2,526 |
| Flags / misc control | ~96 | 5,052 |
| **Total flops** | **~1,150** | **~60,500 (~1.9 tiles)** |

### 4.2 Combinational (est)

| Block | Cells `[est]` |
|---|---|
| 16-bit ALU + shifter + flag logic | ~600 |
| Decode + control FSM | ~400 |
| Pin mux (8 logical × 24 physical + OE/OD) | ~800 |
| Comparators (timeout, watermark, ptr) | ~300 |
| FIFO control | ~200 |
| Observer trigger logic | ~400 |
| Host-port FSM + serial engine | ~400 |
| Status-mux, reset, glue | ~500 |
| **Total** | **~3,600 cells ≈ 72,000 µm² (~2.3 tiles)** |

### 4.3 SRAM (cited macro sizes)

| Macro | Bits | Area `[cited]` | Tiles |
|---|---|---|---|
| IMEM `256x32` | 8,192 | 49,489 µm² | ~1.6 |
| Trace `1024x8` (204 entries × 40b) | 8,192 | 49,419 µm² | ~1.6 |

### 4.4 Totals and the SRAM-vs-flops proof

| | µm² | Tiles / 24 | Cells / ~24 K |
|---|---|---|---|
| Flops | ~60,500 | ~1.9 | ~1,150 |
| Combinational `[est]` | ~72,000 | ~2.3 | ~3,600 |
| IMEM SRAM | 49,489 | 1.6 | (macro) |
| Trace SRAM | 49,419 | 1.6 | (macro) |
| **Total** | **~231,000** | **~7.4 (~31%)** | **~4,750 (~20%)** |

> **Measured update (2026-09-26, R1 trial):** `SRAM_TRIAL.md` replaced the
> estimates with silicon-vendor data — LEF areas 49,488.5 µm² (IMEM) /
> 49,419.2 µm² (trace), read access 5.13–5.44 ns / 7.05–7.35 ns at slow
> corner. Yosys synthesis vs PDK stdcells: flop-based 256×32 = 667,441 µm²
> vs macro → **13.5× block-level** (storage-only 8.1× vs the 8.7× estimate
> above, 7% gap explained by decode/mux overhead). Updated budget:
> **~227k µm² ≈ 7.4 tiles (31%)**, 50 MHz closes with +11.6/+9.7 ns margin.
> R1 retired; remaining SRAM work is P&R execution on Tiny Tapeout CI.

**The quantification of Jane Street's SRAM hint** (`[derived]`):
- 256×32 IMEM in flops: 8,192 × 52.62 = **431,062 µm² ≈ 13.8 tiles**
  vs SRAM 1.6 tiles → **SRAM ~8.7× denser**.
- 204-entry trace in flops: 8,160 × 52.62 = 429,379 µm² ≈ 13.7 tiles
  vs SRAM 1.6 tiles → **~8.6× denser**.
- Even a minimal 4 Kbit IMEM in flops (6.9 tiles) costs more than the
  *entire logic* of the PE. **SRAM is not an optimization; below ~4
  Kbit it is the only way the design fits.** This is also why R1 (§9)
  is the top risk: if SRAM integration fails, the fallback is a
  128×32 flop IMEM (~6.9 tiles) + 32-entry flop trace (~2.2 tiles),
  pushing the total to ~16 tiles — fits, but tight, and firmware
  shrinks to match.

Headroom (~69% of tiles) is deliberate: P&R at 5 metals, ECO margin,
and room for the stretch accelerators nobody has designed yet.

## 5. Firmware mapping

Convention: `@50 MHz`, 1 cycle = 20 ns. `d=n` = delay field.
The assembler's job (§7.1): `PSETR R0, bit(115200)` assembles the
delay fields from the *target* timing — firmware states intent, the
toolchain proves the cycles.

### 5.1 UART TX 115200 8N1 (bit = 434 cycles)

```
        LDI  R1, 8            ; bit counter
        LDI  R2, 1            ; shift amount
        PMASK 0x01           ; L0 = TX
        PSET 0x00, d=13      ; START bit (low), 14 cyc
        SHR  R0, R0, R2      ; --">>" not needed yet; keep pipeline full
```
Cleaner loop (pin stable exactly 434 cycles/bit):
```
txbit:  PSETR R0, d=13       ; 14 cyc, TX = R0[0]
        SHR  R0, R0, R2      ; 1 cyc
        DJNZ R1, txbit       ; 1 cyc (taken or not — same cost)
        SLEEP 417            ; 418 cyc  → 14+1+1+418 = 434 ✓
        ; after loop: R0 shifted 8×, TX = last data bit
        PSET 0x01, d=13      ; STOP bit (high)
        SLEEP 417            ; + SHR/DJNZ skipped → pad: SLEEP 419
```
(Exact padding is the assembler's arithmetic, not the programmer's —
the listing *is* the timing proof.) Full byte ≈ 10 × 434 = 4,340
cycles ≈ 86.8 µs. **Firmware: 8 instructions.**

### 5.2 UART RX 115200 (with autobaud for free)

```
        PMASK 0x02                    ; L1 = RX
        WAIT {pin=1,falling,t=1M}, R3  ; R3 = idle→start time (baud measurable!)
        ; R3 ≈ cycles since last edge — firmware can derive actual baud
        SLEEP 216                     ; → sample at bit center
        LDI  R1, 8
        LDI  R4, 0                    ; accumulator
        LDI  R7, 0x02                 ; RX mask
rxbit:  SLEEP 427                     ; 428 cyc
        PGET R5                       ; 1 — sample RX (sync latency = const 2, §2.2.4)
        AND  R6, R5, R7               ; 1 — isolate
        SHL  R6, R6, R8               ; 1 — R8=6: bit1 → bit7
        SHR  R4, R4, R2               ; 1 — R2=1
        OR   R4, R4, R6               ; 1 — insert at top
        DJNZ R1, rxbit                ; 1 → 428+6 = 434 ✓
        PUSH R4                       ; byte to host
```
**9 instructions.** Note what `WAIT→Rd` buys: the same firmware that
receives also *measures* the peer's baud — no separate autobaud routine.

### 5.3 SPI master @1 MHz (SCLK period = 50 cycles)

Pack `{SCLK, MOSI}` in R0[1:0], PMASK=0x03; MISO=L2:
```
        LDI R1, 8
        LDI R2, 0x02        ; SCLK bit
        LDI R6, 0xFD        ; ~SCLK
spibit: PSETR R0, d=23      ; 24 cyc: MOSI=data, SCLK=0
        OR   R0, R0, R2     ; 1: SCLK=1
        PSETR R0, d=0       ; 1: SCLK rises (MISO setup satisfied)
        PGET R3             ; 1: sample MISO
        AND  R4, R3, R5     ; 1: R5=0x04 isolate
        SHR  R9, R9, R10    ; accumulate (R10=1)
        OR   R9, R9, R4
        AND  R0, R0, R6     ; 1: SCLK=0
        SLEEP 15            ; 16
        DJNZ R1, spibit     ; 1  → 49 cyc/bit ≈ 1.02 MHz ✓
```
Asymmetry (SCLK high ≈ 6 cyc, low ≈ 42) is *visible in the listing* —
tunable to 25/25 by moving delay budget. CPOL/CPHA variants are
firmware, not silicon.

### 5.4 I2C master 100 kHz (the open-drain test)

```
        PMODE R0            ; R0 = 0x0F0F: SDA/SCL open-drain + pull-up
        PDIR  0x03          ; drive-enable both (OD: 1=Hi-Z, 0=low)
        ; START: SDA ↓ while SCL high
        PSET 0x03, d=99     ; both released → pulled high
        PSET 0x02, d=99     ; SDA low → START
        PSET 0x00, d=99     ; SCL low, bus owned
wrbit:  PSETR R1, d=0       ; SDA = data bit (PMASK=0x01)
        SLEEP 99
        PSET 0x03, d=0      ; release SCL (PMASK=0x02)
        WAIT {pin=SCL,high,t=64K}, R3  ; **clock stretching**: slave may hold SCL
        SLEEP 199           ; high period (minus WAIT overhead — assembler-resolved)
        PSET 0x00, d=99     ; SCL low
        DJNZ R9, wrbit
        ; ACK: release SDA, raise SCL, sample
        PSET 0x01, d=0      ; release SDA
        PSET 0x03, d=0      ; SCL high
        SLEEP 199
        PGET R3             ; SDA low = ACK
```
Half-bit = 500 cycles @100 kHz; the listing shows where each goes.
Clock stretching — the thing that breaks naive bit-bangers — is one
`WAIT` with a bounded timeout. Multi-master arbitration (SDA
read-back while driving) falls out of PGET.

### 5.5 Stretch protocols — feasibility at 50 MHz (honest)

| Protocol | Rate | Cycles/bit | Verdict |
|---|---|---|---|
| JTAG | ≤10 MHz (TCK) | ≥5 | ✅ feasible; TAP FSM in firmware; **Observer snoops live JTAG = reverse-engineering demo** |
| SWD | ≤4 MHz | ≥12 | ✅ feasible |
| PS/2 | 10–16 kHz | ~3,500 | ✅ trivially feasible |
| CAN | ≤1 Mbps | ≥50 | ✅ feasible (external transceiver; bit-stuff in firmware) |
| USB low-speed | 1.5 Mbps | 33.3 | ⚠️ **TX signaling feasible** (PSETR d=31 chains ≈ 32 cyc/pin-update); NRZI+bit-stuff RX in firmware likely **not** at 33 cyc/bit. Full SIE: no. |
| 10BASE-T Ethernet | 10 Mbps Manchester | 5 (2.5/half) | ❌ **not feasible** at 50 MHz — fastest pin toggle is 1/cycle and a MAC needs far more. Do not claim. (Revisit only if harness clock ≫50 MHz — R2.) |

The JTAG angle deserves emphasis: a protocol emulator that can *drive*
JTAG while the Observer *records* a third party's JTAG session is a
complete debug/reverse-engineering story in one chip — and a demo
Jane Street's hardware team would actually watch.

## 6. Novelty thesis (aimed at the two judging criteria)

**Criterion 1 — unique functionality.** The field (§8) converges on
"PIO-like timed ISA," which is the obvious answer and therefore not a
differentiator. Ours:

1. **The Observer: the chip also listens.** A programmable,
   cycle-timestamped event-capture engine with 204-entry trace SRAM,
   running independently of (and concurrently with) the protocol
   engine. Tarang is not just a protocol *speaker* — it is an 8-channel
   logic analyzer with 20 ns resolution that fits the same die. This
   directly serves the competition's own motivation ("a useful tool for
   hardware debugging and reverse engineering"), and no surveyed entrant
   has anything like it. Demo: drive JTAG with the PE while the
   Observer records a *different* live bus — one chip, both sides of a
   reverse-engineering session.
2. **Measurement as ISA semantics.** `WAIT` returns elapsed cycles;
   `CAP` snapshots `{timestamp, pins}` atomically. Competing timed-ISAs
   (PIO included) can *emit* precisely but cannot *measure* — Tarang
   firmware characterizes unknown peers (autobaud in §5.2 falls out of
   the receive path; pulse-width/period measurement is two
   instructions). Emitter → characterizer is a genuine capability gap.

**Criterion 2 — novel design & verification methodology.**

3. **A machine-checked, cycle-exact timing contract.** The ISA is
   specified once in YAML; the YAML generates the RTL decode package,
   the assembler, the C golden model, and the timing-contract table —
   CI fails on any drift (single-source discipline). On top of that, the
   contract items in §2.2 are *proven* with SymbiYosys: per-opcode
   latency = 1+delay, pin-effect/sample points, synchronizer latency,
   WAIT timeout bounds, observer capture correctness and timestamp
   monotonicity. Firmware timing stops being tested and starts being
   *proven* — for a chip whose entire purpose is timing, this is the
   methodology the brief asks for.
4. **Agentic verification at tapeout scale (AgeNex-style).** A
   multi-agent campaign where agents *do* verification work, not just
   write tests: a coverage agent mines the coverage DB and proposes
   directed tests for holes; a triage agent delta-debugs failures to
   minimal reproducers and proposes fixes; a formal agent mines SVA
   properties from the ISA YAML (e.g., "for every opcode, latency ==
   1+delay"); a spec agent keeps the docs in sync with the YAML. Every
   agent action is an artifact in CI with deterministic replay seeds —
   agents are *reviewed like engineers*, and the campaign itself is part
   of the open-source deliverable. Plus: the RTL is proven on the Zybo
   Zynq-7010 FPGA *before* tapeout (§7.7), with the Observer's trace
   cross-checked against ILA — "debug capability and waves," on real
   hardware, before silicon.

## 7. Verification methodology plan

Philosophy: the verification *is* the product story. A timing-exact
chip verified by vibes would be an embarrassment; a timing-exact chip
with proven timing is the entry.

### 7.1 Single-source ISA (`isa.yaml` — table stakes, done right)

One YAML file generates: SystemVerilog decode package, assembler
(Python), C golden model, ISA spec docs, and the formal timing table.
A CI job regenerates all artifacts and fails on any diff — including
hand-edited drift. (axpe does this; matching it is required, not novel.
§6.3/6.4 are the novelty.)

### 7.2 Differential testing (golden model vs RTL)

- C/Python golden model (from YAML) vs Verilator RTL, **lockstep**:
  after every instruction, compare GPRs, flags, PC, pin outputs.
- Stimulus: constrained-random *program generator* (random opcodes,
  delays, immediates) + constrained-random *pin scenarios* (edges,
  glitches, stretches, timeouts). Seeds archived; failures replay
  deterministically.

### 7.3 Dynamic TB (cocotb or UVM-style SystemVerilog)

- Drivers: host-port model (loads programs, pokes FIFOs), pin wiggler
  (protocol peer models: UART/SPI/I2C with randomized baud ±2%, phase,
  I2C clock-stretch).
- Scoreboards: FIFO data integrity, trace-entry reconstruction
  (re-derive pin waveform from trace, compare to driven waveform).
- Functional coverage: opcode × delay-value crosses, WAIT
  timeout/condition crosses, FIFO full/empty × PUSH/PULL crosses,
  observer trigger-mode × watermark crosses, illegal pin-map configs.
- SVA assertions embedded in RTL (see §7.4).

### 7.4 Formal (SymbiYosys + yosys-smtbmc — fits build-in-public)

| ID | Property | Technique |
|---|---|---|
| F1 | Every opcode completes in exactly 1+delay cycles | induction over ISA |
| F2 | PSET/PSETR effect visible at pins ≤1 cycle after cycle 0 | BMC |
| F3 | PGET returns the sync-pin value of 2 cycles prior | BMC + sync model |
| F4 | WAIT: elapsed == actual wait; timeout ⟺ TIMEOUT set | induction |
| F5 | Observer: trigger ⟹ entry written ≤K cycles; timestamps non-decreasing | induction |
| F6 | Host-port loader: byte stream in ⟹ IMEM contents correct | induction |
| F7 | FIFOs: no drop except with OVERRUN sticky; no duplication; order preserved | induction |
| F8 | Pin mux: illegal mapping ⟹ GND + CONFIG_ERR (never X, never short) | BMC |

F1–F4 are the *timing contract made machine-checkable* — the
centerpiece of the methodology story.

### 7.5 Firmware-level verification

- UART/SPI/I2C firmware vs **independent** peer models (not the RTL's
  own assumptions): randomized baud error, jitter, I2C stretch,
  SPI CPOL/CPHA — self-checking byte streams, 10K+ frames `[est
  target]`.
- Protocol compliance assertions (framing, ACK/NAK, START/STOP
  legality) as checkers on the pin waveform.
- Assembler-resolved timing re-verified: assemble → extract per-bit
  cycle counts from the listing → assert against protocol spec.

### 7.6 Agentic layer (the AgeNex playbook, open-sourced)

| Agent | Input | Output (CI artifact) |
|---|---|---|
| coverage-agent | coverage DB + ISA YAML | directed-test proposals for holes; merged after review |
| triage-agent | failing seed + waveforms | minimal reproducer (delta-debugged program), suspected RTL vs TB vs spec, proposed fix |
| formal-agent | ISA YAML + RTL | mined SVA properties; coverage of F1–F8 against code |
| spec-agent | YAML + docs | doc-drift PRs; blocks merge on inconsistency |
| firmware-agent | protocol spec text | new firmware + peer-model tests |

Rules: agents never touch RTL directly — they open reviewed artifacts;
every agent run pins its model/seed; replay is deterministic. The
campaign log is published with the repo: *"here is what the agents
found"* is itself judging-criteria evidence.

### 7.7 FPGA prototype (Zybo Zynq-7010 — pre-tapeout proof)

- Synthesize PE+Observer with IMEM mapped to BRAM; ARM (PS) drives the
  host-port protocol via EMIO; loopback + peer boards at 50 MHz.
- **Cross-check the Observer against ILA**: drive a known pin pattern,
  compare Observer trace timestamps to ILA capture — the on-chip logic
  analyzer proves itself against the lab instrument.
- Validates: the cycle-exact contract in real hardware (§2.2),
  host-port robustness, firmware for all three mandatory protocols.
- This is also the demo platform for the "waves" story: GTKWave/FST
  from real captures, in the repo.

### 7.8 Post-silicon bring-up plan (winners get chips back)

1. SRAM BIST (`_bm_bist` macros) → IMEM/trace health.
2. Host-port self-test: LOAD → VERIFY → GO on a hello-world blinky.
3. Loopback firmware: UART TX→RX on-chip, SPI loopback — proves the
   PE + pin fabric.
4. Observer self-capture: PE emits a known pattern, Observer records
   it, host reconstructs — proves timestamp + trigger + trace path.
5. JTAG demo (§5.5): the public video.

## 8. Competitive landscape (surveyed 2026-09-26)

All repos below build in public and reference the Jane Street
competition. Status is as-observed; the field moves fast.

| Entrant | Approach | Status | Read |
|---|---|---|---|
| **scynth-labs/atomix** `axpe` | timed-ISA µCPU; per-insn delay; **WAITE returns elapsed cycles**; single-source `isa.yaml` → codegen | Arch defined, building | Strongest conceptually; closest to our PE. No observer, no formal-timing proofs described, no trace. |
| **thomasgilbert481/tt_um_loom** "Loom" | AI-architected (Fable 5.1); cycle-exact `SEMANTICS.md`; `isa.yaml` | In progress | Best flow-facts research (`tt_cmos5l_facts.md` — cited in §0.1). Notes 8×4 unavailable. |
| **enriquenb/pe16-protocol-emulator** "PE-16" | timed-ISA coprocessor; solo ~2 h/day | In progress | Internal freeze Jan 10, 2027. Disciplined but small bandwidth. |
| **emilpopovic/proto-emu** | SystemVerilog tiny CPU; host-link PHYs done | Skeleton (core empty) | Early; infra-first approach. |
| **pfernandez35/protocol-emulator** | programmable micro-CPU, ~24 K cells | Early | Sparse public detail. |
| **sealvlon/…** | hello-world fixed UART stage (flow validation first) | Validating flow | Claims 8×4 tiles — invalid per flow facts; likely course-corrects. |

**Positioning.** The field converges on the PIO-like timed ISA — it is
the obvious answer, so it cannot be our edge. Our wedge, in order:
(1) the Observer/trace engine — *nobody* has it, and it turns the chip
into the debug tool the brief describes; (2) measurement-as-ISA
(`WAIT`→cycles, `CAP`) — axpe's WAITE is the only adjacent idea, and
we go further with atomic snapshot + hardware trace; (3) machine-checked
timing contract + agentic verification campaign — the methodology half
of the judging criteria, played with our actual strengths; (4)
FPGA-proven on Zybo before tapeout, with the Observer cross-checked
against ILA. If axpe ships WAITE + single-source first, we still win
on 1, 3, and 4 — provided we execute.

## 9. Risks, open questions, decision log

### 9.1 Risks (ordered by expected damage × probability)

| ID | Risk | Mitigation |
|---|---|---|
| **R1** | **SRAM integration in the TT cmos5l flow fails or slips.** TT: "not trivial"; no published CMOS5L SRAM tapeout; macros are SG13G2 re-exports. Without SRAM the design barely fits (§4.4). | Abstract the memory interface on day one (identical RTL ports for macro vs flop array); copy the `tt_um_urish_sram_test` integration pattern; run a *trial hardening* of IMEM+trace macros alone by mid-Oct 2026 — the single highest-priority de-risking task. Fallback: 128×32 flop IMEM + 32-entry flop trace (§4.4). |
| R2 | **Harness clock ≠ 50 MHz** (or too jittery for cycle-exact claims). | Verify against TT demo-board docs immediately; the entire §5 math re-derives from one parameter — keep `CLOCK_HZ` a top-level constant everywhere (RTL, YAML, assembler, TB). |
| R3 | Area overrun at P&R (5-metal stack, 6×4 only). | 69% headroom in the budget (§4.4); first synthesis by Oct 2026 replaces estimates; no feature may consume headroom without a re-budget. |
| R4 | Single-port trace SRAM contention (Observer writes vs host reads). | Priority to Observer writes; host reads stall with a BUSY status bit — host is not cycle-exact, so this is legal. Document the arbitration rule in ISA v0.2. |
| R5 | Schedule: Jan 18, 2027 with a small team and a day job. | Phase the firmware (UART → SPI → I2C → JTAG → stretch); freeze RTL early Dec 2026; the FPGA prototype (§7.7) de-risks firmware in parallel with hardening. |
| R6 | PDK/flow churn (CMOS5L is preview; TT flow moves). | Pin the flow commit the way Loom's fact sheet does; re-verify monthly; keep the trial-hardening (§R1) green in CI. |

### 9.2 Open questions

- **Q1.** IMEM depth: 256×32 vs 512×32 (+~1 tile)? Decide after
  firmware sizing (UART+SPI+I2C+JTAG assembled size × 2 headroom).
- **Q2.** ALU richness: add CRC-8/16 assist or multiply? (Tempting for
  CAN/USB-CRC; costs ~300–500 cells `[est]`. Default: no — firmware
  CRC at 50 MHz is fast enough for ≤1 Mbps.)
- **Q3.** FIFO depths (16×16 proposed): revisit after host-port latency
  measurement on FPGA.
- **Q4.** Should the PE read the trace buffer? (Default: no — §3.5.
  Revisit if a stretch protocol needs adaptive RX.)
- **Q5.** Observer trigger expressiveness: is per-pin 2-bit edge config
  enough, or do we need sequence triggers (A-then-B)? Cost/benefit TBD.
- **Q6.** Exact `WAIT` timeout presets and `CAP` special-reg layout —
  ISA v0.2 detail.
- **Q7.** Pull-up strength / open-drain electrical validation on IHP
  pads — check the IO library docs; external pull-ups as fallback.

### 9.3 Decision log (phase-1; all reversible until RTL freeze)

| ID | Date | Decision | Rationale | Revisit if |
|---|---|---|---|---|
| D1 | 2026-09-26 | PE + hardware Observer (not dual symmetric cores) | Area (~2 vs ~8 tiles `[est]`); the observer covers "listen while talking" with simpler firmware | Observer proves inadequate for a target use case |
| D2 | 2026-09-26 | 32-bit fixed-width ISA (not 16-bit) | 16-bit cannot hold pin-mask + delay + reg fields; 32-bit gives single-word LDI; +0.7 tiles accepted | Synthesis shows decode blowup |
| D3 | 2026-09-26 | IMEM 256×32 SRAM primary; flop array fallback | §4.4: SRAM ~8.7× denser; flops can't fit ≥4 Kbit | R1 trial fails → fallback |
| D4 | 2026-09-26 | Timing contract: 1+delay cycles; WAIT the only data-dependent insn | Provable determinism; formal-checkable (§7.4) | A protocol needs sub-cycle pin ops (then: faster clock, R2) |
| D5 | 2026-09-26 | `ena`=0 → PROG mode, `ena`=1 → RUN mode | Uses the existing harness signal for exactly this; no pin wasted on mode select | TT redefines `ena` semantics |
| D6 | 2026-09-26 | Non-pipelined single-cycle core | PRU-style determinism over IPC; every cycle accounted | Timing closure fails at 50 MHz (add pipeline → lose contract; prefer slower clock) |
| D7 | 2026-09-26 | Unified 2-wire framed host port for PROG + RUN | Pin budget (§3.7); one FSM to verify instead of two | Host bit-bang proves too slow in practice (measure on FPGA) |
| D8 | 2026-09-26 | 10BASE-T out of scope at 50 MHz | 5 cycles/bit Manchester cannot host a firmware MAC; honesty > ambition | Harness clock ≫50 MHz verified |

### 9.4 Proposed milestones (to 2027-01-18)

| When | Milestone |
|---|---|
| Oct 2026 | **R1 trial hardening** (SRAM macros alone through the TT flow); ISA v0.2 frozen; `isa.yaml` + codegen + assembler |
| Nov 2026 | PE RTL + F1–F4 formal green; UART firmware on FPGA; Observer trace vs ILA cross-check |
| Dec 2026 | **RTL freeze**; SPI+I2C+JTAG firmware; full formal suite (F1–F8); agentic campaign running in CI |
| Early Jan 2027 | Gate-level sim + STA; DRC/LVS clean; submission |

### 9.5 Suggested repo layout (build-in-public from day one)

```
tarang/
  isa/isa.yaml            # single source of truth (§7.1)
  isa/gen/                # generated: decode.sv, assembler, golden model, docs
  rtl/                    # pe.sv, observer.sv, pinmux.sv, hostport.sv, fifos/...
  tb/                     # cocotb/UVM TB, peer models, coverage
  formal/                 # .sby configs for F1–F8
  fw/                     # uart.s, spi.s, i2c.s, jtag.s + tests
  fpga/zybo/              # Vivado project, BRAM-mapped IMEM, ILA configs
  agents/                 # coverage/triage/formal/spec/firmware agents + run logs
  docs/                   # this file, ISA.md (generated), DECISIONS.md
  flow/                   # TT hardening configs, trial runs (R1)
```

---

*End of phase-1 architecture proposal. Next step if approved: ISA v0.2
(detail the operand encodings, WAIT/CAP config layouts, host-port frame
spec) and the R1 SRAM trial hardening — in that order.*
