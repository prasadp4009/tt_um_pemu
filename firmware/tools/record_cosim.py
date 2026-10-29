"""COS2 golden-trace recorder for Tarang co-simulation.

Regenerates test/cosim/traces/*.bin from the ISA golden model (sim.py)
after firmware changes. The old recorder was lost; this one replicates its
semantics, validated by reproducing the pre-fix traces' co-sim behavior.

Trace format COS2 (must match test/cosim/test_cosim.py; COS2 ONLY --
the repo reader accepts COS2 only, and all COS1 traces must be
re-recorded in COS2):

  header: 47 bytes (same size as COS1)
    offset  size  field
    0       4     magic "COS2"
    4       4     N (u32 LE) -- number of records
    8       1     halted (u8)
    9       2     final_pc (u16 LE)
    11      1     pad (zero)
    12      1     init_rx_len (u8)
    13      2     pad (zero)
    15      32    init_rx[16] (u16 LE each)

  record: 122 bytes
    offset  size  field
    0       1     pins_phys (u8)
    1       2     pc (u16 LE)
    3       32    regs[16] (u16 LE each)
    35      1     znc flags (u8: bit0=Z, bit1=N, bit2=C)
    36      2     sticky (u16 LE)
    38      1     pmask (u8)
    39      1     pdir (u8)
    40      2     pmode (u16 LE)
    42      1     pin_drv (u8)
    43      1     sync0 (u8)
    44      1     sync1 (u8)
    45      4     ts (u32 LE)
    49      2     evtflag (u16 LE)
    51      1     rx_len (u8)
    52      32    rx_fifo[16] (u16 LE each)
    84      1     tx_len (u8)
    85      32    tx_fifo[16] (u16 LE each)
    117     1     trig_mode (u8)
    118     1     obs_en (u8)
    119     1     wmark (u8)
    120     1     prescaler (u8)
    121     1     trace_len (u8)

COS1 -> COS2 delta (field by field; nothing else changes):
  * Versioning: header magic "COS1" -> "COS2" (the magic IS the version
    field; there is no separate version byte in either format).
  * Header final_pc: COS1 stored it as u8 at offset 9, with pad bytes at
    offsets 10-11. COS2 stores it as u16 LE at offsets 9-10, consuming
    the offset-10 pad byte; offset 11 remains pad. Header size is
    unchanged (47 bytes) and every other header field keeps its COS1
    offset and size (N at 4, halted at 8, init_rx_len at 12,
    init_rx[16] at 15).
  * Record pc: COS1 stored it as u8 at offset 1. COS2 stores it as
    u16 LE at offsets 1-2. The record therefore grows by one byte,
    121 -> 122 bytes, and EVERY record field after pc shifts by +1 byte
    relative to COS1 (regs 2->3, znc 34->35, sticky 35->36, pmask
    37->38, pdir 38->39, pmode 39->40, pin_drv 41->42, sync0 42->43,
    sync1 43->44, ts 44->45, evtflag 48->49, rx_len 50->51, rx_fifo
    51->52, tx_len 83->84, tx_fifo 84->85, trig_mode 116->117, obs_en
    117->118, wmark 118->119, prescaler 119->120, trace_len 120->121).
    pins_phys at offset 0 is unchanged. All shifted fields keep their
    COS1 size, encoding and semantics.
  * Reason: with the IMEM-512 expansion (ISA v0.3) PCs run 0..511 and
    neither a u8 per-record pc nor a u8 header final_pc can represent
    values above 255.

Cycle mapping: record k-1 = golden state AFTER the k-th core tick
(sim.py _tick_delay). The dump hooks _tick_delay, so multi-tick
instructions (SLEEP/WAIT/delay slots) emit one record per tick, with
pre-commit state during the ticks (matching the RTL: pc advances on the
base edge for normal insns; WAIT holds pc until the exit edge, which the
testbench special-cases via wait_exit_rd).
"""
import struct
import sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim

REC_SIZE = 122
HDR_SIZE = 47


def dump_record(sim):
    rec = bytearray(REC_SIZE)
    rec[0] = sim.pins_phys & 0xFF
    struct.pack_into("<H", rec, 1, sim.pc & 0x1FF)
    for i, r in enumerate(sim.regs):
        struct.pack_into("<H", rec, 3 + 2 * i, r & 0xFFFF)
    rec[35] = (sim.z & 1) | ((sim.n & 1) << 1) | ((sim.c & 1) << 2)
    struct.pack_into("<H", rec, 36, sim.sticky & 0xFFFF)
    rec[38] = sim.pmask & 0xFF
    rec[39] = sim.pdir & 0xFF
    struct.pack_into("<H", rec, 40, sim.pmode & 0xFFFF)
    rec[42] = sim.pin_drv & 0xFF
    rec[43] = sim.sync0 & 0xFF
    rec[44] = sim.sync1 & 0xFF
    struct.pack_into("<I", rec, 45, sim.ts & 0xFFFFFFFF)
    struct.pack_into("<H", rec, 49, sim.evtflag & 0xFFFF)
    rec[51] = len(sim.rx_fifo) & 0xFF
    for i, w in enumerate(sim.rx_fifo[:16]):
        struct.pack_into("<H", rec, 52 + 2 * i, w & 0xFFFF)
    rec[84] = len(sim.tx_fifo) & 0xFF
    for i, w in enumerate(sim.tx_fifo[:16]):
        struct.pack_into("<H", rec, 85 + 2 * i, w & 0xFFFF)
    rec[117] = sim.trig_mode & 0xFF
    rec[118] = 1 if sim.obs_en else 0
    rec[119] = sim.wmark & 0xFF
    rec[120] = sim.prescaler & 0xFF
    rec[121] = len(sim.trace) & 0xFF
    return bytes(rec)


def record(hex_words, init_rx, max_cycles=5_000_000):
    """Run the golden model with prefilled RX FIFO, no peer. Returns
    (header_bytes, records_list)."""
    sim = Sim(list(hex_words))
    sim.rx_fifo = list(init_rx)
    sim.peer_drv = {}
    sim.pins_peer = None

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

    hdr = bytearray(HDR_SIZE)
    hdr[0:4] = b"COS2"
    struct.pack_into("<I", hdr, 4, len(records))
    hdr[8] = 1 if sim.halted else 0
    struct.pack_into("<H", hdr, 9, sim.pc & 0x1FF)
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


# Deterministic co-sim scenarios (prefilled FIFO, no peer). Each exercises
# the firmware's RXNE-guarded multi-word pulls.
SCENARIOS = {
    "spi":     [0x0001, 2, 0xA5, 0x3C, 0x00FF],
    "uart":    [0x0001, 2, 0x41, 0x42, 0x00FF],
    "i2c":     [0x0001, 0xA2, 0, 0x00FF],
    "onewire": [0x0002, 0xA5, 0x00FF],
}


def main():
    if len(sys.argv) != 4:
        print("usage: record_cosim.py <name> <hex> <out.bin>", file=sys.stderr)
        sys.exit(2)
    name, hex_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    init_rx = SCENARIOS[name]
    hdr, records = record(load_hex(hex_path), init_rx)
    with open(out_path, "wb") as f:
        f.write(hdr)
        for r in records:
            f.write(r)
    print(f"{name}: {len(records)} ticks, {len(hdr) + len(records)*REC_SIZE} bytes -> {out_path}")


if __name__ == "__main__":
    sys.exit(main())
