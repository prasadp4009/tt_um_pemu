#!/usr/bin/env python3
"""COS1 golden-trace recorder for the PS/2 stretch protocol.

Mirrors tools/record_cosim.py (same header/record format, reuses its
dump_record so the trace is COS1 byte-compatible), but the record loop
drives the golden model with the PS/2 keyboard peer attached
(sim.pins_peer), because the device generates CLK/DATA in the recorded
scenario -- record_cosim.py's peer-less loop cannot produce it.

Recorded scenario (compact): a single device->host receive,
  init_rx = [0x0001, 0x00FF]   (receive one frame, then HLT)
with the keyboard sending scancode 0x1C, correct odd parity, at the
fast end of the PS/2 clock spec: 16.67 kHz (bit cell 3000 cycles
@50 MHz, CLK high 1500c / low 1500c). The golden test
(tests/test_ps2.py) runs the fuller scenario at 12 kHz.

Usage: python3 tests/record_ps2.py <ps2.hex> <out_trace.bin>
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

spec = importlib.util.spec_from_file_location("test_ps2",
                                               os.path.join(HERE, "test_ps2.py"))
test_ps2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(test_ps2)

INIT_RX = [0x0001, 0x00FF]
# Fast end of the PS/2 clock spec (10.0-16.7 kHz): 3000-cycle bit cell.
REC_HI, REC_LO = 1500, 1500


def record_ps2(hex_words, max_cycles=5_000_000):
    sim = Sim(list(hex_words))
    sim.rx_fifo = list(INIT_RX)
    kb = test_ps2.PS2Keyboard(hi=REC_HI, lo=REC_LO, frames=(True,),
                              start_delay=300)
    sim.pins_peer = kb

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
    assert tx == [test_ps2.RX_BYTE, 0x0000], \
        f"recorded scenario sanity: TX words {tx}, want [0x1C, 0x0000]"
    # All 11 clocks of the frame must be on the wire. (The model may
    # still be inside the final low phase when the PE halts -- the frame
    # is complete at the 11th falling edge, which the host sampled.)
    falls = test_ps2._clk_falls(kb.wire)
    assert len(falls) == 11, f"keyboard frame incomplete: {len(falls)} falls"

    hdr = bytearray(47)
    hdr[0:4] = b"COS1"
    struct.pack_into("<I", hdr, 4, len(records))
    hdr[8] = 1 if sim.halted else 0
    hdr[9] = sim.pc & 0xFF
    hdr[12] = len(INIT_RX) & 0xFF
    for i, w in enumerate(INIT_RX[:16]):
        struct.pack_into("<H", hdr, 15 + 2 * i, w & 0xFFFF)
    return bytes(hdr), records


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    hex_path, out_path = sys.argv[1], sys.argv[2]
    hdr, records = record_ps2(load_hex(hex_path))
    with open(out_path, "wb") as f:
        f.write(hdr)
        for r in records:
            f.write(r)
    print(f"ps2: {len(records)} ticks, "
          f"{len(hdr) + len(records) * REC_SIZE} bytes -> {out_path} "
          f"(device clock 16.67 kHz, bit cell 3000 cycles)")


if __name__ == "__main__":
    sys.exit(main())
