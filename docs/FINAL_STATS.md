# tt_um_pemu (TEMPO) — Final Hardening Stats

**Source of truth:** GitHub Actions run **40575084383** on HEAD **76451e0** (branch `cmos5l` → `main`, repo prasadp4009/tt_um_pemu, PRIVATE).
gds job ✅ SUCCESS (20:06:41Z → 20:45:03Z, **38 min 22 s**). precheck ✅ SUCCESS (first ever). test ✅, docs ✅.
Artifacts preserved in a local run archive, not committed to this repo (`gds_artifacts_40575084383/` with `GDS_logs/`, `tt_submission/`, `precheck_reports/`, `gds_render/`).
Final GDS from the local run archive, not committed to this repo (15,828,650 bytes). Flow: LibreLane 3.1.0.dev3, PDK `ihp-sg13cmos5l` (IHP-Open-PDK @ 2bbec755).

Every number below is cross-checked across at least two of: `final/metrics.json`, the step logs in the run artifacts, `info.yaml`, and the checker reports. Disagreements are flagged inline under **Reconciliation notes**.

---

## 1. Die, shape, and tile fit

| Item | Value | Source |
|---|---|---|
| Die bbox | (0.00, 0.00) → (1289.28, 710.64) µm | metrics `design__die__bbox` + GDS top-cell bbox (identical) |
| Die dimensions | **1289.28 × 710.64 µm** (aspect 1.814 : 1, landscape) | computed |
| Die area | **916,214 µm²** (0.916 mm²) | metrics `design__die__area` = 916214; KLayout DRC log: "Total area of the design is 916213.9391999999 um^2" ✓ |
| Core bbox | (2.88, 3.78) → (1286.40, 706.86) µm | metrics `design__core__bbox` |
| Core dimensions / area | 1283.52 × 703.08 µm / **902,417 µm²** | metrics `design__core__area` |

**Tile fit vs info.yaml `tiles: "6x4"`:**

- Per-tile unit (die ÷ grid): **214.88 µm wide × 177.66 µm tall**; per-tile area 38,175.6 µm².
- 6 × 4 = 24 tiles × 38,175.6 µm² = **916,214 µm² = the die, exactly.** The hardened die *is* the full 6×4 allotment — it fits the declared tile count with **0 µm² of overflow** and no partial tile: width divides by 6 and height by 4 with no remainder.
- Shape alignment: both SRAM macros sit on the die's bottom edge inside the core; the TMEM tower (336.46 µm tall) spans tile rows 1–2 of column 6 without crossing the die boundary; nothing protrudes past the core bbox on any side.
- ⚠ **Reconciliation note:** the comment inside `info.yaml` says "A single tile is about 167x108 uM." That is leftover sky130-era template boilerplate text in the file's comment, **not** the IHP cmos5l tile size. The governing numbers are the flow's die bbox above (1289.28 × 710.64), which is the standard TT-IHP 6×4 footprint. The `tiles: "6x4"` value itself is correct.

## 2. Utilization and instances

| Item | Value |
|---|---|
| Instance utilization (all instances incl. macros, of core) | **37.9 %** (`design__instance__utilization` = 0.379034) |
| Stdcell utilization (of core) | **30.3 %** (0.302596) |
| Total instances | **68,684** — of which 52,105 are fill cells |
| Placed stdcells (non-fill) | **16,577** |
| Macros | **2** |
| Total instance area | 895,262 µm² (incl. fill 553,216 µm²) |

Instance / area breakdown (metrics, by class):

| Class | Count | Area (µm²) |
|---|---:|---:|
| Sequential cells | 1,771 | 86,759.2 |
| Multi-input combinational | 10,001 | 95,753.1 |
| Inverters | 511 | 2,781.5 |
| Clock buffers / inverters | 188 / 69 | 4,434.4 / 484.4 |
| Timing-repair buffers | 4,009 | 52,771.8 |
| Antenna cells | 27 (13 antenna diodes inserted per `antenna_diodes_count`) | 147.0 |
| Plain buffers | 1 | 7.3 |
| **Stdcell subtotal** | **16,577** | **243,139** |
| **SRAM macros** | **2** | **98,907.7** |
| Fill cells | 52,105 | 553,216 |

Routed wirelength 654,638 µm; 99,101 vias (all single-cut). Total power (typ corner): **6.80 mW** (internal 5.61 mW + switching 1.15 mW + leakage 0.036 mW).

## 3. SRAM macros

| Instance | Cell | Size (W × H, µm) | Area (µm²) | Position (lower-left, µm) | Orientation | Occupies |
|---|---|---:|---:|---|---|---|
| `u_imem` | RM_IHPSG13_1P_256x32_c2_bm_bist | 416.64 × 118.78 | 49,488.5 | (205.68, 3.78) | **FS** | x 205.68–622.32, y 3.78–122.56 (bottom edge, tile cols 1–3, row 1) |
| `u_tmem` | RM_IHPSG13_1P_1024x8_c2_bm_bist | 146.88 × 336.46 | 49,419.2 | (1127.36, 3.78) | **FS** | x 1127.36–1274.24, y 3.78–340.24 (bottom-right corner, tile col 6, rows 1–2) |

Macro areas sum to 49,488.5 + 49,419.2 = **98,907.7 µm²**, matching metrics `design__instance__area__macros` exactly. Cell sizes are the PDK LEF dimensions (GDS cell bboxes agree: 416.64 × 119.01 and 146.88 × 336.69 including a 0.225 µm LEF overhang). Both macros are placed on the proven PDN phase (x = 3.36 + k·11.24 µm family); pins face into the die (FS) — the fix that took GRT overflow from 3,375 to 0.

## 4. Pins vs the 24-pin Tiny Tapeout interface

Top module `tt_um_pemu` physical ports (from final/vh + info.yaml pinout):

- Inputs: `clk`, `rst_n`, `ena`, `ui_in[7:0]`, `uio_in[7:0]` — 19 pins
- Outputs: `uo_out[7:0]`, `uio_out[7:0]`, `uio_oe[7:0]` — 24 pins
- **User digital interface: ui 8 + uo 8 + uio 8 = 24 pins — exactly the TT 24-pin interface, no analog pins.**

Assigned functions (info.yaml): `ui[0]` = HP_RX (host port in), `uo[0]` = HP_TX (host port out), `uio[0..7]` = PIN0–PIN7 (protocol pins). Remaining ui/uo bits are unassigned in the pinout (blank), as the template permits.

## 5. Timing by corner (post-PnR STA, step 58, 20 ns / 50 MHz constraint)

| Corner | Setup WNS (ns) | Setup TNS (ns) | Setup violators | Hold WNS (ns) | Worst hold slack (ns) | Max-slew viol. | Max-cap viol. |
|---|---:|---:|---:|---:|---:|---:|---:|
| nom_fast 1.32 V, −40 °C | 0 (clean) | 0 | 0 | 0 | +0.104 | 0 | 12 |
| nom_typ 1.20 V, 25 °C | 0 (clean) | 0 | 0 | 0 | +0.289 | 32 | 12 |
| nom_slow 1.08 V, 125 °C | **−2.933** | **−171.68** | **131** | 0 | +0.609 | 587 | 12 |

Positive worst setup slack where clean: typ **+5.339 ns**, fast **+8.681 ns** — 50 MHz is met with margin at typical and fast corners. Hold is clean at **all** corners.

**The honest slow-corner item:** all **131** setup violators at nom_slow share a single source pin — `u_imem/A_DOUT[18]` (one IMEM read-data bit fanning out across the PE; the fetch path). Worst slack −2.933 ns against the 20 ns constraint implies a slow-corner fmax ≈ **43.6 MHz**. These are checker *warnings* in this flow, not flow errors; the competition imposes no clock target (designer-chosen 50 MHz in info.yaml). One net ⇒ tractable later (fanout buffering/replication or fetch pipelining) if ever pursued.

⚠ **Reconciliation note:** the previous run (Step 3, 40520569898) reported slow WNS −2.880 ns / TNS −164.90 / 129 violators, typ +5.37 ns. This run's numbers (−2.933 / −171.68 / 131, typ +5.339) differ slightly because placement and routing changed with Steps 3.5+4. Same single source net. **This run's numbers supersede.**

## 6. Sign-off verdicts (quoted from this run's artifacts)

**LVS (netgen, step 69/70) — PASS.**
From `69-netgen-lvs/reports/lvs.netgen.rpt`:
> "Netlists match with 3 symmetries."
> "Final result: Circuits match uniquely."

Metrics agree: `design__lvs_error__count` = 0; unmatched pins / nets / devices = 0; device & net differences = 0. (Last run's 10-error LVS failure — the VPWR↔VGND stripe bridge — is gone; the clearance guard worked.)

**KLayout DRC (cmos5l deck, step 65/66) — PASS, 0 errors.**
Step log, verbatim:
> "%OL_METRIC_I klayout__drc_error__count 0"

Precheck's independent KLayout SG13CMOS5L DRC also ✅ (see §7).

**Magic DRC — not run (by config).** `RUN_MAGIC_DRC: false` in the resolved config (unchanged since the SRAM-wiring step; restori
...[truncated 4436 chars]
## 8. IMEM-512 expansion run — dev/imem-512 @ aaa486a (run 40699493628, 2026-10-28)

The sections above describe the proven 256-word run (40575084383, main @ e99ff28, tagged
`v1.0-proven-256`). This section is the IMEM-512 expansion: identical flow, identical die,
u_imem swapped to RM_IHPSG13_1P_512x32 at the same placement/orientation. Artifacts on
local run archive `gds_artifacts_40699493628_imem512/` (not committed to this repo). CI verdicts:
gds ✅, precheck ✅ 9/9, gl_test ✅, test ✅, docs ✅, viewer ❌ (GitHub Pages toggle — known).

| Field | IMEM-512 (aaa486a) | 256-word baseline | Delta |
|---|---|---|---|
| Die size | 1289.28 × 710.64 µm, 916,214 µm² | 1289.28 × 710.64 µm, 916,214 µm² | IDENTICAL — exactly 6×4 tiles |
| Core | 1283.52 × 703.08 µm / 902,417 µm² | same | identical |
| Instance utilization | 41.4 % (0.413732) | 37.9 % | +3.5 pts |
| Stdcell utilization | 31.6 % (0.315824) | 30.3 % | +1.3 pts |
| Placed stdcells | 16,635 | 16,577 | +58 |
| Total instances (incl. fill) | 66,154 (fill 49,517) | 68,684 (fill 52,105) | −2,530 |
| Macros (total) | 2, 129,139 µm² | 2, 98,907.7 µm² | +30,231 µm² (exactly the predicted delta) |
| u_imem | RM_IHPSG13_1P_512x32_c2_bm_bist, 416.64 × 191.34 µm (79,719.8 µm²), (205.68, 3.78) FS, spans y 3.78–195.12 | RM_IHPSG13_1P_256x32…, 416.64 × 118.78 µm (49,488.5 µm²), (205.68, 3.78) FS | same width/placement/orientation; +72.56 µm height only |
| u_tmem | RM_IHPSG13_1P_1024x8_c2_bm_bist, 146.88 × 336.46 µm, (1127.36, 3.78) FS | same | unchanged |
| Power (typ) | 6.56 mW (int 5.50 + sw 1.02 + leak 0.034) | 6.80 mW | −0.24 mW |
| Routed wirelength | 668,354 µm (99,138 vias) | 654,638 µm (99,101 vias) | +13,716 µm (+2.1 %) |
| Setup WS typ / fast | +5.713 ns / +8.578 ns | +5.339 / +8.681 ns | typ +0.37 ns; fast −0.10 ns |
| Slow setup WNS / TNS | −2.824 ns / −157.48 ns | −2.933 / −171.68 ns | improved on both |
| Slow violators | 112 | 131 | −19 |
| Violator source | 110/112 from u_imem/A_DOUT[17] (109 reg-reg + 1 reg-out); 2 reg-out from u_imem/A_DOUT[18] | all 131 from u_imem/A_DOUT[18] | source net moved [18]→[17]; same fetch-path single-bit class; implied slow-corner fmax ≈43.8 MHz (was ≈43.6) |
| Hold | clean all corners (worst slack fast +0.062 / typ +0.264 / slow +0.616 ns) | clean all corners (+0.104/+0.289/+0.609) | still clean; fast-corner margin thinner |
| LVS | "Circuits match uniquely" (5 symmetries), all error counts 0 | "Circuits match uniquely" (3 symmetries) | PASS both |
| KLayout DRC | 0 errors (flow) + precheck DRC ✅ | 0 | unchanged |
| Antenna | 0 violating nets/pins (20 diodes inserted) | 0 (13 diodes) | unchanged verdict |
| Worst IR drop | 0.128 mV (≈0.011 % of 1.2 V) | 0.205 mV (≈0.02 %) | improved |
| Max slew violations (slow/typ/fast) | 779 / 31 / 0 | 587 / 32 / 0 | slow-corner count worse — checker warnings, not flow errors |
| Max cap violations | 4 (all corners) | 12 | improved |
| Route DRC final | 0 | 0 | unchanged |
