#!/usr/bin/env python3
"""Generate every SVG diagram for the tt_um_pemu README + docs site.

Sources (all numbers traceable, nothing invented):
  - Die/core/macro geometry: FINAL_STATS.md section 8 (IMEM-512 run
    40699493628) + dashboard manifest (GDS-measured macro bboxes).
  - Pin label anchors: docs/assets/layers.json `pins[]` (Metal4.text).
  - Logic-block regions: final DEF
    GDS_logs/runs/wokwi/final/def/tt_um_pemu.def, run 40699493628.
    Component names are flattened, so cells were attributed to a block
    by the hierarchy prefix of the nets they connect to (u_pe./u_obs./
    u_host.); cells on top-level-only nets (clock tree, ties, pin
    fabric glue) could not be attributed and are NOT drawn as a region.
    Solid box = 5-95 percentile concentration of attributed cells;
    dashed box = full min/max bbox. Placement interleaves blocks, so
    the boxes overlap -- that overlap is real, not a drawing error.
  - Timing numbers: repo docs/FIRMWARE.md + STRETCH_PROTOCOL_TESTS
    (golden-model measurements, cycle-exact).

Themes: every diagram is emitted twice from this single script -- a light
variant (diagram-*.svg) and a dark variant (diagram-*-dark.svg) -- with
identical geometry, numbers and wording. The docs site swaps variants when
the reader toggles the theme (nav.js). Palette contrast was checked
programmatically (WCAG ratios, computed from the hex values below):
light ink on paper 17.2:1, muted on paper 7.5:1, amber link 7.2:1,
teal 5.4:1; dark ink on ink 14.5:1, muted on ink 7.0:1, amber link
10.7:1, teal 9.6:1; wave-trace colors on their canvas backgrounds are
all >= 4.8:1 (traces are graphics, whose WCAG bar is 3:1; trace labels
are ink, not trace-colored).

Usage: python3 generate_diagrams.py [outdir]  (default: same dir)
"""
import json
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- themes
LIGHT = dict(
    bg="#fffdf9", bg2="#f5f0e8", ink="#1c1917", muted="#57534e",
    faint="#78716c", grid="#e7e0d4", stroke="#334155",
    blue="#2563eb", blue_bg="#dbeafe",
    green="#047857", green_bg="#d1fae5",
    amber="#b45309", amber_bg="#fef3c7",
    purple="#6d28d9", purple_bg="#ede9fe",
    gray_bg="#f1f5f9", red="#dc2626", highlight="#fef9c3",
    copper1="#f59e0b", copper2="#ea580c", field_op="0.18",
)
DARK = dict(
    bg="#0f172a", bg2="#16213a", ink="#e2e8f0", muted="#94a3b8",
    faint="#64748b", grid="#1e293b", stroke="#94a3b8",
    blue="#60a5fa", blue_bg="#172554",
    green="#34d399", green_bg="#052e2b",
    amber="#fbbf24", amber_bg="#451a03",
    purple="#a78bfa", purple_bg="#2e1065",
    gray_bg="#1e293b", red="#f87171", highlight="#451a03",
    copper1="#fbbf24", copper2="#f97316", field_op="0.30",
)
THEMES = {"light": LIGHT, "dark": DARK}
T = LIGHT
THEME = "light"


def set_theme(name):
    global T, THEME
    THEME, T = name, THEMES[name]


# ---------------------------------------------------------------- constants
DIE_W, DIE_H = 1289.28, 710.64
CORE = (2.88, 3.78, 1283.52, 703.08)  # x, y, w, h (um)
MACROS = {
    "u_imem": dict(cell="RM_IHPSG13_1P_512x32_c2_bm_bist", x=205.68, y=3.78,
                   w=416.64, h=191.57, note="512 x 32-bit instruction SRAM"),
    "u_tmem": dict(cell="RM_IHPSG13_1P_1024x8_c2_bm_bist", x=1127.36, y=3.78,
                   w=146.88, h=336.69, note="1024 x 8-bit trace SRAM (204 entries)"),
}
# DEF-derived placement regions (um). See module docstring for method.
# Colors are resolved per theme at draw time (blue/green/amber).
REGIONS = {
    "PE core (u_pe)": dict(n=1754,
        bbox=[12.48, 283.5, 782.88, 597.24],
        conc=[[92.16, 328.86], [661.92, 585.9]]),
    "Observer (u_obs)": dict(n=273,
        bbox=[659.04, 325.08, 1275.84, 476.28],
        conc=[[695.52, 347.76], [1260.96, 461.16]]),
    "Host port (u_host)": dict(n=2552,
        bbox=[4.8, 143.64, 1152.48, 540.54],
        conc=[[60.48, 181.44], [1057.92, 510.3]]),
}
REGION_COLORS = {"PE core (u_pe)": "blue", "Observer (u_obs)": "green",
                 "Host port (u_host)": "amber"}
# Pin label anchors, verbatim from layers.json pins[] (Metal4.text).
# Only the functional subset is text-labeled; every anchor gets a tick.
PINS = [
    ("VPWR", 9.03, 355.32), ("VGND", 14.65, 355.32),
    ("clk", 187.2, 710.14), ("ena", 191.04, 710.14), ("rst_n", 183.36, 710.14),
    ("ui_in[0]", 179.52, 710.14), ("ui_in[1]", 175.68, 710.14),
    ("ui_in[2]", 171.84, 710.14), ("ui_in[3]", 168.0, 710.14),
    ("ui_in[4]", 164.16, 710.14), ("ui_in[5]", 160.32, 710.14),
    ("ui_in[6]", 156.48, 710.14), ("ui_in[7]", 152.64, 710.14),
    ("uio_in[0]", 148.8, 710.14), ("uio_in[1]", 144.96, 710.14),
    ("uio_in[2]", 141.12, 710.14), ("uio_in[3]", 137.28, 710.14),
    ("uio_in[4]", 133.44, 710.14), ("uio_in[5]", 129.6, 710.14),
    ("uio_in[6]", 125.76, 710.14), ("uio_in[7]", 121.92, 710.14),
    ("uio_oe[0]", 56.64, 710.14), ("uio_oe[1]", 52.8, 710.14),
    ("uio_oe[2]", 48.96, 710.14), ("uio_oe[3]", 45.12, 710.14),
    ("uio_oe[4]", 41.28, 710.14), ("uio_oe[5]", 37.44, 710.14),
    ("uio_oe[6]", 33.6, 710.14), ("uio_oe[7]", 29.76, 710.14),
    ("uio_out[0]", 87.36, 710.14), ("uio_out[1]", 83.52, 710.14),
    ("uio_out[2]", 79.68, 710.14), ("uio_out[3]", 75.84, 710.14),
    ("uio_out[4]", 72.0, 710.14), ("uio_out[5]", 68.16, 710.14),
    ("uio_out[6]", 64.32, 710.14), ("uio_out[7]", 60.48, 710.14),
    ("uo_out[0]", 118.08, 710.14), ("uo_out[1]", 114.24, 710.14),
    ("uo_out[2]", 110.4, 710.14), ("uo_out[3]", 106.56, 710.14),
    ("uo_out[4]", 102.72, 710.14), ("uo_out[5]", 98.88, 710.14),
    ("uo_out[6]", 95.04, 710.14), ("uo_out[7]", 91.2, 710.14),
]


def svg_open(w, h, title):
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" font-family="DejaVu Sans, Arial, sans-serif" '
        f'role="img" aria-label="{title}">',
        f"<title>{title}</title>",
        "<defs>",
        f'<linearGradient id="gradCopper" x1="0" y1="0" x2="1" y2="0">'
        f'<stop offset="0%" stop-color="{T["copper1"]}"/>'
        f'<stop offset="100%" stop-color="{T["copper2"]}"/></linearGradient>',
        "</defs>",
        f'<rect width="100%" height="100%" fill="{T["bg"]}"/>',
    ]


def titlebar(p, cx, y=42):
    p.append(f'<rect x="{cx - 60}" y="{y}" width="120" height="4" rx="2" fill="url(#gradCopper)"/>')


def box(p, x, y, w, h, fill, stroke=None, r=8, sw=1.5):
    if stroke is None:
        stroke = T["stroke"]
    p.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" '
             f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')

def text(p, x, y, s, size=13, fill=None, anchor="middle", weight="normal",
         mono=False):
    if fill is None:
        fill = T["ink"]
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    fam = 'font-family="DejaVu Sans Mono, monospace"' if mono else ""
    p.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
             f'text-anchor="{anchor}" font-weight="{weight}" {fam}>{s}</text>')

def arrow(p, x1, y1, x2, y2, color=None, w=1.6, dashed=False):
    if color is None:
        color = T["stroke"]
    d = 'stroke-dasharray="5,4"' if dashed else ""
    p.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
             f'stroke-width="{w}" {d}/>')
    # simple arrowhead
    import math
    ang = math.atan2(y2 - y1, x2 - x1)
    for da in (2.6, -2.6):
        ax = x2 - 9 * math.cos(ang + da * 0.12)
        ay = y2 - 9 * math.sin(ang + da * 0.12)
        p.append(f'<line x1="{x2}" y1="{y2}" x2="{ax:.1f}" y2="{ay:.1f}" '
                 f'stroke="{color}" stroke-width="{w}"/>')

def wave_lane(p, x0, y, label, levels, step, high=26, color=None):
    """levels: list of 0/1 per step. Draws a step waveform + label."""
    if color is None:
        color = T["blue"]
    text(p, x0 - 8, y + high // 2 + 4, label, size=12, anchor="end", mono=True)
    pts = []
    x = x0
    prev = levels[0]
    pts.append(f"{x},{y + high - prev * high}")
    for lv in levels[1:]:
        x += step
        if lv != prev:
            pts.append(f"{x},{y + high - prev * high}")
            pts.append(f"{x},{y + high - lv * high}")
        prev = lv
    x += step
    pts.append(f"{x},{y + high - prev * high}")
    p.append(f'<polyline points="{" ".join(pts)}" fill="none" '
             f'stroke="{color}" stroke-width="2"/>')

def save(name, parts):
    if THEME == "dark":
        name = name.replace(".svg", "-dark.svg")
    parts.append("</svg>")
    with open(os.path.join(OUT, name), "w") as f:
        f.write("\n".join(parts) + "\n")
    print("wrote", name)

# ---------------------------------------------------------------- architecture
def architecture():
    p = svg_open(980, 560, "TEMPO system architecture")
    text(p, 490, 30, "TEMPO system architecture — one die, two independent engines",
         size=17, weight="bold")
    titlebar(p, 490)
    box(p, 60, 80, 300, 170, T["blue_bg"], T["blue"])
    text(p, 210, 106, "PE core — TEMPO-32 engine", size=14, weight="bold")
    text(p, 210, 130, "timed ISA · 16 x 16-bit GPRs", size=12)
    text(p, 210, 150, "WAIT returns elapsed cycles", size=12)
    text(p, 210, 170, "CAP snapshots {timestamp, pins}", size=12)
    text(p, 210, 190, "ALU · CALL/RET · 9-bit PC (v0.3)", size=12)
    text(p, 210, 216, "drives PIN0–PIN7 via pin fabric", size=12)
    box(p, 60, 290, 300, 150, T["green_bg"], T["green"])
    text(p, 210, 316, "Observer — trace engine", size=14, weight="bold")
    text(p, 210, 340, "watches the same 8 pins", size=12)
    text(p, 210, 360, "32-bit cycle timestamps", size=12)
    text(p, 210, 380, "EDGE / PATTERN / PULSE triggers", size=12)
    text(p, 210, 400, "204-entry trace SRAM — PE cannot read it", size=12)
    box(p, 620, 80, 300, 170, T["amber_bg"], T["amber"])
    text(p, 770, 106, "Host port", size=14, weight="bold")
    text(p, 770, 130, "2-wire framed serial · autobaud", size=12)
    text(p, 770, 150, "ui[0] = HP_RX · uo[0] = HP_TX", size=12)
    text(p, 770, 170, "LOAD / VERIFY / GO / RD_TRACE", size=12)
    text(p, 770, 190, "TX + RX FIFOs, 16 x 16-bit each", size=12)
    text(p, 770, 216, "RD_STATUS · HALT_REQ · WR_CFG", size=12)
    box(p, 620, 290, 300, 150, T["purple_bg"], T["purple"])
    text(p, 770, 316, "Pin fabric (top level)", size=14, weight="bold")
    text(p, 770, 340, "per-pin direction (PDIR)", size=12)
    text(p, 770, 360, "open-drain + pull-up (PMODE)", size=12)
    text(p, 770, 380, "2-FF input synchronizer", size=12)
    text(p, 770, 400, "uio[0..7] = PIN0–PIN7", size=12)
    box(p, 400, 130, 180, 70, T["gray_bg"])
    text(p, 490, 156, "u_imem", size=14, weight="bold", mono=True)
    text(p, 490, 176, "512 x 32-bit", size=12)
    box(p, 400, 320, 180, 70, T["gray_bg"])
    text(p, 490, 346, "u_tmem", size=14, weight="bold", mono=True)
    text(p, 490, 366, "1024 x 8-bit", size=12)
    arrow(p, 400, 165, 360, 165)                       # u_imem -> PE (instruction fetch)
    arrow(p, 360, 355, 400, 355, color=T["green"])     # Observer -> u_tmem (trace write)
    arrow(p, 620, 165, 580, 165, dashed=True)          # Host -> u_imem (LOAD_IMEM)
    text(p, 490, 480, "Structural invariant: the PE has no data path to the trace SRAM.",
         size=13, weight="bold")
    text(p, 490, 502, "The Observer can therefore characterize the bus — including the PE's own output.",
         size=12)
    text(p, 490, 530, "Firmware (not gates) decides the protocol: UART · SPI · I2C · 1-Wire · JTAG · SWD · PS/2 · CAN · USB LS.",
         size=12)
    save("diagram-architecture.svg", p)

# ---------------------------------------------------------------- ISA word
def isa_word():
    p = svg_open(980, 330, "TEMPO-32 instruction word format")
    text(p, 490, 30, "TEMPO-32 instruction word — 32 bits, timing inside the instruction",
         size=16, weight="bold")
    titlebar(p, 490)
    x0, y, W = 40, 70, 900
    fields = [("opcode", 6, T["blue"]), ("delay d", 5, T["green"]),
              ("operands / target / immediate", 21, T["amber"])]
    x = x0
    for name, bits, col in fields:
        w = W * bits / 32
        p.append(f'<rect x="{x}" y="{y}" width="{w}" height="64" fill="{col}" '
                 f'fill-opacity="{T["field_op"]}" stroke="{col}" stroke-width="2"/>')
        text(p, x + w / 2, y + 28, name, size=13, weight="bold")
        text(p, x + w / 2, y + 50, f"{bits} bits", size=12)
        x += w
    text(p, 40, 160, "[31:26]", size=12, mono=True, anchor="start")
    text(p, 250, 160, "[25:21]  0–31 cycles", size=12, mono=True, anchor="start")
    text(p, 560, 160, "[20:0]", size=12, mono=True, anchor="start")
    text(p, 490, 195, "Every instruction executes in 1 + d cycles. Pin effects and samples land on exact cycles.",
         size=13)
    text(p, 490, 220, "WAIT cfg, rd — wait for a pin condition; rd = cycles actually elapsed (timeout: TIMEOUT sticky).",
         size=13)
    text(p, 490, 245, "CAP rd — atomically snapshot {32-bit cycle counter, synchronized pins}.",
         size=13)
    text(p, 490, 270, "v0.3 (IMEM-512): JMP / CALL target9 = instr[20:12], DJNZ target9 = instr[16:8]; PC is 9 bits (0–511).",
         size=13)
    text(p, 490, 295, "WAIT timeouts as built: tsel 0 → 256 cycles, tsel 1 → 4096 cycles; tsel 2/3 fall back + CONFIG_ERR (see Limitations).",
         size=12)
    save("diagram-isa-word.svg", p)

# ---------------------------------------------------------------- timing contract
def timing_contract():
    p = svg_open(980, 420, "TEMPO timing contract")
    text(p, 490, 30, "Timing contract — the program is the timing diagram", size=16, weight="bold")
    titlebar(p, 490)
    x0 = 150
    # instruction slots: each insn 1+d cycles; draw cycle grid
    text(p, x0 - 8, 80, "cycles", size=12, anchor="end", mono=True)
    for i in range(17):
        xx = x0 + i * 48
        p.append(f'<line x1="{xx}" y1="64" x2="{xx}" y2="300" stroke="{T["grid"]}"/>')
        text(p, xx, 58, str(i), size=10, anchor="middle", fill=T["faint"], mono=True)
    wave_lane(p, x0, 90, "SCLK", [0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0], 48)
    wave_lane(p, x0, 140, "MOSI", [1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0], 48, color=T["green"])
    wave_lane(p, x0, 190, "MISO", [0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1], 48, color=T["amber"])
    p.append(f'<line x1="{x0 + 5 * 48}" y1="64" x2="{x0 + 5 * 48}" y2="300" '
             f'stroke="{T["red"]}" stroke-width="2" stroke-dasharray="6,4"/>')
    text(p, x0 + 5 * 48, 320, "PGET sample point\n(mid-bit, +2-cycle sync accounted)", size=12,
         fill=T["red"], anchor="middle")
    text(p, 490, 360, "Rules: pin effect of an instruction lands on its own cycle grid; PGET reads the 2-FF-synchronized pins;",
         size=13)
    text(p, 490, 385, "WAIT exits on the condition cycle (elapsed = timeout counts as satisfied, no TIMEOUT) or on timeout (TIMEOUT set);",
         size=13)
    text(p, 490, 405, "SLEEP is exactly 1 + imm13 cycles; HLT gates PE clocks (Observer and timestamp keep running).",
         size=13)
    save("diagram-timing-contract.svg", p)

# ---------------------------------------------------------------- pin map
def pinmap():
    p = svg_open(980, 420, "TEMPO 24-pin functional map")
    text(p, 490, 30, "Functional pins — Tiny Tapeout 24-pin interface (ui + uo + uio)", size=16, weight="bold")
    titlebar(p, 490)
    # three banks
    for i, (bank, role, col) in enumerate([("ui[0..7]", "inputs", T["blue"]),
                                           ("uo[0..7]", "outputs", T["green"]),
                                           ("uio[0..7]", "bidirectional protocol pins", T["amber"])]):
        y = 70 + i * 100
        text(p, 60, y + 34, bank, size=14, weight="bold", mono=True, anchor="start")
        text(p, 60, y + 56, role, size=12, anchor="start")
        for b in range(8):
            x = 300 + b * 78
            fn = ""
            if bank.startswith("ui") and b == 0: fn = "HP_RX"
            if bank.startswith("uo") and b == 0: fn = "HP_TX"
            if bank.startswith("uio"): fn = f"PIN{b}"
            fill = T["bg"]
            if fn: fill = T["highlight"]
            box(p, x, y, 66, 62, fill, col)
            text(p, x + 33, y + 26, f"{bank[:2]}[{b}]", size=12, mono=True)
            text(p, x + 33, y + 48, fn if fn else "—", size=11, mono=True)
    text(p, 490, 385, "Control: clk (50 MHz nominal) · rst_n (known state) · ena (PROG vs RUN) · VPWR / VGND.",
         size=13)
    text(p, 490, 405, "GDS pin-label anchors (all 45 Metal4.text labels) are drawn at true positions in the labeled top view.",
         size=12)
    save("diagram-pinmap.svg", p)

# ---------------------------------------------------------------- die / tiles
def die_tiles():
    W, H = 980, 640
    p = svg_open(W, H, "TEMPO die and 6x4 tile fit")
    text(p, 490, 30, "Die 1289.28 x 710.64 um — exactly the 6 x 4 tile allotment (0 um^2 overflow)",
         size=16, weight="bold")
    titlebar(p, 490)
    ox, oy, sc = 60, 70, 0.62
    dw, dh = DIE_W * sc, DIE_H * sc
    # tiles
    tw, th = dw / 6, dh / 4
    for r in range(4):
        for c in range(6):
            x, y = ox + c * tw, oy + r * th
            p.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{tw:.1f}" height="{th:.1f}" '
                     f'fill="{T["bg2"]}" stroke="{T["grid"]}"/>')
            text(p, x + tw / 2, y + th / 2 + 4, f"{c+1},{4-r}", size=10, fill=T["faint"])
    # core outline
    cx, cy = ox + CORE[0] * sc, oy + (DIE_H - CORE[1] - CORE[3]) * sc
    p.append(f'<rect x="{cx:.1f}" y="{cy:.1f}" width="{CORE[2]*sc:.1f}" height="{CORE[3]*sc:.1f}" '
             f'fill="none" stroke="{T["blue"]}" stroke-width="2" stroke-dasharray="8,5"/>')
    text(p, cx + 8, cy + 18, "core 1283.52 x 703.08 um", size=12, fill=T["blue"])
    # macros (y up -> svg y down)
    for name, m in MACROS.items():
        mx = ox + m["x"] * sc
        my = oy + (DIE_H - m["y"] - m["h"]) * sc
        box(p, mx, my, m["w"] * sc, m["h"] * sc, T["amber_bg"], T["amber"], r=2)
        text(p, mx + m["w"] * sc / 2, my + m["h"] * sc / 2 - 2, name, size=13, weight="bold", mono=True)
        text(p, mx + m["w"] * sc / 2, my + m["h"] * sc / 2 + 16,
             f'{m["w"]:.2f} x {m["h"]:.2f} um', size=10)
    text(p, 490, oy + dh + 28, "Per-tile unit: 214.88 x 177.66 um. Both SRAMs sit on the bottom edge, pins facing into the die (FS).",
         size=13)
    text(p, 490, oy + dh + 50, "u_imem spans tile columns 1–3, row 1; u_tmem spans column 6, rows 1–2. Nothing protrudes past the core.",
         size=13)
    save("diagram-die-tiles.svg", p)

# ---------------------------------------------------------------- waveforms
def waveform(name, title, lanes, notes, step=34):
    p = svg_open(980, 300, title)
    text(p, 490, 30, title, size=16, weight="bold")
    titlebar(p, 490)
    x0 = 130
    y = 70
    for label, levels, col in lanes:
        wave_lane(p, x0, y, label, levels, step, color=col)
        y += 52
    for i, n in enumerate(notes):
        text(p, 490, y + 24 + i * 22, n, size=12, fill=T["muted"])
    save(name, p)

def waveforms():
    waveform("wave-spi.svg", "SPI master, mode 0 — 50 cycles/bit, 408 cycles/byte (schematic)",
             [("CS#", [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1], T["red"]),
              ("SCLK", [0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0], T["blue"]),
              ("MOSI", [0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0], T["green"]),
              ("MISO", [0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0], T["amber"])],
             ["SCLK period 50 cycles x14, zero deviation; byte-boundary period 58 cycles; duty 25/25.",
              "Loopback demo: MOSI 0xA5 -> MISO 0x5A, 0x3C -> 0xC3. CS# brackets SCLK. N=0: 3-cycle pulse, no SCLK."])
    waveform("wave-uart.svg", "UART 115200 8N1 — 434 cycles/bit (schematic)",
             [("TX", [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1], T["blue"]),
              ("RX", [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1], T["green"])],
             ["TX bit cell 434 cycles exact; byte pitch 4349 cycles x3, zero deviation.",
              "RX first-sample offset +1 cycle from ideal mid-bit (CAP-calibrated); back-to-back margin +/-216 cycles.",
              "Break (>= 8192 low cycles, two chained tsel=1 waits) -> EVT2 + 0xFFFE."])
    waveform("wave-i2c.svg", "I2C master 100 kHz — nominal 500 cycles/bit, measured 499 (schematic)",
             [("SCL", [1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1], T["blue"]),
              ("SDA", [1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1], T["green"])],
             ["73 data clocks at exactly 499 cycles (= 100.2 kHz); high 248 / low 251 cycles.",
              "Clock stretch 2000 cycles tolerated (WAIT 2001 < 4096 timeout, no abort).",
              "NACK-on-address -> 0xFFE0 + STOP + EVT1. Spec gates pass on all 92 highs / 90 lows."])
    waveform("wave-usb.svg", "USB low-speed token + DATA0 — 33/34-cycle dither, NRZI (schematic)",
             [("D+ ", [0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0], T["blue"]),
              ("D- ", [1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1], T["green"]),
              ("SE0", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], T["amber"])],
             ["Bit cells dither 33,33,34 cycles (average exactly 33.333); max edge deviation from ideal grid 1 cycle (20 ns).",
              "SETUP token (ADDR 5, ENDP 0, CRC5 residue 01100) + DATA0 (CRC16 residue checked by an independent decoder).",
              "EOP = SE0 for 66 cycles. J (idle) = D+=0, D-=1; K = D+=1, D-=0; NRZI: 0 = transition, 1 = hold."])

# ---------------------------------------------------------------- labeled top view
def labeled():
    sc = 0.92
    ml, mt = 130, 215          # margins for labels (pin brackets live above the die)
    W = int(ml + DIE_W * sc + 60)
    H = int(mt + DIE_H * sc + 90)
    p = svg_open(W, H, "TEMPO labeled GDS top view, IMEM-512 layout")

    def X(x): return ml + x * sc
    def Y(y): return mt + (DIE_H - y) * sc  # y up -> svg down

    text(p, W / 2, 28, "TEMPO (tt_um_pemu) — labeled top view, IMEM-512 layout (run 40699493628)",
         size=17, weight="bold")
    text(p, W / 2, 52, "Die + core + SRAM macros at true GDS positions; pin ticks at true Metal4.text label anchors;",
         size=12)
    text(p, W / 2, 70, "logic-block outlines are placement regions from the final DEF (see note below) — approximate, overlapping by design.",
         size=12)
    titlebar(p, W / 2, y=80)
    # die + core
    p.append(f'<rect x="{X(0):.1f}" y="{Y(DIE_H):.1f}" width="{DIE_W*sc:.1f}" height="{DIE_H*sc:.1f}" '
             f'fill="{T["bg2"]}" stroke="{T["ink"]}" stroke-width="2.5"/>')
    text(p, X(0) + 8, Y(DIE_H) + 18, "die 1289.28 x 710.64 um", size=12, weight="bold", anchor="start")
    p.append(f'<rect x="{X(CORE[0]):.1f}" y="{Y(CORE[1]+CORE[3]):.1f}" width="{CORE[2]*sc:.1f}" height="{CORE[3]*sc:.1f}" '
             f'fill="none" stroke="{T["blue"]}" stroke-width="1.5" stroke-dasharray="8,5"/>')
    text(p, X(CORE[0]) + 8, Y(CORE[1] + CORE[3]) + 34, "core 1283.52 x 703.08 um", size=11, fill=T["blue"], anchor="start")
    # tile grid (light)
    for c in range(1, 6):
        xx = X(c * DIE_W / 6)
        p.append(f'<line x1="{xx:.1f}" y1="{Y(DIE_H):.1f}" x2="{xx:.1f}" y2="{Y(0):.1f}" stroke="{T["grid"]}"/>')
    for r in range(1, 4):
        yy = Y(r * DIE_H / 4)
        p.append(f'<line x1="{X(0):.1f}" y1="{yy:.1f}" x2="{X(DIE_W):.1f}" y2="{yy:.1f}" stroke="{T["grid"]}"/>')
    # DEF regions: dashed full bbox + solid concentration box
    for name, reg in REGIONS.items():
        col = T[REGION_COLORS[name]]
        x0, y0, x1, y1 = reg["bbox"]
        p.append(f'<rect x="{X(x0):.1f}" y="{Y(y1):.1f}" width="{(x1-x0)*sc:.1f}" height="{(y1-y0)*sc:.1f}" '
                 f'fill="none" stroke="{col}" stroke-width="1.5" stroke-dasharray="6,4"/>')
        (cx0, cy0), (cx1, cy1) = reg["conc"]
        p.append(f'<rect x="{X(cx0):.1f}" y="{Y(cy1):.1f}" width="{(cx1-cx0)*sc:.1f}" height="{(cy1-cy0)*sc:.1f}" '
                 f'fill="{col}" fill-opacity="0.08" stroke="{col}" stroke-width="2"/>')
    # region labels
    text(p, X(92.16), Y(585.9) - 8, "PE core (u_pe) — 1,754 cells", size=12, weight="bold", fill=T["blue"], anchor="start")
    text(p, X(695.52), Y(461.16) - 8, "Observer (u_obs) — 273 cells", size=12, weight="bold", fill=T["green"], anchor="start")
    text(p, X(60.48), Y(510.3) - 8, "Host port (u_host) — 2,552 cells", size=12, weight="bold", fill=T["amber"], anchor="start")
    # macros (short lines: the u_tmem box is only ~135 px wide)
    macro_lines = {
        "u_imem": ["RM_IHPSG13_1P_512x32", "c2_bm_bist",
                   "416.64 x 191.57 um", "@ (205.68, 3.78) FS",
                   "512 x 32-bit instruction SRAM"],
        "u_tmem": ["RM_IHPSG13_1P_1024x8", "c2_bm_bist",
                   "146.88 x 336.69 um", "@ (1127.36, 3.78) FS",
                   "1024 x 8-bit trace SRAM", "(204 entries)"],
    }
    for name, m in MACROS.items():
        box(p, X(m["x"]), Y(m["y"] + m["h"]), m["w"] * sc, m["h"] * sc, T["amber_bg"], T["amber"], r=2, sw=2)
        text(p, X(m["x"] + m["w"] / 2), Y(m["y"] + m["h"]) + 22, name, size=14, weight="bold", mono=True)
        for i, ln in enumerate(macro_lines[name]):
            text(p, X(m["x"] + m["w"] / 2), Y(m["y"] + m["h"]) + 40 + i * 15, ln, size=9, mono=True)
    # pin ticks at true anchors
    for name, x, y in PINS:
        if y > 700:  # top edge: tick upward
            p.append(f'<line x1="{X(x):.1f}" y1="{Y(y):.1f}" x2="{X(x):.1f}" y2="{Y(y)-14:.1f}" stroke="{T["red"]}" stroke-width="2"/>')
        else:        # left edge: tick leftward
            p.append(f'<line x1="{X(x):.1f}" y1="{Y(y):.1f}" x2="{X(x)-14:.1f}" y2="{Y(y):.1f}" stroke="{T["red"]}" stroke-width="2"/>')
    # bracket labels for pin groups (anchors are 3.84 um apart -- individual labels would collide)
    text(p, X(29.76), Y(DIE_H) - 18, "uio_oe[0..7] (3 views of the same 8 uio pins: in / out / oe)", size=11, fill=T["red"], anchor="start")
    text(p, X(60.48), Y(DIE_H) - 36, "uio_out[0..7]", size=11, fill=T["red"], anchor="start")
    text(p, X(91.2), Y(DIE_H) - 54, "uo_out[0..7] — uo[0] = HP_TX", size=11, fill=T["red"], anchor="start")
    text(p, X(121.92), Y(DIE_H) - 72, "uio_in[0..7] = PIN0–PIN7", size=11, fill=T["red"], anchor="start")
    text(p, X(152.64), Y(DIE_H) - 90, "ui_in[0..7] — ui[0] = HP_RX · clk · rst_n · ena", size=11, fill=T["red"], anchor="start")
    text(p, X(14.65) - 20, Y(355.32), "VPWR / VGND", size=11, fill=T["red"], anchor="end")
    # legend + honesty note
    ly = Y(0) + 26
    text(p, X(0), ly, "Legend: solid = 5–95 percentile concentration of DEF-attributed cells · dashed = full min/max bbox · gold = SRAM macro (true GDS rect)",
         size=11, anchor="start")
    text(p, X(0), ly + 20, "Method note: final-DEF component names are flattened, so cells were attributed by the hierarchy prefix of the nets they connect to",
         size=11, anchor="start")
    text(p, X(0), ly + 38, "(u_pe. / u_obs. / u_host.). 12,022 non-fill cells sit on top-level-only nets (clock tree, ties, pin-fabric glue) and have no region.",
         size=11, anchor="start")
    text(p, X(0), ly + 56, "Placement interleaves blocks, so regions overlap — the overlap is real. Pin ticks: all 45 Metal4.text anchors from layers.json.",
         size=11, anchor="start")
    save("labeled-top-view.svg", p)
    # sidecar: machine-readable region data for the site (written once).
    # Region colors are the original light-theme values, so the sidecar
    # schema is unchanged (colors now live in the theme palettes above).
    if THEME == "light":
        sidecar_regions = {name: {"n": reg["n"],
            "color": LIGHT[{"PE core (u_pe)": "blue",
                "Observer (u_obs)": "green", "Host port (u_host)": "amber"}[name]],
            "bbox": reg["bbox"], "conc": reg["conc"]}
            for name, reg in REGIONS.items()}
        with open(os.path.join(OUT, "def_regions.json"), "w") as f:
            json.dump({"die": [DIE_W, DIE_H], "core": list(CORE), "macros": MACROS,
                       "regions": sidecar_regions,
                       "unattributed_nonfill_cells": 12022,
                       "method": "Final DEF (run 40699493628) components are flattened; "
                                 "cells attributed by hierarchy prefix of connected nets "
                                 "(u_pe./u_obs./u_host.). Solid = 5-95 percentile box, "
                                 "dashed = full bbox. Top-level-only cells have no region."},
                      f, indent=1)
        print("wrote def_regions.json")


if __name__ == "__main__":
    for theme in ("light", "dark"):
        set_theme(theme)
        architecture()
        isa_word()
        timing_contract()
        pinmap()
        die_tiles()
        waveforms()
        labeled()
