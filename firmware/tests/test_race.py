"""Tarang firmware inter-word race regression test.

BUG (found 2026-09-27 by the Tiny Tapeout template test): the serial host
delivers 16-bit command-frame words ~2000 core cycles apart, but the
firmware pulled multi-word frames back-to-back (~5 cycles apart). A PULL on
an empty RX FIFO returns 0 and sets RX_UNDERRUN, so frame words were lost
(e.g. SPI's byte-count became 0) and later words were misinterpreted as
unrelated commands.

FIX: every dependent frame-word PULL is now preceded by an RXNE wait loop
(`jmp have, rxne` / `jmp wait`), so the PE spins until the host word
arrives instead of consuming a phantom zero.

This test delivers multi-word frames with realistic 2000-cycle gaps and
requires:
  1. the PE halts cleanly on 0x00FF,
  2. RX_UNDERRUN is never set (the direct race detector),
  3. the TX FIFO holds exactly the protocol-correct response words.

It FAILS on pre-fix firmware (phantom zeros -> RX_UNDERRUN + corrupted
responses) and PASSES on fixed firmware.

Usage:
  python3 tests/test_race.py [--hexdir DIR]
Default: assembles the current sources. --hexdir lets the same test run
against saved pre-fix images to prove it guards the bug.
"""
import os
import sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
FW = "/home/hatch/workspace/janestreet-pemu/firmware"
sys.path.insert(0, TOOLS)
from sim import Sim
import tb

GAP = 2000  # realistic serial-host inter-word gap, core cycles

RX_UNDERRUN = 1 << 2


def assemble(name):
    src_path = os.path.join(FW, name, name + ".asm")
    with open(src_path) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, _, _ = tb.assemble_src(name, src, workdir)
    return img


def load_hexdir(hexdir, name):
    words = []
    with open(os.path.join(hexdir, name + ".hex")) as f:
        for line in f:
            line = line.strip()
            if line:
                words.append(int(line, 16))
    return words


def run_gapped(sim, words, gap=GAP):
    """Push one frame word every `gap` cycles, then run to halt."""
    for w in words[:-1]:
        if sim.halted:
            break
        sim.host_push_rx_words([w])
        sim.run(max_cycles=gap)
    if not sim.halted:
        sim.host_push_rx_words([words[-1]])
        sim.run(max_cycles=2_000_000)
    return sim


def check(name, sim, expect_tx, frame_desc):
    errs = []
    if not sim.halted:
        errs.append("PE did not halt on 0x00FF")
    if sim.sticky & RX_UNDERRUN:
        errs.append(f"RX_UNDERRUN sticky set (sticky={sim.sticky:#x}): "
                    "frame word pulled from empty FIFO -> THE RACE")
    if list(sim.tx_fifo) != list(expect_tx):
        errs.append(f"TX FIFO {list(sim.tx_fifo)} != expected {list(expect_tx)} "
                    f"for {frame_desc}")
    return errs


def main():
    hexdir = None
    if "--hexdir" in sys.argv:
        hexdir = sys.argv[sys.argv.index("--hexdir") + 1]

    def image(name):
        return load_hexdir(hexdir, name) if hexdir else assemble(name)

    results = {}

    # ---- SPI: TRANSFER N=2 with 2 data bytes, MISO=0 ----
    sim = Sim(image("spi"))
    run_gapped(sim, [0x0001, 2, 0xA5, 0x3C, 0x00FF])
    # correct outcome: rx bytes (MISO=0) then status 0x0000
    results["spi"] = check("spi", sim, [0x0000, 0x0000, 0x0000], "TRANSFER 2")

    # ---- UART: TX demo N=2 ----
    sim = Sim(image("uart"))
    run_gapped(sim, [0x0001, 2, 0x41, 0x42, 0x00FF])
    results["uart"] = check("uart", sim, [0x0000], "TX 2")

    # ---- I2C: WRITE probe to NACK address 0xA2 (7-bit 0x51, no slave) ----
    # Correct outcome: address NACK -> 0xFFE0, EVT 1. Proves addr+N arrived
    # intact; a phantom-zero addr would "succeed" as 0x0000 instead.
    sim = Sim(image("i2c"))
    run_gapped(sim, [0x0001, 0xA2, 0, 0x00FF])
    results["i2c"] = check("i2c", sim, [0xFFE0], "WRITE probe NACK")

    # ---- 1-Wire: WRITE byte 0xA5 ----
    sim = Sim(image("onewire"))
    run_gapped(sim, [0x0002, 0xA5, 0x00FF])
    results["onewire"] = check("onewire", sim, [0x0000], "WRITE 0xA5")

    ok_all = True
    for name, errs in results.items():
        status = "PASS" if not errs else "FAIL"
        print(f"[{status}] {name}")
        for e in errs:
            print(f"    - {e}")
            ok_all = False
    print("RACE TEST: %s" % ("PASS - no inter-word race" if ok_all
                             else "FAIL - inter-word race present"))
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
