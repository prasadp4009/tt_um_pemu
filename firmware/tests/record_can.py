#!/usr/bin/env python3
"""COS1 golden-trace recorder for the CAN stretch protocol.

Mirrors tools/record_cosim.py (same header/record format, reuses its
dump_record so the trace is COS1 byte-compatible), but the record loop
drives the golden model with the CAN bus peer attached (sim.pins_peer),
because the receiver's ACK drive onto RXD is part of the recorded
scenario -- record_cosim.py's peer-less loop cannot produce it.

Recorded scenario (compact): a single TX frame with ACK,
  init_rx = [0x0001, 0x123, 2, 0xFF, 0x00, 0x00FF]
(ID=0x123, DLC=2, data FF 00 -- exercises stuffing in RTR..DLC and data,
CRC-15, ACK slot sample -> status 0). The golden test (tests/test_can.py)
runs the fuller scenario (second frame + arbitration).

Usage: python3 tests/record_can.py <can.hex> <out_trace.bin>
"""
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.normpath(os.path.join(HERE, "..", "tools"))
sys.path.insert(0, TOOLS)
sys.path.insert(0, HERE)

from sim import Sim                    # noqa: E402
from record_cosim import dump_record, load_hex, REC_SIZE  # noqa: E402

spec = importlib.util.spec_from_file_location("test_can",
                                              os.path.join(HERE, "test_can.py"))
test_can = importlib.util.module_from_spec(spec)
spec.loader.exec_module(test_can)

INIT_RX = [0x0001, 0x0123, 0x0002, 0x00FF, 0x0000, 0x00FF]
ARB_RX = [0x0002, 0x0155, 0x00FF]


def record_can(hex_words, arb=False, max_cycles=5_000_000):
    init_rx = ARB_RX if arb else INIT_RX
    if arb:
        # arm the bus model on the first (only) frame of this scenario
        test_can.ARB_FRAME_IDX = 0
    sim = Sim(list(hex_words))
    sim.rx_fifo = list(init_rx)
    sim.pins_peer = test_can.CANBus()

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

    tx = sim.host_pop_tx_words()
    want = [0xFFA0] if arb else [0x0000]
    assert tx == want, \
        f"recorded scenario sanity: TX words {tx}, want {want}"

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
    if len(sys.argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    hex_path, out_path = sys.argv[1], sys.argv[2]
    arb = len(sys.argv) == 4 and sys.argv[3] == "arb"
    hdr, records = record_can(load_hex(hex_path), arb=arb)
    with open(out_path, "wb") as f:
        f.write(hdr)
        for r in records:
            f.write(r)
    print(f"can{' arb' if arb else ''}: {len(records)} ticks, "
          f"{len(hdr) + len(records) * REC_SIZE} bytes -> {out_path} "
          f"({'arbitration loss ID=0x155 -> 0xFFA0' if arb else 'TX frame ID=0x123 DLC=2 data FF00, ACKd, 1 Mbit/s'})")


if __name__ == "__main__":
    sys.exit(main())
