"""COS1 golden-trace recorder for the JTAG stretch protocol.

Mirrors tools/record_cosim.py (same dump_record, byte-identical COS1
format), except the recording runs WITH the JTAG TAP target peer active:
record_cosim.py's record() is peerless, but this scenario needs the
target driving TDO during Shift-DR/Shift-IR, so the record loop is
replicated here with sim.pins_peer set to the target model from
tests/test_jtag.py. The pins_phys values produced by that peer are
recorded in the trace and replay into the RTL identically.

Scenario: init_rx = [0x0001 (IDCODE read), 0x0002 (BYPASS test),
0x00FF (HLT)] -- the firmware halts, as the COS1 header requires.

Usage:
    python3 tests/record_jtag.py <jtag.hex> <out.bin>
"""
import struct
import sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
TESTS = "/home/hatch/workspace/janestreet-pemu/firmware/tests"
sys.path.insert(0, TOOLS)
sys.path.insert(0, TESTS)
from sim import Sim
from record_cosim import dump_record, load_hex, REC_SIZE
import test_jtag

INIT_RX = [0x0001, 0x0002, 0x00FF]


def record(hex_words, init_rx, max_cycles=5_000_000):
    """Replicates record_cosim.record()'s hooked-tick loop, with the
    JTAG target peer driving TDO (sim.pins_peer set)."""
    sim = Sim(list(hex_words))
    sim.rx_fifo = list(init_rx)
    sim.peer_drv = {}
    target = test_jtag.JTAGTarget()
    sim.pins_peer = target

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
    assert target.state == "RTI", f"target final state {target.state}"
    assert sim.host_pop_tx_words() == [0x0477, 0x1BA0, 0x004A]

    hdr = bytearray(47)
    hdr[0:4] = b"COS1"
    struct.pack_into("<I", hdr, 4, len(records))
    hdr[8] = 1 if sim.halted else 0
    hdr[9] = sim.pc & 0xFF
    hdr[12] = len(init_rx) & 0xFF
    for i, w in enumerate(init_rx[:16]):
        struct.pack_into("<H", hdr, 15 + 2 * i, w & 0xFFFF)
    return bytes(hdr), records


def main():
    if len(sys.argv) != 3:
        print("usage: record_jtag.py <hex> <out.bin>", file=sys.stderr)
        sys.exit(2)
    hex_path, out_path = sys.argv[1], sys.argv[2]
    hdr, records = record(load_hex(hex_path), INIT_RX)
    with open(out_path, "wb") as f:
        f.write(hdr)
        for r in records:
            f.write(r)
    print(f"jtag: {len(records)} ticks, {len(hdr) + len(records)*REC_SIZE} bytes -> {out_path}")


if __name__ == "__main__":
    sys.exit(main())
