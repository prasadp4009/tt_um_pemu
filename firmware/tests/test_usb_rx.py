"""TEMPO USB LS RECEIVE experiment test (standalone RX image).

The product USB firmware (usb.asm, 243 words) has no room for the receiver;
this test exercises the standalone experiment image
(usb/usb_rx_experiment.asm, 62 words) to establish whether an RX loop is
cycle-feasible at all at 33.333 cycles/bit. Verdict (see
stretch_results/usb.md): the balanced PGET sample-at-center loop DOES hold
the dithered grid -- it decodes every packet below exactly, with a
27-cycle-wide first-sample calibration window. RX is therefore a WORD
gap in the combined image, not a cycle gap.

  peer: drives D+/D- with a spec-encoded packet (NRZI + stuffing, cells
        33,33,34 dithered) after an idle-J preamble.
  run1: DATA0, payload [0xFF, 0xFF] (heavy stuffing).
  run2: IN token, ADDR=5, ENDP=0.
  check: pushed bytes == the exact de-stuffed stream bytes (SYNC, PID,
        payload/field, CRC bytes in wire order), status 0, PE halted.
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim
import tb

TEST = {"name": "usb_rx", "proto": "usb_rx"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/usb/usb_rx_experiment.asm"
J, K, SE0 = 0x02, 0x01, 0x00


def bits_of(byts):
    bits = []
    for b in byts:
        for i in range(8):
            bits.append((b >> i) & 1)
    return bits


def crc16_tx_bits(payload):
    crc = 0xFFFF
    for bit in bits_of(payload):
        fb = ((crc >> 15) & 1) ^ bit
        crc = (crc << 1) & 0xFFFF
        if fb:
            crc ^= 0x8005
    comp = (~crc) & 0xFFFF
    return [(comp >> (15 - i)) & 1 for i in range(16)]


def crc5_tx_bits(field11):
    crc = 0x1F
    for bit in field11:
        fb = ((crc >> 4) & 1) ^ bit
        crc = (crc << 1) & 0x1F
        if fb:
            crc ^= 0x05
    comp = (~crc) & 0x1F
    return [(comp >> (4 - i)) & 1 for i in range(5)]


def stuff(bits):
    out, ones = [], 0
    for bit in bits:
        if ones == 6:
            out.append(0)
            ones = 0
        out.append(bit)
        ones = ones + 1 if bit == 1 else 0
    return out


def make_peer(raw_bits, t_start=300):
    sched = []
    state, t, cell = J, t_start, 0
    for bit in stuff(raw_bits):
        if bit == 0:
            state = K if state == J else J
        dur = 34 if cell % 3 == 2 else 33
        sched.append((t, state, dur))
        t += dur
        cell += 1
    sched.append((t, SE0, 66))
    t += 66
    sched.append((t, J, 33))

    def peer(sim):
        st = J
        for (tt, state, dur) in sched:
            if sim.cycle >= tt:
                st = state
            else:
                break
        sim.peer_drv[0] = st & 1
        sim.peer_drv[1] = (st >> 1) & 1

    return peer


def stream_bytes(raw_bits):
    out = []
    for i in range(0, len(raw_bits), 8):
        v = 0
        for j in range(8):
            v |= raw_bits[i + j] << j
        out.append(v)
    return out


def run_case(raw_bits):
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("usb_rx", src, workdir)
    sim = Sim(img + [0] * (256 - len(img)))
    sim.pins_peer = make_peer(raw_bits)
    sim.run(max_cycles=20000)
    return sim, sim.host_pop_tx_words(), stream_bytes(raw_bits), nwords


_case2 = {}


def build(sim):
    raw = bits_of([0x80, 0xC3, 0xFF, 0xFF]) + crc16_tx_bits([0xFF, 0xFF])
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("usb_rx", src, workdir)
    build.nwords = nwords
    sim.imem = img + [0] * (256 - len(img))
    sim.pins_peer = make_peer(raw)
    _case2["raw"] = raw

# NOTE: no module-level peer() -- tb.py would overwrite sim.pins_peer with
# it after build(). build() installs the real peer directly.


def check(sim):
    errs = []
    rep = []
    rep.append(f"RX experiment image = {build.nwords} words (standalone)")
    want1 = stream_bytes(_case2["raw"])
    got1 = sim.host_pop_tx_words()
    if got1 == want1 + [0]:
        rep.append(f"primary run: DATA0 FF FF decoded "
                   f"{[hex(x) for x in got1]}")
    else:
        errs.append(f"primary run: got {[hex(x) for x in got1]}, "
                    f"want {[hex(x) for x in want1]} + status")
    s1, g1, w1, _ = run_case(_case2["raw"])
    if g1 != w1 + [0]:
        errs.append(f"DATA0 FF FF: got {[hex(x) for x in g1]}, "
                    f"want {[hex(x) for x in w1]} + status")
    else:
        rep.append(f"DATA0 [FF FF]: decoded stream bytes "
                   f"{[hex(x) for x in g1]} == SYNC/PID/payload/CRC + status 0")
    if not s1.halted:
        errs.append("RX run1 did not halt at EOP")

    field = bits_of([0x05])[:7] + [0, 0, 0, 0]
    raw2 = bits_of([0x80, 0x69]) + field + crc5_tx_bits(field)
    s2, g2, w2, _ = run_case(raw2)
    if g2 != w2 + [0]:
        errs.append(f"IN token: got {[hex(x) for x in g2]}, "
                    f"want {[hex(x) for x in w2]} + status")
    else:
        rep.append(f"IN token ADDR=5: decoded {[hex(x) for x in g2]} "
                   f"== SYNC/PID/field/CRC5 + status 0")

    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
