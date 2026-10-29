# IMEM Expansion Analysis — can Tarang grow to fit USB TX+RX in one image?

**Date:** 2026-10-27 · **Scope:** feasibility + impact analysis only. No RTL changed, nothing committed or pushed.
**Question (Prasad):** "Make sure we are able to incorporate additional words so we support USB as well."
**Baseline:** repo HEAD `e99ff28` (full TT flow green), IMEM = 1× `RM_IHPSG13_1P_256x32_c2_bm_bist`.

## Headline

**Yes — and the ISA was designed for exactly this.** ISA v0.2 pre-reserved the extension:
`target9[8]` in JMP/CALL/DJNZ is a must-be-zero bit *"held for a future IMEM-512 extension"*
(merge decision M3, resolution R-7; ARCHITECTURE.md open question Q1). The encodings already
carry 9-bit targets, the host loader's wire address is already 16-bit, and the PDK contains a
pin-compatible 512×32 macro whose signal-pin row is **bit-identical** to the current macro's.
No hard encoding or protocol limit exists anywhere in the chain. The swap costs **+30,231 µm²
(3.3% of the die, 0.79 tile)** and a mechanical, fully enumerated change set. **Recommendation:
Option A — swap u_imem to `RM_IHPSG13_1P_512x32_c2_bm_bist` at the same placement.**

Side answers: the CAN DLC≤2 cap is **structural (register file, not words) — 512 does not lift
it** (§5). A firmware-only device-role USB image in 256 words is possible only as a reduced
product with unproven rework (§4).

---

## 1. Macro options (sg13cmos5l_sram PDK library)

`src/config.json` addresses macros as `pdk_dir::libs.ref/sg13cmos5l_sram/…`, and
`sg13cmos5l_sram` is a symlink to the SG13G2 SRAM directory (PUSH_PREP_AUDIT §wiring), so the
SG13G2 library on starklabs *is* the CI library. Its 256×32 LEF SIZE (416.64 × 118.78)
matches the green run's macro exactly, confirming identity. **All views (gds, lef, lib ×3
corners, cdl, verilog) verified on disk for the 512×32 1P macro.**

| Option | Macro | LEF size (W×H, µm) | Area (µm²) | Δ vs current | % of die (916,214 µm²) | Address pins |
|---|---|---|---|---|---|---|
| Current | RM_IHPSG13_1P_256x32_c2_bm_bist | 416.64 × 118.78 | 49,488.5 | — | 5.40% | A_ADDR[7:0] |
| **A: 512×32 swap** | **RM_IHPSG13_1P_512x32_c2_bm_bist** | **416.64 × 191.34** | **79,720** | **+30,231 (+61.1%)** | **8.70%** | A_ADDR[8:0] |
| B: second bank | +1× RM_IHPSG13_1P_256x32 (total) | 2× (416.64 × 118.78) | 98,977 | +49,489 | 10.80% | A_ADDR[7:0] ×2 + bank select |
| (priced, rejected) | RM_IHPSG13_1P_1024x32_c2_bm_bist | 416.64 × 336.46 | 140,183 | +90,695 | 15.30% | A_ADDR[9:0] |

Notes:
- The whole ×32 family shares the 416.64 µm width; depth grows purely as height. ARCHITECTURE.md
  Q1 estimated 512×32 at "+~1 tile" in September — measured delta is 0.79 tile. Estimate held up.
- 1024×32 exists and fits geometrically, but nothing needs it: the largest merged image
  contemplated is 291 words (§4). Rejected as area spent for no consumer.
- Precedent: Pettit's design in this same competition/flow hardens **two** RM 512×32 macros
  (BEST_PRACTICES_AND_PLAN_2026-10-26.md survey) — the macro is proven in the cmos5l flow.

## 2. Floorplan fit

**Option A placement sketch: change nothing but the cell.** `u_imem` stays at
**(205.68, 3.78), orientation FS** — the proven PDN phase (x = 3.36 + 18 × 11.24 µm) with the
same width, so the macro's Metal4 power columns land on exactly the same x positions and the
Step-3 ExtendPowerStripes / MouthKeepouts machinery (keyed on instance + `RM_` prefix) applies
unchanged in kind. Occupied y extends 3.78–122.56 → **3.78–195.12** (+72.56 µm upward, into
empty core; core top is 706.86). `u_tmem` at (1127.36, 3.78) is not touched; the inter-macro
channel (505.04 µm) is unchanged; halos (6.0 H / 2.0 V) unchanged. Instance utilization rises
37.9% → ≈41.2%; stdcell utilization (30.3%) is unaffected.

**Why routing risk is low — LEF-measured pin identity.** Comparing the two LEFs pin by pin:
**187 of 189 pins sit at bit-identical coordinates**, including every signal pin on the
bottom-edge row (all signal pins are at y=0 in both macros — the geometry whose mishandling
caused the October routing saga). A_DOUT[18] — the net behind all 131 slow-corner warnings —
is at the identical coordinate (259.64, 0). The only deltas: **+A_ADDR[8]** (bottom edge,
x 222.37–222.63, plus its BIST twin), and the VSS!/VDDARRAY! power shapes, which necessarily
differ because the array is taller (the plugin bridges power *columns*, whose x positions are
unchanged). What changes for the router: one additional bottom-edge escape (addr bit 8), and
+72.56 µm of OBS height over the same 416.64 µm width in a die that is ~62% empty. That is a
normal re-convergence profile, not a saga profile — stated as low risk, not zero risk.

**Option B geometry (for contrast):** bank 1 at (677.76, 3.78) FS keeps the proven 55.44 µm
channel to bank 0, but its right edge (1094.40) leaves only a **32.96 µm channel to u_tmem** —
below the 55.44 µm channel the PDN-0178 fix established, and u_tmem cannot move right (12.16 µm
slack to the core edge). Shifting bank 0 left instead re-opens the exact narrow-channel question
that forced the 160.72 → 205.68 move in iteration 2. The stacked variant (bank 1 flipped above
bank 0, Pettit's pattern) works but reintroduces facing pin rows + keepout re-tuning. B also
doubles the PDN surface (12 macro power pins to feed instead of 6) and needs bank decode +
DOUT muxing in RTL. Strictly worse than A on area, PDN risk, and floorplan risk.

## 3. ISA / RTL blast radius for 512 words

**The encoding has room — by design.** JMP and CALL encode `target9` at instr[20:12]; DJNZ at
instr[16:8]. All three lanes are already 9 bits wide in `isa_v0.2.yaml`; v0.2 froze bit 8 to
zero *explicitly* as the IMEM-512 reserve (M3/R-7). **No instruction format changes, no opcode
claimed, no hard limit found in any layer.** Governance: activating the reserved bit should be
issued as an ISA v0.3 note (v0.2 §10 keeps v0.2 clean for errata only) — a documentation act by
the ISA lead, not a redesign.

Itemized change set (every item located in the current sources):

| # | File | Change |
|---|---|---|
| 1 | `src/tt_um_pemu_pe.v` | `pc` [7:0]→[8:0] (l.174); `pc_plus1`; `next_pc_addr` — JMP/CALL target `instr[19:12]`→`instr[20:12]`, DJNZ `instr[15:8]`→`instr[16:8]` (l.327–331); `retstack[0:3]` entries [7:0]→[8:0] (l.192) + reset literals; `prog_addr`/`imem_addr` ports [7:0]→[8:0] (l.73/80, assign l.875). ~15 lines, one module. |
| 2 | `src/tt_um_pemu.v` | `imem_addr` wire [7:0]→[8:0] (l.79); u_imem cell name → 512×32 (l.300); header comment. A_ADDR port widens with the cell. |
| 3 | `src/tt_um_pemu_host.v` | `prog_addr` [7:0]→[8:0]; LOAD_IMEM validation (l.634–641): `addr_hi != 0 \|\| span > 256` → full 16-bit base with span ≤ 512; `addr8`→9-bit base reg; `prog_addr_r` [8:0]; VERIFY_IMEM mirrored range check (l.808+). **Wire format unchanged** — the address was always 2 bytes; LEN byte already caps a frame at 63 words, so the host already loads in multiple frames (≈5 frames for 256 words → ≈9 for 512). `nwords`/`widx` stay 8-bit. |
| 4 | `test/sram_bb.v` | New blackbox module for the 512×32 (name + [8:0] A_ADDR/A_BIST_ADDR). |
| 5 | `test/sram_sim.v` | New sim model, same pattern (512-deep array, [8:0] addr). |
| 6 | `src/config.json` | MACROS entry: swap cell name + view paths (all views exist, §1); `PDN_MACRO_CONNECTIONS` unchanged (same instance name, same power pin names); placement/orientation unchanged. |
| 7 | `firmware/tools/asm.py` | Five spots: target operand cap 255→511 (l.227); M3 rejection (l.201–202) → allow ≤511; `.org` cap (l.261); image-size limit 256→512 (l.283–284); headroom print (l.347). The YAML field lanes need **no** change. |
| 8 | `firmware/tools/sim.py` (golden model) | IMEM pad 256→512 (l.64); PC range check (l.340); `& 0xFF` → `& 0x1FF` masks (pc+1, targets, retstack push — l.414/481/492/503/524); VCD pc width cosmetic. |
| 9 | `firmware/tools/record_cosim.py` + `test/cosim/` | **The one non-one-line item.** The COS1 trace stores PC as a **u8 per record** and final_pc as u8 in the header. PCs above 255 need a format revision (COS2) and re-recording of all 10 protocol traces. Bounded and mechanical, but it touches every existing co-sim evidence trace. |
| 10 | `test/formal/gen.py` | Harness `h_pc` wire [7:0]→[8:0] (l.31). The T1–T17 property schemas are latency/pin/sample contracts — address-width-agnostic; prefetch properties (`imem_addr==pc`) hold structurally. Re-run 32/32; add upper-bank branch covers as new evidence. |
| 11 | Benches (599) | Concentrated in `tb_host.v` (139 checks): the deliberate `addr_hi != 0 → NACK_ERR` expectations (LOAD §6, VERIFY ~l.312) **invert** — addr_hi=1 becomes legal up to 511, and the span boundary moves 256→512; ~4–6 expectations edited + new positive upper-bank checks. `tb_pe.v` (357): all programs ≤256 words at base 0, unaffected except new checks worth adding (branch/CALL/DJNZ into 256–511). `tb_observer.v` (35) and `tb_top.v` (68): no imem-depth coupling found. Everything re-runs regardless. |
| 12 | `fpga/` (only when a >256-word image goes to Zybo) | `sram_emu.v` twin of #5; `gen_fw_rom.py` loader-ROM index 8→9 bit (its l.30 comment states the 256 limit); `emu_tt_loader.v` image depth. Not on the ASIC-submission path. |
| 13 | Docs | ISA_v0.2.md §3 target9 note + R-7 (bit flips reserved→implemented, issued as v0.3 note); ARCHITECTURE.md Q1 closed. info.yaml: no change (still 6x4 tiles; no imem field). |

**Timing caveat, honestly:** the fetch path is already the design's one soft spot — all 131
slow-corner violators (≈43.6 MHz implied fmax) come from `u_imem/A_DOUT[18]`. The 512×32 puts
that pin at identical coordinates, but the taller array's .lib read timing may be marginally
slower, so expect the same warning class, possibly slightly worse WNS. These are warnings, not
flow errors, and the competition imposes no clock target — but the swap will not improve the
one number that is already negative.

## 4. Firmware accounting — USB at 512, and the 256-word fallback

Section attribution from the assembler's own label map (exact, not estimated):

- **USB TX, 243 words** = init + cmd dispatch **28** (words 0–27) + payload staging **133**
  (28–160: the pb0–pb7 unrolled PULL paths + load/next byte sequencing for N≤8) + shared bit
  engine & EOP **82** (161–242: the cycle-counted 33/34-dither bit loop with in-loop NRZI,
  stuffing, and reflected CRC5/CRC16).
- **USB RX, 63 words standalone** = ~15 words of init/dispatch idioms shared with the product
  image + **48 unique** (WAIT edge sync + the path-balanced PGET sample-at-center loop,
  words 18–62).
- **Merged host-role image: 243 + 63 − 15 = 291 words** (the stretch report's accounting).
  At 512 that fits with **221 words spare (43% headroom)** — room that matters, because raw
  packet TX+RX is not yet a USB *device*: SETUP decode, enumeration state, and control-transfer
  logic still have to be written, and now have somewhere to live. (RX remains golden-model-proven
  only; hardware still needs the V-USB-style breakout and a real host — unchanged by this change.)

**Option C — device-role image inside 256 words (no RTL change), honestly assessed:**
A USB device never sends tokens, so the token-generation staging is droppable — but the
accounting is tighter than it first looks:

- *Handshake-only device* (RX + ACK/NAK/STALL): dispatch 28 + RX 48 + engine subset
  (SYNC/PID/EOP only — no CRC field, no payload staging) ≈ 55–65 → **≈135–145 words. Fits** —
  but it cannot answer an IN token with data. A control-pipe skeleton, not a device.
- *Full device* (RX + handshake + data responses): 28 + 48 + engine 82 + handshake ≈15 +
  data staging. With the **proven** unrolled staging (133): **≈306 — over.** With a lean
  pull-per-byte staging (~45–60 words; plausible because the LS inter-byte gap is ~266 cycles,
  so the unrolled paths are a luxury, not a necessity): **≈218–233 — fits**, with ~25–35 words
  to spare. But that staging is a redesign that exists nowhere today, and the result is
  device-only forever.
- Verdict: C is a product cut purchased with unproven firmware rework. A dominates it — A keeps
  the host role, uses every already-proven word as-is, and leaves 221 spare.

## 5. CAN side-effect — does 512 lift the DLC≤2 cap?

**No. The cap is structural, not a word-count limit** — stated precisely, from `can.asm`'s own
header (the stretch summary's "did not fit the remaining words" is the symptom; this is the
cause): all 16 GPRs are fully allocated; the data stream (≤16 bits at DLC≤2) must survive the
SOF..DLC fields intact in **one register** while the ID shifter, DLC shifter, and arbitration
flag are also live. DLC 3–8 means up to 64 data bits = up to 4 stream registers that do not
exist. The only spill homes are 8-bit observer sregs, and a 16-bit stream cannot be reloaded
from 8-bit sregs inside the 10-cycle inter-bit gap. **512 words adds zero registers, so the cap
stays at DLC≤2.** Lifting it requires a data-path redesign (e.g., streaming data bytes out of
the RX FIFO during the data field — the current firmware pre-stages all arguments before SOF
precisely so frame timing never waits on the host), which is independent of IMEM depth and
currently unproven. What 512 *does* give CAN is image headroom (255/256 → 255/512) — comfort,
not capability.

## 6. Cost of the change

- **RTL/tools edits:** ~1 day. Every item in §3 is mechanical and pre-located; the only design
  judgment is the host range-check rewrite, and it is small.
- **USB merge (the actual feature):** integrating the proven RX loop into the product image +
  golden test + co-sim — the item the stretch campaign already scoped; days, not weeks.
- **Re-verification:** full bench re-run (599 checks; ~4–6 host expectations edited, new
  upper-bank checks added), formal re-run (32 properties + harness width), all golden firmware
  tests re-run under the relaxed assembler, co-sim format bump + re-record of 10 traces.
  Nothing is waived — the whole evidence stack re-executes against the widened machine.
- **Re-hardening:** config-only delta (macro swap, placement untouched) + full CI. The green
  flow takes ~38–55 min per converging run; budget 1–3 iterations from campaign experience.
  gl_test re-runs against the new macro's PDK Verilog model (exists, §1); precheck is
  macro-agnostic. Residual risks, stated plainly: routing re-convergence (mitigated by the
  bit-identical pin row, §2 — low, not zero) and the pre-existing slow-corner fetch warning
  (§3 — expected to persist, possibly marginally worse; warnings only).
- **Schedule:** 82 days remain to the 2027-01-18 deadline. Total effort ≈ 3–5 working days
  including the USB merge; wall-clock risk sits in hardening iterations, not in the edits.
  **Schedule risk: low.**

## 7. Option comparison and recommendation

| Option | What it is | Area | Fits USB TX+RX (291 w)? | Risk | Effort |
|---|---|---|---|---|---|
| **A** | Swap u_imem → 512×32 macro, same placement | 79,720 µm² (8.70% die) | ✅ 221 words spare | Low — identical pin row, PDN phase, placement; macro proven in-flow (Pettit ×2) | §3 change set + §6 |
| B | Second banked 256×32 | 98,977 µm² (10.80%) | ✅ | Medium — 32.96 µm tmem channel *or* facing-pin-row stack; double PDN surface; bank decode/mux RTL | ≥ A, plus floorplan iteration risk |
| C | Firmware-only device-role image in 256 | 0 | ⚠️ Reduced form only (~218–233 w, unproven staging redesign; no host role) | Medium — product cut + unproven rework | Firmware-only, but buys less than A |
| D | Page/bank register on the existing 256×32 | 0 | ❌ **Not viable as stated** | — | — |

**Option D, addressed directly:** a bank register banks *physical* storage, and the existing
macro physically holds 256 words — there is nothing behind the register to select. The nearest
real variant (two host-loaded images swapped via PROG-mode reload) breaks USB itself: a reload
holds the PE in reset (~10K host clocks for 1 KB) and destroys protocol state, while a USB
device must answer within the transaction that asked. Rejected on mechanism, not on taste.

**Recommendation: Option A.** It is the path the ISA itself reserved (M3/R-7, ARCHITECTURE Q1),
the macro is pin-identical where it matters and already hardened twice over in this exact flow
by a fellow entrant, the change set is ~15 lines of RTL plus mechanical tool widenings, and it
converts USB from "TX proven, RX stranded" into a single 291-word image with 43% headroom for
the enumeration logic a real device still needs. It does not fix CAN's DLC cap (nothing about
words can) and it does not improve the slow-corner fetch warning — both stated so the decision
is made with them on the table.

*Evidence base: ISA_v0.2.md (§3, M3/R-7, §10), isa_v0.2.yaml field lanes, ARCHITECTURE.md Q1,
STRETCH_PROTOCOL_TESTS_2026-10-27.md + stretch_results/{usb,can}.md, FINAL_STATS.md (die/util/
STA), PUSH_PREP_AUDIT_2026-10-26.md (PDN phase, symlink, channel history), src/config.json,
src/tt_um_pemu{,_pe,_host}.v, test/{sram_bb,sram_sim}.v, test/tb_host.v, test/formal/gen.py,
test/COVERAGE.md (599-check inventory), firmware/tools/{asm,sim,record_cosim}.py (label maps
produced by the project assembler itself), fpga/gen_fw_rom.py, and LEF measurements taken
directly from the PDK library on starklabs (sg13g2_sram @ ciel c4b8b4e, the cmos5l symlink
target).*
