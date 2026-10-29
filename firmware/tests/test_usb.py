"""TEMPO USB 1.1 low-speed device TX test: independent spec decoder.

TEST PLAN
  host: [0x0001, 4, 0xFF, 0x3C, 0xFF, 0xA5]  -> TX two packets
        [0x00FF]                            -> HLT
  check (INDEPENDENT USB 1.1 decoder, written from the spec -- MSB-first
  LFSR residue method, NOT the firmware's reflected implementation):
    * segment D+/D- pin history into packets on the dithered grid
      (33.33 cycles/bit nominal, anchored at each packet's first SYNC edge)
    * report max edge deviation from the ideal grid (must be <= 1 cycle)
    * NRZI-decode, de-stuff (stuff bits present, never 7 consecutive 1s)
    * token: SYNC, PID == SETUP (0x2D), ADDR == 5, ENDP == 0, CRC5 residue
    * data: SYNC, PID == DATA0 (0xC3), payload == host args, CRC16 residue
    * EOP: SE0 width == 2 bit cells (+-1 cycle), bus returns to J idle
    * TX FIFO == [0x0000] status; PE halted; zero warnings/stickies
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim
import tb

TEST = {"name": "usb", "proto": "usb"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/usb/usb.asm"
PAYLOAD = [0xFF, 0x3C, 0xFF, 0xA5]

J, K, SE0 = 0x02, 0x01, 0x00
_hist = []          # (cycle, dpdm) recorded once per core tick by the peer


def peer(sim):
    _hist.append((sim.cycle, sim.pins_phys & 0x03))


def build(sim):
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("usb", src, workdir)
    build.nwords = nwords
    sim.imem = img + [0] * (256 - len(img))
    sim.host_push_rx_words([0x0001, len(PAYLOAD)] + PAYLOAD + [0x00FF])


# ---------------------------------------------------------------------------
# Independent USB 1.1 decoder (from the spec)
# ---------------------------------------------------------------------------

def crc5_checker(bits):
    """MSB-first LFSR, poly x^5+x^2+1 (low 00101), init all-ones.
    Feeding data+CRC in tx order must leave the spec residue 01100."""
    crc = 0x1F
    for b in bits:
        fb = ((crc >> 4) & 1) ^ b
        crc = (crc << 1) & 0x1F
        if fb:
            crc ^= 0x05
    return crc


def crc16_checker(bits):
    """MSB-first LFSR, poly x^16+x^15+x^2+1 (low 0x8005), init all-ones.
    Feeding data+CRC in tx order must leave residue 1000000000001101."""
    crc = 0xFFFF
    for b in bits:
        fb = ((crc >> 15) & 1) ^ b
        crc = (crc << 1) & 0xFFFF
        if fb:
            crc ^= 0x8005
    return crc


def decode_bus(hist):
    """hist: [(cycle, state)] with state in {J,K,SE0}. Returns
    (packets, max_edge_dev_cycles, transcript_lines). Each packet is a
    dict with raw cell states, decoded+destuffed bits, EOP width."""
    states = [s for _, s in hist]
    cycles = [c for c, _ in hist]
    n = len(states)
    packets = []
    max_dev = 0
    lines = []
    i = 0
    # find packet starts: J (idle >= 5 samples) followed by K
    while i < n:
        if states[i] == K and (i == 0 or states[i - 1] == J):
            # require this to be a genuine start: previous run of J >= 5
            j = i - 1
            run = 0
            while j >= 0 and states[j] == J:
                run += 1
                j -= 1
            if run >= 5:
                t0 = cycles[i]           # first K sample = SYNC edge anchor
                pkt, dev, used = _decode_packet(states, cycles, i, t0)
                max_dev = max(max_dev, dev)
                packets.append(pkt)
                i += max(used, 1)
                continue
        i += 1
    return packets, max_dev, lines


def _decode_packet(states, cycles, start_idx, t0):
    """Decode cells on the nominal grid anchored at t0 (first K sample).
    Cell k ideal span: [t0 + round(k*100/3), t0 + round((k+1)*100/3))."""
    n = len(states)
    cells = []                 # cell states (J/K) until SE0 cell
    max_dev = 0
    k = 0
    eop_start_cycle = None
    # sample cells at centers
    while True:
        center = t0 + round((2 * k + 1) * 50 / 3)
        # find sample at/after center
        j = start_idx
        while j < n and cycles[j] < center:
            j += 1
        if j >= n:
            break
        st = states[j]
        if st == SE0:
            eop_start_cycle = t0 + round(k * 100 / 3)
            break
        cells.append(st)
        k += 1
        if k > 300:
            break
    # EOP width: consecutive SE0 samples from eop region
    eop_width = None
    if eop_start_cycle is not None:
        j = start_idx
        while j < n and not (states[j] == SE0
                             and cycles[j] >= eop_start_cycle - 3):
            j += 1
        cnt = 0
        while j < n and states[j] == SE0:
            cnt += 1
            j += 1
        eop_width = cnt          # samples are 1 per cycle
        used = j - start_idx
        # edge deviations, restricted to this packet's span (through the
        # J cell that follows SE0, ~1 more cell)
        end_cyc = cycles[j] + 34 if j < n else cycles[-1]
        prev = states[start_idx - 1] if start_idx > 0 else J
        for idx in range(start_idx, n):
            if cycles[idx] > end_cyc:
                break
            if states[idx] != prev:
                edge_cyc = cycles[idx]
                kk = round((edge_cyc - t0) * 3 / 100)
                ideal = t0 + round(kk * 100 / 3)
                max_dev = max(max_dev, abs(edge_cyc - ideal))
                prev = states[idx]
    else:
        used = start_idx
    # NRZI decode: prev bus state before SYNC is J (idle)
    bits = []
    prev = J
    for st in cells:
        bits.append(1 if st == prev else 0)
        prev = st
    # de-stuff
    out = []
    ones = 0
    nstuff = 0
    stuff_err = None
    for b in bits:
        if ones == 6:
            if b != 0:
                stuff_err = "missing stuff bit after six 1s"
            nstuff += 1
            ones = 0
            continue             # drop stuff bit (the 0 itself resets count)
        out.append(b)
        ones = ones + 1 if b == 1 else 0
    pkt = {"cells": cells, "bits_raw": bits, "bits": out, "nstuff": nstuff,
           "stuff_err": stuff_err, "eop_width": eop_width,
           "ncells": len(cells)}
    return pkt, max_dev, used


def bits_to_bytes(bits):
    byts = []
    for i in range(0, len(bits) - 7, 8):
        v = 0
        for j in range(8):
            v |= bits[i + j] << j
        byts.append(v)
    return byts


def check(sim):
    errs = []
    rep = []

    if sim.warnings:
        errs.append(f"{len(sim.warnings)} sim warnings (want 0)")
        for c, w in sim.warnings[:5]:
            rep.append(f"  warn @{c}: {w}")
    rep.append(f"firmware image = {build.nwords} words (limit 256)")

    packets, max_dev, _ = decode_bus(_hist)
    rep.append(f"decoder: {len(packets)} packets, max edge deviation from "
               f"ideal 33.33c grid = {max_dev} cycle(s) "
               f"({max_dev * 20} ns)")
    if len(packets) != 2:
        errs.append(f"decoder found {len(packets)} packets, want 2")
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
                errs.append(f"{name}: EOP SE0 width {p['eop_width']} cycles, "
                            f"want 2 bit cells (66.7 +- ~3)")

        # ---- token packet ----
        tbts = tok["bits"]
        if len(tbts) != 32:
            errs.append(f"token: {len(tbts)} bits after de-stuff, want 32")
        else:
            byts = bits_to_bytes(tbts)
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
            res = crc5_checker(field)
            rep.append(f"token CRC5 residue = {res:05b} (spec: 01100)")
            if res != 0b01100:
                errs.append(f"token CRC5 residue {res:05b} != 01100")

        # ---- data packet ----
        dbts = dat["bits"]
        want_bits = 16 + 8 * len(PAYLOAD) + 16
        if len(dbts) != want_bits:
            errs.append(f"data: {len(dbts)} bits after de-stuff, "
                        f"want {want_bits}")
        else:
            byts = bits_to_bytes(dbts)
            rep.append(f"data bytes: {[hex(b) for b in byts]}")
            if byts[0] != 0x80:
                errs.append(f"data SYNC = {byts[0]:#04x}, want 0x80")
            if byts[1] != 0xC3:
                errs.append(f"data PID = {byts[1]:#04x}, want 0xC3 (DATA0)")
            got_payload = byts[2:2 + len(PAYLOAD)]
            if got_payload != PAYLOAD:
                errs.append(f"data payload {got_payload} != {PAYLOAD}")
            else:
                rep.append(f"data payload OK: {[hex(b) for b in got_payload]}")
            crc_field = dbts[16 + 8 * len(PAYLOAD):]
            res = crc16_checker(dbts[16:16 + 8 * len(PAYLOAD)] + crc_field)
            rep.append(f"data CRC16 residue = {res:016b} "
                       f"(spec: 1000000000001101), CRC tx bits = {crc_field}")
            if res != 0b1000000000001101:
                errs.append(f"data CRC16 residue {res:016b} != spec residue")

    # bus returns to J idle at end
    if _hist and _hist[-1][1] != J:
        errs.append(f"bus not in J idle at end (state {_hist[-1][1]})")
    else:
        rep.append("bus in J idle at end")

    tx_words = sim.host_pop_tx_words()
    if tx_words != [0x0000]:
        errs.append(f"TX words {[hex(w) for w in tx_words]} != [0x0000]")
    else:
        rep.append("TX status word OK: [0x0000]")
    if not sim.halted:
        errs.append("PE did not halt on 0x00FF")
    else:
        rep.append(f"PE halted after {sim.cycle} cycles")
    if sim.sticky & 0x06:
        errs.append(f"FIFO stickies set: {sim.sticky & 0x06:#04x}")

    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
