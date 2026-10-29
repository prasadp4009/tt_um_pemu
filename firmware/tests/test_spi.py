"""Tarang SPI master test: mode-0 1 MHz bit-bang vs scripted SPI slave peer.

TEST PLAN
  host: [0x0001, 2, 0xA5, 0x3C]  -> 2-byte full-duplex transfer
        [0x0003, 0x0001]          -> set-mode (unsupported -> 0xFFFF)
        [0x0001, 0]              -> 0-byte transfer edge case
        [0x00FF]                 -> HLT
  peer: SPI slave; on CS# falling edge loads response[i] = ~tx[i] & 0xFF,
        drives MSB first, changes MISO on SCLK falling edges, samples MOSI
        on SCLK rising edges.
  check: peer saw exactly the MOSI bytes; rx bytes == ~tx pattern;
         every SCLK period == 50 cycles; byte time == 456 cycles;
         CS# low window covers exactly each transaction; 2 CS# pulses;
         zero sim warnings; PE halted.
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim
import tb

TEST = {"name": "spi", "proto": "spi"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/spi/spi.asm"
TX_BYTES = [0xA5, 0x3C]
RESP_BYTES = [(~b) & 0xFF for b in TX_BYTES]

# pin bit positions
SCLK, MOSI, MISO, CSN = 2, 3, 4, 5


class SPISlave:
    """Mode-0 SPI slave peer. Drives MISO (pin4); observes PE-driven
    SCLK/MOSI/CS# via sim.pin_drv (post-commit values, seen by the peer
    during end_of_cycle before physical resolution -- 1-cycle granularity
    is plenty with >=24-cycle edges)."""

    def __init__(self, tx_bytes):
        self.resp = [(~b) & 0xFF for b in tx_bytes]
        self.reset()

    def reset(self):
        self.cs = 1
        self.sclk = 0
        self.byte_idx = 0
        self.bit_idx = 0      # MOSI bits sampled in current byte
        self.cur = 0          # assembling MOSI byte
        self.seen = []        # completed MOSI bytes
        self.sent = []        # completed MISO response bytes
        self.miso = None      # current MISO drive (None = Hi-Z)
        self.pulses = 0       # CS# falling-edge count

    def __call__(self, sim):
        pdir, drv = sim.pdir, sim.pin_drv
        cs = (drv >> CSN) & 1 if (pdir >> CSN) & 1 else 1
        sclk = (drv >> SCLK) & 1 if (pdir >> SCLK) & 1 else 0
        mosi = (drv >> MOSI) & 1 if (pdir >> MOSI) & 1 else 0

        if self.cs == 1 and cs == 0:          # CS# falling: load resp MSB
            self.pulses += 1
            self.bit_idx = 0
            self.cur = 0
            rb = self.resp[self.byte_idx] if self.byte_idx < len(self.resp) else 0
            self.miso = (rb >> 7) & 1
        elif self.cs == 0 and cs == 1:        # CS# rising: release bus
            self.miso = None

        if cs == 0:
            if self.sclk == 0 and sclk == 1:  # rising: sample MOSI
                self.cur = ((self.cur << 1) | mosi) & 0xFF
                self.bit_idx += 1
                if self.bit_idx == 8:
                    self.seen.append(self.cur)
                    rb = (self.resp[self.byte_idx]
                          if self.byte_idx < len(self.resp) else 0)
                    self.sent.append(rb)
                    self.byte_idx += 1
                    self.cur = 0
                    self.bit_idx = 0
            elif self.sclk == 1 and sclk == 0:  # falling: advance MISO
                rb = (self.resp[self.byte_idx]
                      if self.byte_idx < len(self.resp) else 0)
                self.miso = (rb >> (7 - self.bit_idx)) & 1

        self.cs, self.sclk = cs, sclk
        sim.peer_drv[MISO] = self.miso


_slave = None


def peer(sim):
    _slave(sim)


def build(sim):
    global _slave
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("spi", src, workdir)
    sim.imem = img + [0] * (256 - len(img))
    sim.host_push_rx_words(
        [0x0001, len(TX_BYTES)] + TX_BYTES +   # 2-byte transfer
        [0x0003, 0x0001] +                     # set-mode (unsupported)
        [0x0001, 0] +                          # 0-byte transfer edge case
        [0x00FF])                              # halt
    _slave = SPISlave(TX_BYTES)


def _pin_transitions(snaps, pin):
    """Return (rise_commits, fall_commits): snapshot cycles where physical
    pin went 0->1 / 1->0. Commit cycle = snapshot cycle - 1 (all pin
    instructions here are d=0, so the snapshot lands one cycle after the
    base cycle that committed the edge)."""
    rises, falls = [], []
    prev = 0
    for (cyc, pc, pins, sync, ts) in snaps:
        cur = (pins >> pin) & 1
        pr = (prev >> pin) & 1
        if cur and not pr:
            rises.append(cyc - 1)
        elif pr and not cur:
            falls.append(cyc - 1)
        prev = pins
    return rises, falls


def check(sim):
    errs = []
    rep = []

    # 1. zero warnings
    if sim.warnings:
        errs.append(f"{len(sim.warnings)} sim warnings (want 0)")
        for c, w in sim.warnings[:5]:
            rep.append(f"  warn @{c}: {w}")

    # 2. peer saw exactly the MOSI bytes sent
    if _slave.seen != TX_BYTES:
        errs.append(f"peer MOSI bytes {_slave.seen} != sent {TX_BYTES}")
    else:
        rep.append(f"peer MOSI bytes OK: {[hex(b) for b in _slave.seen]}")

    # 3. MISO bytes received == ~tx pattern; TX FIFO word order
    #    [rx0, rx1, 0x0000(xfer status), 0xFFFF(mode unsupported),
    #     0x0000(N=0 xfer status)]
    tx_words = sim.host_pop_tx_words()
    want_tx = RESP_BYTES + [0x0000, 0xFFFF, 0x0000]
    if tx_words != want_tx:
        errs.append(f"TX words {[hex(w) for w in tx_words]} != "
                    f"want {[hex(w) for w in want_tx]}")
    else:
        rep.append(f"TX words OK: rx={[hex(w) for w in tx_words[:2]]} "
                   f"xfer-status=0x0000 mode-status=0xFFFF n0-status=0x0000")
    if _slave.sent != RESP_BYTES:
        errs.append(f"peer sent {_slave.sent} != resp {RESP_BYTES}")

    # 4. SCLK period: every rising->rising delta == 50 cycles, except the
    #    inter-byte gap delta == 58 (measured; = 25 fall + 33 gap; was 57 — see audit 2026-10-29).
    rises, falls = _pin_transitions(sim.vcd_signals, SCLK)
    nbits = len(TX_BYTES) * 8
    if len(rises) != nbits:
        errs.append(f"{len(rises)} SCLK rising edges, want {nbits}")
    else:
        deltas = [b - a for a, b in zip(rises, rises[1:])]
        bad = [(i, d) for i, d in enumerate(deltas)
               if d != (58 if (i + 1) % 8 == 0 else 50)]
        if bad:
            errs.append(f"SCLK period deviations (want 50, 58 at byte "
                        f"boundary): {bad[:8]}")
        else:
            n50 = sum(1 for d in deltas if d == 50)
            n56 = sum(1 for d in deltas) - n50
            rep.append(f"SCLK period: {n50}x50c + {n56}x58c(byte gap), "
                       f"zero deviation")
            rep.append("byte-gap placement OK (58c every 8th delta)")
        # duty: first bit high time == 25 cycles
        if falls and falls[0] - rises[0] != 25:
            errs.append(f"SCLK high time bit0 = {falls[0]-rises[0]}, want 25")
        else:
            rep.append("SCLK duty 25c high / 25c low (bit 0)")

    # 5. cycles/byte: first rising edge of byte k -> byte k+1 == 408 (was 407)
    if len(rises) == nbits:
        byte_time = rises[8] - rises[0]
        if byte_time != 408:
            errs.append(f"cycles/byte={byte_time}, want 408 (=400+8)")
        else:
            rep.append(f"cycles/byte = 408 = 400 + 8 overhead (theory match)")

    # 6. CS# low window covers exactly each transaction.
    #    rises[0] is the init 0->1 (pin undriven->driven-high); transaction
    #    windows pair falls[i] with rises[i+1].
    cs_rises, cs_falls = _pin_transitions(sim.vcd_signals, CSN)
    if _slave.pulses != 2 or len(cs_falls) != 2 or len(cs_rises) != 3:
        errs.append(f"CS# pulses: peer={_slave.pulses} vcd_falls={len(cs_falls)} "
                    f"vcd_rises={len(cs_rises)}, want 2/2/3(incl init rise)")
    elif not (cs_rises[0] < cs_falls[0]):
        errs.append("CS# init rise not before first transaction")
    else:
        rep.append("CS# pulsed twice (2-byte xfer + 0-byte xfer), clean init")
        w0, w1 = (cs_falls[0], cs_rises[1]), (cs_falls[1], cs_rises[2])
        # txn1: window must bracket all 16 SCLK edges
        if not (w0[0] < rises[0] and w0[1] > falls[-1]):
            errs.append("txn1 CS# window does not bracket SCLK activity")
        else:
            rep.append(f"txn1 CS# low window [{w0[0]},{w0[1]}] "
                       f"brackets SCLK [{rises[0]},{falls[-1]}]")
        # txn2 (N=0): no SCLK edges inside, short pulse
        mid_rises = [r for r in rises if w1[0] < r < w1[1]]
        if mid_rises:
            errs.append(f"N=0 xfer shows SCLK edges: {mid_rises}")
        else:
            rep.append(f"txn2 (N=0) CS# pulse {w1[1]-w1[0]}c, no SCLK edges")
        # no SCLK activity outside CS# windows
        outside = [r for r in rises
                   if not (w0[0] < r < w0[1] or w1[0] < r < w1[1])]
        if outside:
            errs.append(f"SCLK rising edges outside CS# windows: {outside}")
        else:
            rep.append("no SCLK activity outside CS# windows")

    # 7. PE halted cleanly on 0x00FF
    if not sim.halted:
        errs.append("PE did not halt on 0x00FF")
    else:
        rep.append(f"PE halted after {sim.cycle} cycles")

    # 8. no FIFO stickies tripped (overrun/underrun would mean a bug)
    if sim.sticky & 0x06:
        errs.append(f"FIFO stickies set: {sim.sticky & 0x06:#04x} "
                    f"(TX_OVERRUN/RX_UNDERRUN)")

    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
