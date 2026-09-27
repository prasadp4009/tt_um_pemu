#!/usr/bin/env python3
"""Assemble Worker D bench programs -> test/hex/*.hex (checked in).

Run from the repo root:  python3 test/gen_bench_hex.py
Uses firmware/tools/asm.py (YAML-driven, never hand-encoded).
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASM = os.path.join(ROOT, "test", "asm")
HEX = os.path.join(ROOT, "test", "hex")
ASM_PY = os.environ.get("TEMPO_ASM_PY", "")
YAML = os.environ.get("TEMPO_ISA_YAML", "")
if not ASM_PY or not YAML or not os.path.isfile(ASM_PY) or not os.path.isfile(YAML):
    sys.exit(
        "gen_bench_hex.py: set TEMPO_ASM_PY and TEMPO_ISA_YAML to the specs-repo\n"
        "paths (e.g. ~/workspace/janestreet-pemu/firmware/tools/asm.py and\n"
        " ~/workspace/janestreet-pemu/isa_v0.2.yaml); the .hex files in\n"
        " test/hex/ are checked in and only need regeneration when the ISA changes."
    )

os.makedirs(HEX, exist_ok=True)
ok = True
for fn in sorted(os.listdir(ASM)):
    if not fn.endswith(".asm"):
        continue
    src = os.path.join(ASM, fn)
    dst = os.path.join(HEX, fn[:-4] + ".hex")
    lst = os.path.join(HEX, fn[:-4] + ".lst")
    r = subprocess.run(
        [sys.executable, ASM_PY, src, "-o", dst, "--listing", lst,
         "--yaml", YAML],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(f"FAIL {fn}:\n{r.stderr}")
        ok = False
    else:
        n = sum(1 for _ in open(dst))
        print(f"assembled {fn} -> {os.path.basename(dst)} ({n} words)")
sys.exit(0 if ok else 1)
