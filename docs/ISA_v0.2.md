# Tarang-32 ISA Specification — v0.2 (encoding freeze)

| | |
|---|---|
| Version | v0.2 |
| Date | 2026-09-26 |
| Status | **Encoding frozen.** Implementation-ready. No RTL written yet. |
| Machine source | [`isa_v0.2.yaml`](isa_v0.2.yaml) — the single source of truth (ARCHITECTURE.md §7.1). This document is generated prose *about* that file; on any disagreement, the YAML wins. |
| Semantics source | `ARCHITECTURE.md` §2 (v0.1 proposal) — **no instruction semantics or mnemonics were changed in v0.2.** |
| Workers | Encoding map (A) · Timing contract formalization (B) · Observer ISA interface (C), merged by the Phase-1 coordinator. |

## 1. What v0.2 is

v0.1 (ARCHITECTURE.md §2) defined *what* each instruction does. v0.2 defines
*exactly which bits do it*: every `[20:0]` operand field for all 24 opcodes,
the full MRS/MSR special-register address map, the STATUS bit layout, the
Observer configuration packing, the host-port command bytes, and the
READ_TRACE wire framing. Three worker drafts were merged; three merge
conflicts were adjudicated (M1/M2/M3, §7). Everything v0.1 left as
"detail for v0.2" is now specified — or explicitly listed as still open
with an owner (§8).

## 2. Encoding rationale

- **Fixed 32-bit words.** `[31:26]` opcode (64 majors), `[25:21]` 5-bit
  delay `d` (0–31), `[20:0]` operand. Both upper fields are **frozen by
  contract** and never repurposed.
- **Uniform register lanes.** Rd/Rs at `[20:17]` everywhere; ALU adds
  Rs1 `[16:13]`, Rs2 `[12:9]`. One register-file port mapping, minimal
  decode muxing.
- **`reserved_zero` discipline.** SLEEP, WAIT, HLT cannot use the delay
  field meaningfully (SLEEP carries its duration in imm13; WAIT is already
  data-dependent; HLT is indefinite), so their delay bits are *reserved,
  must be zero*: the assembler rejects nonzero, hardware ignores nonzero.
  This keeps the cycle-exact contract auditable — a nonzero delay can never
  silently alter timing.
- **6-bit special-register addresses** (`sreg` at `[16:11]` in MRS/MSR):
  64 addresses, 0x00–0x13 assigned, 0x14–0x3F held unallocated.

## 3. Instruction encodings

`d` = `instr[25:21]`. "cycles" is the exact occupancy. Master table
(field order msb→lsb within `[20:0]`):

| # | Mnemonic | `[20:0]` layout | delay | cycles | flags |
|---|---|---|---|---|---|
| 0 | PSET | `imm8[20:13]`, rsv `[12:0]` | applies | 1+d | — |
| 1 | PSETR | `rs[20:17]`, rsv `[16:0]` | applies | 1+d | — |
| 2 | PGET | `rd[20:17]`, rsv `[16:0]` | applies | 1+d | — |
| 3 | PMASK | `imm8[20:13]`, rsv `[12:0]` | applies | 1+d | — |
| 4 | PDIR | `imm8[20:13]`, rsv `[12:0]` | applies | 1+d | — |
| 5 | PMODE | `rs[20:17]`, rsv `[16:0]` | applies | 1+d | — |
| 6 | SLEEP | `imm13[20:8]`, rsv `[7:0]` | **reserved_zero** | **1+imm13** | — |
| 7 | WAIT | `cfg8[20:13]`, `rd[12:9]`, rsv `[8:0]` | **reserved_zero** | 1..1+timeout | TIMEOUT* |
| 8 | CAP | `rd[20:17]`, rsv `[16:0]` | applies | 1+d | — |
| 9 | MOV | `rd[20:17]`, `rs[16:13]`, rsv `[12:0]` | applies | 1+d | — |
| 10 | LDI | `rd[20:17]`, `imm16[16:1]`, rsv `[0]` | applies | 1+d | — |
| 11 | PUSH | `rs[20:17]`, rsv `[16:0]` | applies | 1+d | TX_OVERRUN* |
| 12 | PULL | `rd[20:17]`, rsv `[16:0]` | applies | 1+d | RX_UNDERRUN* |
| 13 | MRS | `rd[20:17]`, `sreg[16:11]`, rsv `[10:0]` | applies | 1+d | — |
| 14 | MSR | `rs[20:17]`, `sreg[16:11]`, rsv `[10:0]` | applies | 1+d | (W1C) |
| 15 | ADD/SUB | `rd[20:17]`, `rs1[16:13]`, `rs2[12:9]`, `fn[8]`, rsv `[7:0]` | applies | 1+d | Z N C |
| 16 | AND/OR/XOR | `rd[20:17]`, `rs1[16:13]`, `rs2[12:9]`, `fn[8:7]`, rsv `[6:0]` | applies | 1+d | Z N |
| 17 | SHL/SHR | `rd[20:17]`, `rs1[16:13]`, `rs2[12:9]`, `fn[8]`, rsv `[7:0]` | applies | 1+d | Z N C |
| 18 | CMP | `rs1[20:17]`, `rs2[16:13]`, rsv `[12:0]` | applies | 1+d | Z N C |
| 19 | JMP | `target9[20:12]`, `cond4[11:8]`, rsv `[7:0]` | applies | 1+d | — |
| 20 | DJNZ | `rs[20:17]`, `target9[16:8]`, rsv `[7:0]` | applies | 1+d | — |
| 21 | CALL/RET | `target9[20:12]`, `is_ret[11]`, rsv `[10:0]` | applies | 1+d | — |
| 22 | HLT | rsv `[20:0]` | **reserved_zero** | indefinite | — |
| 23 | EVT | `imm4[20:17]`, rsv `[16:0]` | applies | 1+d | — |

`*` = sticky W1C flag. `rsv` = reserved, must be zero (assembler rejects).

**Sub-opcode codes.** ADD/SUB `fn[8]`: 0=ADD, 1=SUB. AND/OR/XOR `fn[8:7]`:
00=AND, 01=OR, 10=XOR, 11=reserved. SHL/SHR `fn[8]`: 0=SHL, 1=SHR (amount
Rs2[3:0]; C←last bit shifted out). CALL/RET `is_ret[11]`: 0=CALL, 1=RET
(target9 in the JMP-compatible `[20:12]` lane).

**JMP `cond4`:** 0000=AL, 0001=Z, 0010=NZ, 0011=C, 0100=NC, 0101=TMO
(TIMEOUT sticky), 0110=RXNE (RX FIFO not empty), 0111=TXNF (TX FIFO not
full); 1000–1111 reserved.

**WAIT `cfg8`** (msb→lsb): `pin[2:0] | pol | mode[1:0] | tsel[1:0]`.
mode: 00=level, 01=rising, 10=falling, 11=either. pol (level mode only):
1=wait-for-high, 0=wait-for-low. **tsel→timeout:** 0→256, 1→4096,
2→65536, 3→1048576 cycles (ascending — larger code, longer timeout).
Rd←elapsed cycles; TIMEOUT sticky iff the timeout expired.

**target9 (M3):** `target9[8]` is reserved, must be zero (assembler
rejects); hardware implements an 8-bit PC and ignores bit 8. Reserved for
a future IMEM-512 extension (ARCHITECTURE.md Q1).

## 4. Special registers

6-bit `sreg` at operand `[16:11]`. MRS reads; MSR writes (W1C for
stickies; MSR to EVTFLAG ignored — the host clears).

| Addr | Name | Access | Reset | Width/content |
|---|---|---|---|---|
| 0x00 | STATUS | RO/W1C | 0x0000 | live bits + sticky flags (bit table below) |
| 0x01 | CYCLES_LO | RO | 0x0000 | timestamp[15:0] |
| 0x02 | CYCLES_HI | RO | 0x0000 | timestamp[31:16] |
| 0x03 | CTS_HI | RO | 0x0000 | CAP snapshot ts[31:16] |
| 0x04 | CTS_PINS | RO | 0x0000 | CAP snapshot {8'b0, pins[7:0]} |
| 0x05 | OBS_PTR | RO | 0x0000 | trace entries valid: 0..204, saturates, never wraps |
| 0x06 | PMASKR | RO | 0x00FF | PMASK readback |
| 0x07 | PDIRR | RO | 0x0000 | PDIR readback (all-Hi-Z power-on default) |
| 0x08 | PMODER | RO | 0x0000 | 8×2-bit pin modes, pin i = [2i+1:2i] |
| 0x09 | TRIG_MODE | RW | 0x0000 | [1:0]: 00=DISABLED, 01=EDGE, 10=PATTERN, 11=PULSE |
| 0x0A | PIN_SEL | RW | 0x0000 | [2:0] PULSE-mode pin |
| 0x0B | MASK | RW | 0x0000 | [7:0] PATTERN mask |
| 0x0C | VALUE | RW | 0x0000 | [7:0] PATTERN value |
| 0x0D | EDGE_MASK | RW | 0x0000 | [7:0] EDGE quick-enable |
| 0x0E | EDGE_CFG0 | RW | 0x0000 | pins 0–3 edge select, pin-major 2b |
| 0x0F | EDGE_CFG1 | RW | 0x0000 | pins 4–7 edge select, pin-major 2b |
| 0x10 | WMARK | RW | 0x0000 | [7:0] watermark (0=disabled) |
| 0x11 | PRESCALER | RW | 0x0000 | [1:0] shared: 00=÷1, 01=÷16, 10=÷256, 11=÷4096 |
| 0x12 | OBS_CTL | RW | 0x0000 | [0]=OBS_EN, [1]=OBS_ARM (TBD T4), [2]=OBS_CLR W1C strobe |
| 0x13 | EVTFLAG | RO | 0x0000 | 16 host event flags (PE raises via EVT; host clears) |
| 0x14–0x3F | — | — | — | unallocated (MRS→0, MSR ignored; T5) |

**STATUS (0x00) bit layout:**

| Bit | Name | Kind | Meaning |
|---|---|---|---|
| 0 | TIMEOUT | sticky/W1C | WAIT timed out |
| 1 | TX_OVERRUN | sticky/W1C | PUSH to full TX FIFO (dropped) |
| 2 | RX_UNDERRUN | sticky/W1C | PULL from empty RX FIFO (Rd←0) |
| 3 | TRACE_FULL | sticky/W1C | trace SRAM full; capture stopped |
| 4 | CONFIG_ERR | sticky/W1C | illegal pin-mux / config fault |
| 5,7 | — | reserved | must-be-zero / reads zero |
| 6 | — | reserved | **held for CALL_OVF** (proposal P2) |
| 8 | PE_RUNNING | live/RO | PE fetching/executing |
| 9 | PE_HALTED | live/RO | PE halted (HLT) |
| 10 | TX_EMPTY | live/RO | TX FIFO empty |
| 11 | RX_FULL | live/RO | RX FIFO full |
| 12 | TRACE_WM | **sticky (OBS_CLR only)** | watermark reached — the v0.1 "host event" (M2); cleared only by OBS_CLR (MSR OBS_CTL bit 2), NOT by a STATUS W1C write — W1C covers bits [4:0] only; see D7 erratum below |
| 13 | CFG_DIRTY | live/RO | host WR_CFG touched live config (clear: T3) |
| 14–15 | — | reserved | reads zero |

Note: the 8-bit host-port `RD_STATUS` byte (ARCHITECTURE.md §3.6) is a
*different* register; its TRACE_WM bit is **live** (`OBS_PTR >= WMARK`,
combinational). The two views are intentionally different: firmware gets
the latched event, the host gets the live level.

**Erratum D7 (2026-10-26) — TRACE_WM clear semantics, resolved
doc-side.** Earlier text described STATUS[12] TRACE_WM as sticky/W1C.
The RTL and the golden model have always cleared this bit only via
OBS_CLR (MSR OBS_CTL bit 2) or reset/prog_mode; an MSR write to STATUS
clears sticky bits [4:0] only. This document is corrected to match the
verified implementation; RTL and golden-model behavior are unchanged.
No shipped firmware image accesses this bit.

## 5. Timing contract (normative)

The 6-point cycle-exact contract (ARCHITECTURE.md §2.2) restated as
proof obligations T1–T17, each feeding the SymbiYosys suite (F1–F4,
ARCHITECTURE.md §7.4). "Shall" is normative.

- **T1.** Every instruction with opcode ≠ 7 shall occupy exactly `1+d`
  cycles. → F1
- **T2.** WAIT shall occupy `c` cycles, `1 ≤ c ≤ 1+timeout`, timeout ∈
  {256, 4096, 65536, 1048576} per tsel. → F1
- **T3.** PSET/PSETR/PDIR/PMODE shall commit their pin (or pin-control)
  effect at the end of cycle 0; the `d` delay cycles run with pins
  stable. → F2
- **T4.** PGET shall return the synchronized pin vector captured at the
  end of cycle 0. → F3
- **T5.** The 2-FF synchronizer is architectural: PGET/CAP/Observer shall
  see the physical pins exactly 2 core cycles earlier — no more, no
  less. Firmware subtracts this constant; it is never a guess. → F3
- **T6.** No hidden cycles: single-cycle IMEM fetch; the loader writes
  IMEM only in PROG mode with the PE in reset. → F1
- **T7.** WAIT shall always write elapsed to Rd and set TIMEOUT iff the
  timeout expired (and only then). → F4
- **T8.** WAIT elapsed = core cycles from the end of the base cycle until
  the condition first becomes true; **0 if true at entry**
  *(adopted interpretation)*. A condition true exactly at the timeout
  boundary counts as satisfied (elapsed=T, no TIMEOUT). → F4
- **T9.** SLEEP shall occupy exactly `1+imm13` cycles, `d` reserved_zero.
  **Known tension** with T1/§2.2.1 — flagged, not resolved (T2/P1). The
  formal team checks SLEEP exactly as specified here. → F1
- **T10.** CAP shall latch `{timestamp[31:0], pins[7:0]}` atomically;
  Rd←ts[15:0]; CTS_HI/CTS_PINS hold the matching snapshot.
- **T11.** Pin effects committed at end of cycle 0 shall be visible at
  the physical pins ≤ 1 cycle later; PGET reads back output-driven pins
  post-synchronizer *(adopted interpretation)*. → F2
- **T12.** PUSH-full drops + TX_OVERRUN; PULL-empty returns 0 +
  RX_UNDERRUN; stickies set at end of base cycle. (Delay cycles still
  execute: 1+d total.)
- **T13.** Branches (JMP/DJNZ/CALL/RET) occupy exactly `1+d`; the branch
  takes effect at the end of the base cycle and the `d` delay cycles
  execute as NOP-equivalent *(adopted interpretation)*. DJNZ tests the
  **new** (post-decrement) Rs *(adopted interpretation)*. → F1
- **T14.** EVT raises EVTFLAG[imm4] at the end of its base cycle; `d`
  delay cycles run after. → F1
- **T15.** ALU/CMP/MOV/LDI/PMASK/MSR results commit at end of base cycle.
- **T16.** HLT stops the PE cycle counter (clocks gated); wake only on
  host GO or reset.
- **T17.** Observer adjacency: trigger→trace-commit ≤ **K=6** core
  cycles; timestamps non-decreasing. Tarang properties assume only this
  bound (observer internals are §6's). → F5

**SVA schemas** (parameterized; per-opcode instantiation is a 24-row
table in the YAML — no per-opcode expansion): `p_LAT(d)`,
`p_PIN_EFFECT(d)`, `p_PIN_VIS`, `p_SAMPLE(d)`, `p_SYNC2`, `p_NO_STALL`,
`p_WAIT_REPORT(tsel)`, `p_CAP_ATOMIC(d)`. TBD bind names for the formal
team: `issue`, `issue_next`, `eff_commit`, `dec_op`,
`wait_elapsed_cycles`, `wait_timed_out`, `wait_done`, `ts_at_commit`,
`pins_at_commit` (T9).

## 6. Observer programming model

**Q4 — decided for v0.2: no PE trace-data read; host-only read stands.**
A PE read path with writer-priority arbitration would inject unbounded,
pin-activity-dependent stalls into PE reads — breaking contract points
1/5/6 and F1, and forcing a data-dependent entry into the formal timing
table (defeating "the listing *is* the timing proof"). The dual-port
alternative is unproven in the TT CMOS5L flow (risk R1), costs area, and
has no committed firmware consumer: WAIT/CAP/`MRS OBS_PTR` already cover
PE-side measurement. Q4 stays open (owner: firmware phase) and reopens
only if a written, cycle-counted stretch firmware needs PE-side trace
consumption *and* the zero-cost host-mailbox fallback (RD_TRACE → RX
FIFO → PULL) is shown insufficient. PE reads OBS_PTR via MRS (pointer
only) — consistent with this decision.

**Trigger modes** (`TRIG_MODE`, M1 values): 00=DISABLED, 01=EDGE,
10=PATTERN, 11=PULSE. **Any write to TRIG_MODE disarms** (clears OBS_EN):
configure-then-arm; mode switches are never live. EDGE fires when a pin
with `EDGE_MASK[i]=1` and edge-select ≠ 00 (per-pin 2-bit: 00=disabled,
01=rising, 10=falling, 11=either, packed pin-major in EDGE_CFG0/1 — the
§3.5 "exact packing TBD", resolved) transitions. PATTERN fires per cycle
while `(pins & MASK) == VALUE` (level-triggered). PULSE: rising edge on
PIN_SEL commits an entry and arms; falling edge commits and disarms;
firmware subtracts the two 32-bit timestamps.

**Trace:** 40-bit entries `{ts[31:0], pins[7:0]}`, 204 entries in the
1024×8 SRAM. Commit bound K=6 cycles (1 latch + 5 byte-writes);
sustained 1 trigger / 5 cycles, faster bursts coalesce latest-wins;
timestamps non-decreasing. OBS_PTR saturates at 204 (never wraps),
updates atomically between commits. On full: stop (no overwrite, no
wrap) + TRACE_FULL sticky; triggers while full are ignored.

**Re-arm sequence** (normative order): ① `MSR OBS_CTL, OBS_CLR` (W1C:
OBS_PTR←0; TRACE_FULL untouched) → ② `MSR STATUS, TRACE_FULL` (W1C:
clear sticky) → ③ `MSR OBS_CTL, OBS_EN` (re-arm, last). Steps ①+③ may
combine as one write (clear-then-enable). Re-arm with DISABLED is a
benign no-op. Config registers are undisturbed by TRACE_FULL.

**Watermark:** WMARK=0 disables; 1–204 arm normally; 204 fires on the
final commit; >204 unreachable (documented, not faulted). TRACE_WM is
the sticky event bit (M2). The "optional status pin" is a
pin-mux-selectable status source, default disabled — zero pin-budget
cost.

**Host port** (frame `[CMD][LEN][DATA] → [ACK][DATA]`, ~10 host
clocks/byte): commands `0x01` LOAD_IMEM, `0x02` VERIFY_IMEM, `0x03`
WR_CFG, `0x04` RD_CFG, `0x05` WR_RXFIFO, `0x06` RD_TXFIFO, `0x07`
RD_TRACE, `0x08` RD_STATUS, `0x09` GO, `0x0A` HALT_REQ (`0x00` NOP,
`0x0B`–`0x0F`/`0xFF` reserved; unknown → NACK_ERR). ACK codes:
`0xA5` ACK_OK, `0x5A` NACK_BUSY (transient — bounded host retry),
`0x5B` NACK_ERR. Observer CFG_IDs `0x10`–`0x1A` map to the TRIG_MODE …
STATUS registers (`0x00`–`0x0F` reserved for pin-mux).

**READ_TRACE:** request `{start_idx, count}`; response
`[0xA5][ret_count][entries MSB-first][OBS_PTR]`. Entries are 5 bytes
`{ts[31:24]…ts[7:0], pins[7:0]}`. `count=0` = pointer poll; max 16
entries/frame (`count>16` → NACK_ERR); `start_idx ≥ OBS_PTR` clamps
(not an error). Entries are immutable once committed and the port
latches OBS_PTR at decode, so entry data **cannot tear**; NACK_BUSY is
returned only under sustained writer saturation (R4 arbitration rule,
documented as required).

**MSR sequences** (symbolic; configure-then-arm; OBS_EN set last):
EDGE = TRIG_MODE←DISABLED, EDGE_MASK, EDGE_CFG0, EDGE_CFG1, [WMARK],
[PRESCALER], OBS_CTL←OBS_EN. PATTERN = DISABLED, MASK, VALUE, [WMARK],
[PRESCALER], OBS_EN. PULSE = DISABLED, PIN_SEL, [WMARK], [PRESCALER],
OBS_EN. Host-driven capture during HLT uses the same order via WR_CFG;
every host WR_CFG sets the CFG_DIRTY note (T3); GO/HALT_REQ never touch
observer state — a capture configured before HLT continues across it.

## 7. TBDs resolved in v0.2

| # | TBD (source) | Resolution |
|---|---|---|
| R-1 | Observer EDGE per-pin 2-bit packing (§3.5 "exact packing TBD") | EDGE_CFG0/1, pins 0–3 / 4–7, pin-major 2-bit fields; codes 00=disabled, 01=rising, 10=falling, 11=either; `[15:8]` reserved |
| R-2 | WAIT timeout presets + CAP special-reg layout (Q6) | tsel→{256, 4096, 65536, 1M} ascending; CAP → Rd←ts[15:0] + CTS_HI/CTS_PINS via MRS |
| R-3 | PE-side trace read (Q4) | Decided NO for v0.2 with priced arbitration analysis; host-only stands; strict revisit condition, owner = firmware phase |
| R-4 | R4 arbitration rule documentation | Writer priority; host reads stall invisibly; NACK_BUSY only on sustained saturation; entry immutability → no tear |
| R-5 | TRIG_MODE values | M1: 00=DISABLED, 01=EDGE, 10=PATTERN, 11=PULSE (reset = safe DISABLED) |
| R-6 | TRACE_WM bit kind | M2: sticky event bit in STATUS[12] (the v0.1 "host event"); host status byte keeps a live TRACE_WM. **Amended by erratum D7 (2026-10-26): STATUS[12] is cleared only via OBS_CLR (MSR OBS_CTL bit 2), not by STATUS W1C writes (bits [4:0] only) — doc corrected to match RTL/golden model** |
| R-7 | target9[8] vs 256-word IMEM (T1) | M3: reserved, must-be-zero; hardware masks to 8-bit PC; held for future IMEM-512 |
| R-8 | Shared vs split prescaler | Single shared PRESCALER (0x11): timestamp and Observer on one time base — CAP snapshots and trace entries directly comparable |
| R-9 | PDIR reset value | 0x00 (all Hi-Z) — safe power-on default (T8: board review to confirm) |
| R-10 | CFG_DIRTY placement | STATUS bit 13, set by host WR_CFG only (clear condition: T3) |
| R-11 | EVTFLAG clear ownership | MSR writes ignored; host clears via host port |
| R-12 | Reserved opcode slots 24–63 | 24=CRC8, 25=CRC16, 26=PATMATCH, 27=MUL (intent-only); 28–63 unallocated; claiming forces v0.3 (§9) |
| R-13 | Trigger→commit bound (F5) | K=6 cycles; timestamps non-decreasing; sustained 1/5 cycles, latest-wins coalescing |
| R-14 | TRIG_MODE-write disarm rule | Any TRIG_MODE write clears OBS_EN — atomic mode switches |
| R-15 | PATTERN/PULSE edge semantics | PATTERN level-triggered (per-cycle fire); PULSE commits per qualifying edge |
| R-16 | "Optional status pin" (§3.5) | Mux-selectable status source, default disabled |
| R-17 | WMARK=0 | Disabled (documented, not faulted) |
| R-18 | Re-arm order | OBS_CLR → W1C TRACE_FULL → OBS_EN (①+③ may combine) |

## 8. Still open — TBDs with owners

None of these block the encoding freeze; all need a named ruling before
RTL/formal/firmware proceed. (T1 — target9 — was resolved by M3.)

| # | TBD | Owner |
|---|---|---|
| T2 | SLEEP: `1+imm13` vs contract "every insn = 1+delay" — adopt `1+d+imm13`? fold `d`? reword §2.2.1? | ISA lead + formal (F1 must encode the resolution) |
| T3 | CFG_DIRTY (STATUS[13]) clear condition: next GO? PROG-mode WR_CFG? firmware W1C? | Host-port designer |
| T4 | OBS_CTL[1] OBS_ARM semantics: one-shot auto-clear vs sticky; PULSE disarm-after-fire? | Observer designer |
| T5 | MRS/MSR to unallocated sregs 0x14–0x3F: raise CONFIG_ERR, or read-as-zero/write-ignored? | ISA lead |
| T6 | Illegal opcode (24–63): NOP? trap vector? CONFIG_ERR+halt? | ISA lead + PE designer |
| T7 | AND/OR/XOR fn=11: confirm hardware behavior (assembler already rejects) | PE designer |
| T8 | Confirm PDIR reset all-Hi-Z, PMASK 0xFF, PMODE 0x0000 vs pin-mux power-on intent | Pin-fabric designer |
| T9 | Formal bind TBD SVA signal names (`issue`, `eff_commit`, …) to RTL | Formal / PE designer |
| T10 | RET on empty return stack: unspecified in v0.1 (proposal P6) | ISA lead |
| T11 | CALL stack overflow sticky: v0.1 says "overflow sets sticky", names none (proposal P2: STATUS[6]=CALL_OVF) | ISA lead |
| T12 | ARCHITECTURE.md §2.2.2 pin-effect list names only PSET/PSETR — add PDIR/PMODE to match the instruction table (proposal P8, doc fix) | ISA lead (spec) |
| T13 | Q5 sequence triggers (A-then-B): cost/benefit | ISA worker |
| T14 | Q4 revisit gate: PE-side trace read reopens only per the strict condition in §6 | Firmware phase |
| T15 | Watermark async push (alternative to sticky-poll TRACE_WM) | ISA lead |
| T16 | HLT/GO wake accounting for GO during would-be delay cycles | ISA lead |
| **T17** | **WAIT elapsed overflow: 16-bit Rd vs 65536/1048576-cycle timeouts — modulo? saturation?** | **ISA lead (semantics decision — do not silently pick)** |

## 9. Reserved-opcode policy

Opcodes 24–27 are named **intent-only** reservations — CRC8, CRC16,
PATMATCH, MUL — with no v0.2 semantics: they name the most likely
stretch accelerators so firmware and tooling can plan. 28–63 are
explicitly unallocated.

A slot may be claimed **only** by an ISA revision proposal that (a)
names the opcode number, (b) specifies the `[20:0]` field layout
following this file's lane conventions, and (c) demonstrates the need
cannot be met in firmware at 50 MHz. Claiming a slot **requires ISA-owner
review and a passing CI regeneration** of the decode package, assembler,
golden model, and formal timing table (single-source discipline,
ARCHITECTURE.md §7.1) — and **forces a version bump to v0.3** (v0.2 is
reserved for the v0.1 errata/TBD resolutions documented here). Slots may
never be claimed for host-port, debug, or trace-reader functions that
bypass the PE/host-port arbitration rules (R4).

## 10. Version-bump policy

- **v0.2 stays v0.2** while resolutions fit the recorded encoding space
  (errata, TBD resolutions, merge decisions M1–M3).
- **v0.3 is forced by:** any claimed reserved opcode; any instruction
  semantics change (the proposals in Appendix A); any STATUS-bit
  assignment (T11/P2); any host-port command addition; or any timing-contract
  change adopted after resolution (T2/P1, T17).

## Appendix A. Proposals needing a SEMANTICS change — recorded, never adopted here

v0.2 changed no semantics. These were proposed during Phase 1 and are
parked for the ISA owner; adopting any one forces a v0.3 bump.

| # | Proposal | Why it's a semantics change |
|---|---|---|
| P1 | SLEEP cycle count: `1+d+imm13`, or rewording §2.2.1 to exempt SLEEP explicitly | v0.1 fixes SLEEP at exactly `1+imm13` *and* states every insn = 1+delay; with `d` reserved_zero these conflict formally |
| P2 | CALL/RET overflow sticky: STATUS[6]=CALL_OVF (W1C), set on return-stack push-to-full or pop-from-empty (alt: reuse CONFIG_ERR) | v0.1 says "overflow sets sticky" but defines no flag; STATUS[6] is held reserved for exactly this |
| P3 | WAIT delay field: nonzero `d` extends the timeout, or pre-delays before arming | v0.1 WAIT timing is `1..1+timeout` from the preset table only |
| P4 | HLT with delay: interpret `d` as "halt after d cycles" | v0.1 HLT halts immediately |
| P5 | PULL-on-empty returning nonzero, or PUSH-on-full stalling instead of dropping | Non-blocking FIFO semantics are a normative v0.1 contract point (determinism) |
| P6 | RET on empty return stack: trap to defined PC (e.g. 0) + CONFIG_ERR (not silent no-op) | v0.1 silent on RET-underflow; needs ruling before CALL/RET proofs (T10) |
| P7 | New STATUS sticky TRACE_OVERRUN for trigger-burst coalescing visibility (bursts faster than 1/5 cycles coalesce latest-wins invisibly today) | New observable flag; needs a bit assignment |
| P8 | ARCHITECTURE.md §2.2.2: name PDIR and PMODE in the pin-effect-point list (the instruction table already applies the rule) | Doc-level; touches normative contract text, so recorded here rather than silently adopted |
---

## Addendum (post-v0.2 — NOT part of the v0.2 text)

*Added 2026-10-28 as a pointer only; per §10 the v0.2 text above stays
clean (errata only) and is not edited by this addendum.*

The §3 `target9` (M3) reservation — `target9[8]` must-be-zero, "reserved
for a future IMEM-512 extension" (see also resolution R-7 in §7) — has
been **activated** by the ISA v0.3 note (`docs/isa_v0.3_note.md`),
merged into main (formerly branch `dev/imem-512`): IMEM depth is now 512
words and JMP/CALL/DJNZ targets are fully 9-bit. Readers who need the
current target/IMEM rules should read the v0.3 note alongside §3; all
other v0.2 semantics are unchanged.
