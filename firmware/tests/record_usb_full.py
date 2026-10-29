#!/usr/bin/env python3
"""COS2 golden-trace recorder for the merged USB TX+RX firmware.

Modeled on tests/record_can.py: reuses tools/record_cosim.py's
dump_record (COS2 record format), but the record loop drives the
golden model with the USB peer attached (test_usb_full.make_peer),
because the RX phase needs the peer driving D+/D- -- the peerless
record_cosim.record() cannot produce it.

Scenario (one session, one loaded image):
  init_rx = [0x0001, 4, 0xFF, 0x3C, 0xFF, 0xA5, 0x0002, 0x00FF]
  TX SETUP token + DATA0(FF 3C FF A5), then RX one DATA0 packet
  (peer-sourced at test_usb_full.T_START, payload FF FF), then HLT.
Sanity: TX FIFO at halt must be [0x0000] + RX stream + [0x0000],
exactly as in tests/test_usb_full.py.

Usage: python3 tests/record_usb_full.py <hex> <out.bin>
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.normpath(os.path.join(HERE, "..", "tools"))
sys.path.insert(0, TOOLS)
sys.path.insert(0, HERE)

from sim import Sim                    # noqa: E402
from record_cosim import dump_record, load_hex, REC_SIZE, HDR_SIZE  # noqa: E402
import test_usb_full                   # noqa: E402

INIT_RX = [0x0001, 4, 0xFF, 0x3C, 0xFF, 0xA5, 0x0002, 0x00FF]


def record_usb_full(hex_words, max_cycles=5_000_000):
    sim = Sim(list(hex_words))
    sim.rx_fifo = list(INIT_RX)
    sim.peer_drv = {}
    sim.pins_peer = test_usb_full.make_peer()

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
    want = [0x0000] + test_usb_full.RX_STREAM + [0x0000]
    assert tx == want, f"recorded scenario sanity: TX words {tx}, want {want}"

    hdr = bytearray(HDR_SIZE)
    hdr[0:4] = b"COS2"
    struct.pack_into("<I", hdr, 4, len(records))
    hdr[8] = 1 if sim.halted else 0
    struct.pack_into("<H", hdr, 9, sim.pc & 0x1FF)
    hdr[12] = len(INIT_RX) & 0xFF
    for i, w in enumerate(INIT_RX[:16]):
        struct.pack_into("<H", hdr, 15 + 2 * i, w & 0xFFFF)
    return bytes(hdr), records


def main():
    if len(sys.argv) != 3:
        print("usage: record_usb_full.py <hex> <out.bin>", file=sys.stderr)
        sys.exit(2)
    hex_path, out_path = sys.argv[1], sys.argv[2]
    hdr, records = record_usb_full(load_hex(hex_path))
    with open(out_path, "wb") as f:
        f.write(hdr)
        for r in records:
            f.write(r)
    print(f"usb_full: {len(records)} ticks, "
          f"{len(hdr) + len(records) * REC_SIZE} bytes -> {out_path} "
          f"(TX SETUP+DATA0 FF3CFFA5, then RX DATA0 FFFF, one image)")


if __name__ == "__main__":
    sys.exit(main())
