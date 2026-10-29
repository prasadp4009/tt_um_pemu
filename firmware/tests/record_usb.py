"""COS1 golden-trace recorder for the USB LS TX firmware.

Mirrors tools/record_cosim.py: reuses its record()/dump_record (COS1
format), with the USB deterministic scenario prefilled in the RX FIFO
(peerless record() suffices: USB device TX needs no peer drive; the idle
bus is just the pull-up J state the firmware itself drives).

Scenario: [0x0001, 4, 0xFF, 0x3C, 0xFF, 0xA5, 0x00FF]
  TX the SETUP token + DATA0(4 payload bytes), then halt.

Usage: python3 tests/record_usb.py <hex> <out.bin>
"""
import sys

sys.path.insert(0, "/home/hatch/workspace/janestreet-pemu/firmware/tools")
from record_cosim import record, load_hex, REC_SIZE

SCENARIO = [0x0001, 4, 0xFF, 0x3C, 0xFF, 0xA5, 0x00FF]


def main():
    if len(sys.argv) != 3:
        print("usage: record_usb.py <hex> <out.bin>", file=sys.stderr)
        sys.exit(2)
    hex_path, out_path = sys.argv[1], sys.argv[2]
    hdr, records = record(load_hex(hex_path), SCENARIO)
    with open(out_path, "wb") as f:
        f.write(hdr)
        for r in records:
            f.write(r)
    print(f"usb: {len(records)} ticks, "
          f"{len(hdr) + len(records) * REC_SIZE} bytes -> {out_path}")


if __name__ == "__main__":
    sys.exit(main())
