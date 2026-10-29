"""COS1 golden-trace recorder for the SWD stretch scenario.

Mirrors tools/record_cosim.py (same header/record format, reuses its
dump_record so the trace is COS1 byte-identical in format), except the
SWD target peer model is ACTIVE during recording: the target drives
SWDIO during the ACK/data/parity phases, and those physical pin values
are what dump_record captures in pins_phys -- so the recorded trace
replays identically into the RTL co-sim.

Scenario: init_rx = [0x0001, 0x00FF] (run one IDCODE read, then HLT --
the firmware halts at scenario end, as record() requires).

Usage: python3 tests/record_swd.py <hex> <out.bin>
"""
import struct
import sys, os

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
TESTS = "/home/hatch/workspace/janestreet-pemu/firmware/tests"
sys.path.insert(0, TOOLS)
sys.path.insert(0, TESTS)
from sim import Sim
from record_cosim import dump_record, REC_SIZE
import test_swd

INIT_RX = [0x0001, 0x00FF]


def record_swd(hex_words, init_rx, max_cycles=5_000_000):
    """record_cosim.record() replicated with the SWD peer active."""
    sim = Sim(list(hex_words))
    sim.rx_fifo = list(init_rx)
    sim.peer_drv = {}
    target = test_swd.SWDTarget()
    test_swd._target = target
    sim.pins_peer = test_swd.peer

    records = []
    orig_tick = sim._tick_delay

    def hooked():
        orig_tick()
        records.append(dump_record(sim))

    sim._tick_delay = hooked

    n = 0
    while not sim.halted and n < max_cycles:
        c = sim.step()
        n += c
    if not sim.halted:
        raise RuntimeError(f"golden did not halt after {n} cycles")
    if target.state != "done":
        raise RuntimeError(f"SWD target ended in state {target.state}, want done")

    hdr = bytearray(47)
    hdr[0:4] = b"COS1"
    struct.pack_into("<I", hdr, 4, len(records))
    hdr[8] = 1 if sim.halted else 0
    hdr[9] = sim.pc & 0xFF
    hdr[12] = len(init_rx) & 0xFF
    for i, w in enumerate(init_rx[:16]):
        struct.pack_into("<H", hdr, 15 + 2 * i, w & 0xFFFF)
    return bytes(hdr), records


def load_hex(path):
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                words.append(int(line, 16))
    return words


def main():
    if len(sys.argv) != 3:
        print("usage: record_swd.py <hex> <out.bin>", file=sys.stderr)
        sys.exit(2)
    hex_path, out_path = sys.argv[1], sys.argv[2]
    hdr, records = record_swd(load_hex(hex_path), INIT_RX)
    with open(out_path, "wb") as f:
        f.write(hdr)
        for r in records:
            f.write(r)
    print(f"swd: {len(records)} ticks, {len(hdr) + len(records) * REC_SIZE} bytes -> {out_path}")


if __name__ == "__main__":
    sys.exit(main())
