# Tiny Tapeout synthesis — TEMPO (`tt_um_pemu`), IHP SG13G2

Real Tiny Tapeout / LibreLane synthesis run of the **frozen** TEMPO RTL.
This is the actual TT flow (LibreLane Classic, IHP PDK), not the older
hand-rolled Yosys scripts in `test/synth/` (`tempo_synth.ys` etc.).

## Verdict

**Synthesis passes cleanly through the real TT flow.** 11,964 instances,
184,656.74 µm² of standard-cell logic, 0 unmapped cells, 0 inferred latches,
0 check errors, 0 lint errors, 2 pre-existing lint warnings (RTL frozen —
not touched). The only blackboxes are the two intended SRAM macros.

**Not proven by this run:** physical fit in the 6×4 TT boundary, PNR,
timing signoff (no STA in the synthesis step), GDS. SRAM macros have no
LEF/GDS wired into the flow yet — macro integration is a later hardening
concern.

## How to reproduce

Host: starklabs. All tool paths below are on starklabs.

```bash
export PATH=/home/jarvis/asic/tools/oss-cad-suite/bin:$PATH
export PYTHONPATH=/home/jarvis/asic/tools/ll_shim          # tkinter shim, see below
export PDK_ROOT=/home/jarvis/asic/pdk/ciel/ihp-sg13g2/versions/c4b8b4e5e7a05f375cca3815d51b3a37721fbf5c
export _LLN_OVERRIDE_YOSYS=/home/jarvis/asic/tools/yosys-py/bin/yosys   # python-enabled yosys, see below
cd /home/jarvis/asic/projects/js-pemu   # branch cmos5l @ 0ca8496
/home/jarvis/asic/tools/librelane-venv/bin/librelane \
  --manual-pdk --pdk-root "$PDK_ROOT" \
  -p ihp-sg13g2 -f classic \
  -T Yosys.Synthesis \
  --design-dir /home/jarvis/asic/projects/js-pemu \
  --run-tag tt_synth_0ca8496 \
  -c 'DESIGN_NAME=tt_um_pemu' \
  -c 'VERILOG_FILES=src/tt_um_pemu.v,src/tt_um_pemu_pe.v,src/tt_um_pemu_observer.v,src/tt_um_pemu_host.v' \
  -c 'EXTRA_VERILOG_MODELS=test/sram_bb.v' \
  --hide-progress-bar \
  src/config.json
```

Notes:
- `src/config.json` is the repo's TT config (CLOCK_PERIOD 20 ns / 50 MHz,
  PL_TARGET_DENSITY_PCT 60, CTS on). It is passed unchanged.
- CLI `-c` list values are comma-separated strings (LibreLane permissive
  typing), not JSON arrays.
- RTL is frozen: `src/` last touched by `942a318`; nothing in `src/` was
  modified for this run.

## Environment (built 2026-09-27, persistent on starklabs)

| Component | Version / path |
|---|---|
| LibreLane | 3.0.14 (`/home/jarvis/asic/tools/librelane-venv`) — matches tt-gds-action default |
| PDK | ihp-sg13g2 @ `c4b8b4e5e7a05f375cca3815d51b3a37721fbf5c` (LibreLane-compatible Ciel revision) |
| Yosys | 0.69+154, git `30d62572e`, **built from source with Python support** (`/home/jarvis/asic/tools/yosys-py`) |
| bison/flex for the yosys build | 3.8.2 / 2.6.4 (`/home/jarvis/asic/tools/yosys-deps`) |
| pybind11/cxxheaderparser (yosys pyosys gen) | scratch venv `/home/jarvis/asic/tools/pyosys-env` |
| tkinter shim | `/home/jarvis/asic/tools/ll_shim/tkinter.py`, exposed via `PYTHONPATH` |

Two environment gaps had to be closed (no RTL or repo changes involved):
1. **tkinter**: LibreLane evaluates the PDK's `config.tcl` through
   `tkinter.Tcl()`, but Python 3.14 on starklabs has no `_tkinter` module.
   The shim backs `tkinter.Tcl()` with `/usr/bin/tclsh`, capturing
   `set`/`dict` calls exactly as LibreLane's own logic expects. Verified
   against the real PDK `config.tcl` (72 vars resolved, nested `dict set`
   vars parsed correctly).
2. **Python-enabled Yosys**: the oss-cad-suite Yosys 0.69 binary was built
   without Python support, but every LibreLane Classic synthesis step runs
   `yosys -y <pyosys script>`. Built Yosys from source at the **same commit**
   (`30d62572e`) as the oss-cad-suite binary, with `YOSYS_WITH_PYTHON=ON`,
   and pointed LibreLane at it via `_LLN_OVERRIDE_YOSYS`. Same version,
   same commit — only the Python integration differs.

## Results (run tag `tt_synth_0ca8496`, 2026-09-27)

From `final/metrics.csv` and `06-yosys-synthesis/reports/stat.rpt`:

| Metric | Value |
|---|---|
| Total instances | **11,964** |
| Standard cells | 11,962 |
| Blackboxes | 2 — `RM_IHPSG13_1P_1024x8_c2_bm_bist` ×1, `RM_IHPSG13_1P_256x32_c2_bm_bist` ×1 |
| Unmapped cells | **0** |
| Logic area (stdcells) | **184,656.74 µm²** |
| Sequential area | 86,661.19 µm² (46.93%) |
| Flip-flops (`sg13g2_dfrbpq_1`) | 1,769 |
| Inferred latches | 0 (`latch.rpt`: "No latch inferred") |
| Pre-synth check problems | 0 across `tt_um_pemu`, `tt_um_pemu_pe`, `tt_um_pemu_observer`, `tt_um_pemu_host` |
| Post-synth check problems | 0 |
| Lint errors / timing-construct lints | 0 / 0 |
| Lint warnings | 2 (see below) |
| Synthesis runtime | ~10.5 s |

Top cell types by count: `sg13g2_dfrbpq_1` 1769, `sg13g2_tiehi` 1642,
`sg13g2_o21ai_1` 1495, `sg13g2_a21oi_1` 1431, `sg13g2_nor2_1` 959,
`sg13g2_nand2_1` 881, `sg13g2_mux2_1` 563, `sg13g2_inv_1` 533.
Full breakdown in `stat.rpt` / `stat.json`.

SRAM macro area is reported as "unknown" in `stat.rpt` — expected: the
macros are blackboxes at synthesis (Verilog models only, no Liberty/LEF
area). Their physical footprint must be added from the PDK macro views
during hardening.

## Warnings (pre-existing, RTL frozen — not changed)

1. `%Warning-UNUSEDSIGNAL`: `src/tt_um_pemu_host.v:423` — signal `vnwords`
   is not used.
2. `%Warning-SYNCASYNCNET`: `src/tt_um_pemu.v:58` — `rst_n` flopped as both
   synchronous and async.

Both are Verilator lint warnings; the flow completes with EXIT=0.
`error.log` is empty.

## Timing

The `Yosys.Synthesis` step performs no STA — timing signoff happens in
later flow stages (CTS/routing), which were not run. Context:
- Constraint in `src/config.json`: `CLOCK_PERIOD: 20` ns (50 MHz).
- ABC's internal pre-layout delay estimate during mapping: ~8.95 ns on the
  largest partition (`wireload = none`, optimistic, not a signoff number).
- OpenSTA is not installed in this environment, so no pre-PNR slack /
  critical-endpoint report was produced. This is an open measurement, not
  a failure — the synthesis step itself has no timing check to fail.

## PDK-specific observations

- PDK config resolves cleanly through the real `libs.tech/librelane/config.tcl`
  (72 vars), including `SYNTH_EXCLUDED_CELL_FILE` (`synth_exclude.cells`).
- No PDK errors, no missing Liberty/Verilog views for the standard cells used.
- The two SRAM cells match real PDK macro views under
  `libs.ref/sg13g2_sram` (`.lib`, Verilog, LEF, GDS, CDL all present in the
  PDK) — but only the Verilog blackbox models (`test/sram_bb.v`) were fed
  to synthesis. LEF/GDS macro integration is deferred to hardening.

## Files in this directory

- `README.md` — this report
- `flow_run.log` — full LibreLane run log (config load → lint → synthesis)
- `stat.rpt` / `stat.json` — Yosys post-mapping statistics
- `latch.rpt`, `pre_synth_chk.rpt`, `chk.rpt` — check reports
- `metrics.csv` — flow metrics (canonical numbers above)

Large build products (`runs/`, netlists) are intentionally not committed.
