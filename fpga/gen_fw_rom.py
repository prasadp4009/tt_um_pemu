#!/usr/bin/env python3
"""gen_fw_rom.py -- swap the loader case-ROM firmware image per protocol.

Usage: python3 fpga/gen_fw_rom.py {spi,uart,i2c,onewire,usb_full,ubproof,usb_full301}

Reads test/cosim/hex/<proto>.hex (one 32-bit word per line), regenerates the
img_word() case function in fpga/emu_tt_loader.v, updates IMG_WORDS, then
re-extracts the case entries from the file and verifies byte-for-byte against
the hex source. Exits nonzero on any mismatch.
"""
import re, sys

PROTO = sys.argv[1]
assert PROTO in ("spi", "uart", "i2c", "onewire", "usb_full", "ubproof", "usb_full301"), PROTO

REPO = "/home/jarvis/asic/projects/js-pemu"
hexpath = f"{REPO}/test/cosim/hex/{PROTO}.hex"
rtlpath = f"{REPO}/fpga/emu_tt_loader.v"

words = []
for ln in open(hexpath):
    ln = ln.strip()
    if not ln:
        continue
    assert re.fullmatch(r"[0-9a-fA-F]{8}", ln), f"bad hex line: {ln!r}"
    words.append(ln.lower())
n = len(words)
print(f"{PROTO}: {n} words from {hexpath}")

# build the new function text (9-bit index: supports up to 512 words)
flines = []
flines.append("    function [31:0] img_word(input [8:0] w);")
flines.append("        case (w)")
for i, w in enumerate(words):
    flines.append(f"            9'd{i} : img_word = 32'h{w};")
flines.append("            default: img_word = 32'h00000000;")
flines.append("        endcase")
flines.append("    endfunction")
new_func = "\n".join(flines)

s = open(rtlpath).read()

# replace existing img_word function (from its 'function' line to matching 'endfunction')
m = re.search(r"    function \[31:0\] img_word\(input \[(?:7|8):0\] w\);\n(.*?)\n    endfunction",
              s, re.S)
assert m, "img_word function not found"
s = s[:m.start()] + new_func + s[m.end():]

# update IMG_WORDS
m2 = re.search(r"localparam \[(?:7|8):0\] IMG_WORDS = (?:8|9)'d\d+;", s)
assert m2, "IMG_WORDS not found"
s = s[:m2.start()] + f"localparam [8:0] IMG_WORDS = 9'd{n};" + s[m2.end():]

open(rtlpath, "w").write(s)

# ---- byte-for-byte verification: re-extract and compare ----
s = open(rtlpath).read()
got = re.findall(r"9'd(\d+) : img_word = 32'h([0-9a-f]{8});", s)
assert len(got) == n, f"extracted {len(got)} entries, expected {n}"
for (idx, val), exp in zip(got, words):
    assert int(idx) == got.index((idx, val)), "index order broken"
    assert val == exp, f"word {idx}: got {val}, want {exp}"
# check indices are exactly 0..n-1 in order
idxs = [int(i) for i, _ in got]
assert idxs == list(range(n)), "index sequence broken"
# check IMG_WORDS value
m3 = re.search(r"localparam \[8:0\] IMG_WORDS = 9'd(\d+);", s)
assert m3 and int(m3.group(1)) == n, "IMG_WORDS mismatch"
print(f"VERIFY OK: {n}/{n} words byte-identical, IMG_WORDS=9'd{n}")
