"""TEMPO USB 1.1 low-speed TX+RX merged-image test (IMEM-512 expansion).

The merged image (usb/usb_full.asm, 299 words) carries BOTH the proven
TX path (usb.asm) and the proven RX path (usb_rx_experiment.asm) in ONE
loaded image -- the combination that needed ~291 words and could not
fit the old 256-word IMEM. This test exercises both phases back to back
with NO reload between them:

  host preload: [0x0001, 4, 0xFF, 0x3C, 0xFF, 0xA5]  -> TX phase
                [0x0002]                             -> RX phase
                [0x00FF]                             -> HLT
  TX phase check: the INDEPENDENT spec decoder from test_usb.py runs
        on the D+/D- history recorded during the TX window only and
        must reproduce the standalone usb.asm evidence exactly (SETUP
        token ADDR=5/ENDP=0 CRC5 residue 01100; DATA0 payload
        FF 3C FF A5 CRC16 residue 1000000000001101; EOP SE0 2 cells;
        max edge deviation <= 1 cycle).
  RX phase check: after the TX transaction completes, the peer drives
        a spec-encoded DATA0 packet, payload [0xFF, 0xFF] (the primary
        case of test_usb_rx.py, heavy stuffing); the merged RX path
        must PUSH exactly the de-stuffed stream bytes the standalone
        experiment produced, then status 0.
  TX FIFO at halt must be [0x0000 (TX status)] + RX stream + [0x0000].
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
TESTS = "/home/hatch/workspace/janestreet-pemu/firmware/tests"
sys.path.insert(0, TOOLS)
sys.path.insert(0, TESTS)
from sim import Sim
import tb
import test_usb
import test_usb_rx

TEST = {"name": "usb_full", "proto": "usb"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/usb/usb_full.asm"
PAYLOAD = [0xFF, 0x3C, 0xFF, 0xA5]
J, K, SE0 = 0x02, 0x01, 0x00

# RX packet starts long after the TX transaction (~3.9k cycles) ends,
# while the RX WAIT (tsel=1, 4096-cycle timeout) is already armed.
T_START = 4500

_hist = []          # (cycle, dpdm) recorded once per core tick by the peer

# RX wire bits: SYNC, PID DATA0, payload FF FF, CRC16 (spec form, as in
# test_usb_rx.py) -- the packet the peer sources in the RX phase.
RX_RAW_BITS = (test_usb_rx.bits_of([0x80, 0xC3, 0xFF, 0xFF])
               + test_usb_rx.crc16_tx_bits([0xFF, 0xFF]))
RX_STREAM = test_usb_rx.stream_bytes(RX_RAW_BITS)


def make_peer():
    """Peer: Hi-Z during the TX phase (the PE owns the bus), then drives
    the RX packet on the 33/33/34 dithered grid (same schedule
    construction as test_usb_rx.make_peer), then releases the bus.
    Records the per-tick pin history for the TX decoder."""
    sched = []
    state, t, cell = J, T_START, 0
    for bit in test_usb_rx.stuff(RX_RAW_BITS):
        if bit == 0:
            state = K if state == J else J
        dur = 34 if cell % 3 == 2 else 33
        sched.append((t, state, dur))
        t += dur
        cell += 1
    sched.append((t, SE0, 66))
    t += 66
    sched.append((t, J, 33))
    t_end = t + 33

    def peer(sim):
        _hist.append((sim.cycle, sim.pins_phys & 0x03))
        if sim.cycle < T_START or sim.cycle >= t_end:
            sim.peer_drv[0] = None
            sim.peer_drv[1] = None
            return
        st = J
        for (tt, state, dur) in sched:
            if sim.cycle >= tt:
                st = state
            else:
                break
        sim.peer_drv[0] = st & 1
        sim.peer_drv[1] = (st >> 1) & 1

    return peer


def build(sim):
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("usb_full", src, workdir)
    build.nwords = nwords
    sim.imem = img + [0] * (512 - len(img))
    sim.peer_drv = {}
    sim.pins_peer = make_peer()
    sim.host_push_rx_words([0x0001, len(PAYLOAD)] + PAYLOAD
                           + [0x0002, 0x00FF])

# NOTE: no module-level peer() -- build() installs the peer directly
# (same pattern as test_usb_rx.py; tb.py would otherwise overwrite it).


def check(sim):
    errs = []
    rep = []

    if sim.warnings:
        errs.append(f"{len(sim.warnings)} sim warnings (want 0)")
        for c, w in sim.warnings[:5]:
            rep.append(f"  warn @{c}: {w}")
    rep.append(f"merged firmware image = {build.nwords} words (limit 512)")

    # ---- TX phase: standalone decoder on the TX window only ----
    tx_hist = [(c, s) for (c, s) in _hist if c < T_START]
    packets, max_dev, _ = test_usb.decode_bus(tx_hist)
    rep.append(f"TX decoder: {len(packets)} packets, max edge deviation "
               f"from ideal 33.33c grid = {max_dev} cycle(s) "
               f"({max_dev * 20} ns)")
    if len(packets) != 2:
        errs.append(f"TX decoder found {len(packets)} packets, want 2")
    if max_dev > 1:
        errs.append(f"max edge deviation {max_dev} cycles > 1")

    if len(packets) == 2:
        tok, dat = packets
        for name, p in (("token", tok), ("data", dat)):
            rep.append(f"{name}: {p['ncells']} cells on wire, "
                       f"{len(p['bits'])} bits after de-stuff, "
                       f"{p['nstuff']} stuff bits, EOP SE0 width = "
                       f"{p['eop_width']} cycles")
            if p["stuff_err"]:
                errs.append(f"{name}: {p['stuff_err']}")
            if p["eop_width"] is None or not (64 <= p["eop_width"] <= 70):
                errs.append(f"{name}: EOP SE0 width {p['eop_width']} "
                            f"cycles, want 2 bit cells (66.7 +- ~3)")
        tbts = tok["bits"]
        if len(tbts) != 32:
            errs.append(f"token: {len(tbts)} bits after de-stuff, want 32")
        else:
            byts = test_usb.bits_to_bytes(tbts)
            rep.append(f"token bytes (LSB-first reassembly): "
                       f"{[hex(b) for b in byts]}")
            if byts[0] != 0x80:
                errs.append(f"token SYNC = {byts[0]:#04x}, want 0x80")
            if byts[1] != 0x2D:
                errs.append(f"token PID = {byts[1]:#04x}, want 0x2D (SETUP)")
            field = tbts[16:32]
            addr = sum(b << i for i, b in enumerate(field[0:7]))
            endp = sum(b << i for i, b in enumerate(field[7:11]))
            rep.append(f"token: PID=SETUP, ADDR={addr}, ENDP={endp}, "
                       f"CRC5 tx bits={field[11:16]}")
            if addr != 5:
                errs.append(f"token ADDR = {addr}, want 5")
            if endp != 0:
                errs.append(f"token ENDP = {endp}, want 0")
            res = test_usb.crc5_checker(field)
            rep.append(f"token CRC5 residue = {res:05b} (spec: 01100)")
            if res != 0b01100:
                errs.append(f"token CRC5 residue {res:05b} != 01100")
        dbts = dat["bits"]
        want_bits = 16 + 8 * len(PAYLOAD) + 16
        if len(dbts) != want_bits:
            errs.append(f"data: {len(dbts)} bits after de-stuff, "
                        f"want {want_bits}")
        else:
            byts = test_usb.bits_to_bytes(dbts)
            rep.append(f"data bytes: {[hex(b) for b in byts]}")
            if byts[0] != 0x80:
                errs.append(f"data SYNC = {byts[0]:#04x}, want 0x80")
            if byts[1] != 0xC3:
                errs.append(f"data PID = {byts[1]:#04x}, want 0xC3 (DATA0)")
            got_payload = byts[2:2 + len(PAYLOAD)]
            if got_payload != PAYLOAD:
                errs.append(f"data payload {got_payload} != {PAYLOAD}")
            else:
                rep.append(f"data payload OK: "
                           f"{[hex(b) for b in got_payload]}")
            crc_field = dbts[16 + 8 * len(PAYLOAD):]
            res = test_usb.crc16_checker(
                dbts[16:16 + 8 * len(PAYLOAD)] + crc_field)
            rep.append(f"data CRC16 residue = {res:016b} "
                       f"(spec: 1000000000001101), CRC tx bits = {crc_field}")
            if res != 0b1000000000001101:
                errs.append(f"data CRC16 residue {res:016b} != spec residue")

    # ---- both phases: FIFO transcript in ONE loaded image ----
    tx_words = sim.host_pop_tx_words()
    want_words = [0x0000] + RX_STREAM + [0x0000]
    rep.append(f"TX FIFO words: {[hex(w) for w in tx_words]}")
    rep.append(f"RX stream (standalone experiment evidence): "
               f"{[hex(b) for b in RX_STREAM]} + status 0")
    if tx_words != want_words:
        errs.append(f"TX words {[hex(w) for w in tx_words]} != "
                    f"[TX status 0] + RX stream + [RX status 0] = "
                    f"{[hex(w) for w in want_words]}")
    else:
        rep.append("TX phase status 0, then RX decoded stream + status 0 "
                   "in one loaded image: OK")
    if not sim.halted:
        errs.append("PE did not halt on 0x00FF after the RX phase")
    else:
        rep.append(f"PE halted after {sim.cycle} cycles")
    if sim.sticky & 0x06:
        errs.append(f"FIFO stickies set: {sim.sticky & 0x06:#04x}")

    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
