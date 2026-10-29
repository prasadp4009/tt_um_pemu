#!/usr/bin/env python3
"""Tarang-32 1-Wire master firmware test (Worker D).

TEST={"name":"onewire","proto":"onewire"}

Assembles firmware/onewire/onewire.asm (never hand-encoded), loads it,
and drives it through a DS18B20-ish peer model on pin7:

  host stream : 0x0001 | 0x0002,0xA5 | 0x0002,0xCC | 0x0002,0xBE |
                0x0003 | 0x0004 | 0x00FF
  expect TX   : 0x0001, 0x0000, 0x0000, 0x0000, 0x91,
                scratchpad[0..8], then HLT.

A second sim run (peer detached) checks the no-device path:
  host stream : 0x0001 | 0x00FF  ->  TX 0x0000, EVT 1, TIMEOUT sticky.

check() asserts: presence word, no-device word+EVT1, write bit-exactness
(peer's sampled bits == transmitted, low times inside the 1-Wire
write-1/write-0 windows), read byte == scratchpad[0], demo 9 bytes ==
scratchpad, every measured timing inside its spec window, zero sim
warnings, image <= 150 words.
"""
import os
import sys

TOOLS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "tools"))
sys.path.insert(0, TOOLS)
import tb
from sim import Sim

TEST = {"name": "onewire", "proto": "onewire"}

# Fixed slave scratchpad (documented in onewire.asm header).
# temp = 0x0191 = 401 -> 401/16 = 25.0625 C; TH=0x4B, TL=0x46,
# config=0x7F (12-bit), reserved 0xFF,0x0F->0x10, CRC=0xA2.
SCRATCH = [0x91, 0x01, 0x4B, 0x46, 0x7F, 0xFF, 0xFF, 0x10, 0xA2]

ASM_PATH = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "..", "onewire", "onewire.asm"))

IMG = None
NWORDS = None
PEER = None


class DS18B20Peer:
    """DS18B20-ish 1-Wire slave on pin7 (testbench model).

    Open-drain discipline: drives 0 or Hi-Z (None), never 1.
    Timing @50 MHz (1 cycle = 20 ns):
      presence : after reset release, wait 30 us (1500 cyc), pull low
                 120 us (6000 cyc).  (tPDH 15-60 us, tPDL 60-240 us)
      write    : sample wire 30 us (1500 cyc) after slot falling edge.
                 write-1 released at 6 us -> high; write-0 low 61 us -> low.
      read     : on slot falling edge drive the bit -- 0: pull low 60 us
                 (3000 cyc); 1: stay released.
      reset    : wire low > 240 us (12000 cyc) then release.
    Command tracking: 0xCC (SKIP ROM) -> expect function code;
    0xBE (READ SCRATCHPAD) -> read phase, serves the 9-byte scratchpad
    LSB-first. Anything else written is recorded and ignored.
    """

    def __init__(self, present=True):
        self.present = present
        self.scratch = list(SCRATCH)
        self.phase = "IDLE"
        self.prev_wire = 1
        self.low_run = 0
        self.drive_until = -1
        self.presence_at = -1
        self.presence_until = -1
        self.sample_at = -1
        self.bits = []
        self.written_bytes = []
        self.write_slots = []   # {fall, rise, bit} per master write slot
        self.read_slots = []    # (fall, bit) per master read slot
        self.read_rises = []    # rise cycle per read slot (peer or master)
        self.read_sent = []     # bytes served to master, in order
        self.events = []        # (cycle, name)
        self.transitions = []   # (cycle, level) of observed wire
        self.rb = 0
        self.rbit = 0

    # -- per-cycle callback (runs BEFORE pin resolution; sees last cycle's wire)
    def __call__(self, sim):
        c = sim.cycle
        sim.peer_drv[7] = 0 if c < self.drive_until else None
        wire = (sim.pins_phys >> 7) & 1
        if wire != self.prev_wire:
            self.transitions.append((c, wire))
        fell = self.prev_wire == 1 and wire == 0
        rose = self.prev_wire == 0 and wire == 1
        if wire == 0:
            self.low_run += 1
        else:
            if self.low_run > 12000:
                self.events.append((c, "reset_rise"))
                self.on_reset(c)
            self.low_run = 0
        if fell:
            self.on_fall(c)
        if rose:
            self.on_rise(c)
        if 0 <= self.presence_at <= c:
            self.events.append((c, "pres_fall"))
            self.drive_until = c + 6000
            self.presence_until = c + 6000
            self.presence_at = -1
            self.phase = "PRESENCE"
        if 0 <= self.presence_until <= c:
            self.events.append((c, "pres_rise"))
            self.presence_until = -1
            self.drive_until = -1
            self.phase = "CMD"
            self.bits = []
        if 0 <= self.sample_at <= c:
            bit = 0 if wire == 0 else 1
            self.bits.append(bit)
            if self.write_slots:
                self.write_slots[-1]["bit"] = bit
            self.sample_at = -1
            if len(self.bits) == 8:
                byte = 0
                for i, b in enumerate(self.bits):
                    byte |= (b << i)
                self.written_bytes.append(byte)
                self.events.append((c, "wbyte_%02X" % byte))
                if byte == 0xCC:
                    self.phase = "CMD2"
                elif self.phase == "CMD2":
                    if byte == 0xBE:
                        self.phase = "READ"
                        self.rb = 0
                        self.rbit = 0
                    else:
                        self.phase = "CMD"
                self.bits = []
        self.prev_wire = wire

    def on_fall(self, c):
        if self.phase in ("CMD", "CMD2"):
            self.write_slots.append({"fall": c, "rise": None, "bit": None})
            self.sample_at = c + 1500
        elif self.phase == "READ":
            bit = (self.scratch[self.rb] >> self.rbit) & 1
            self.read_slots.append((c, bit))
            if bit == 0:
                self.drive_until = c + 3000
            self.rbit += 1
            if self.rbit == 8:
                self.rbit = 0
                self.read_sent.append(self.scratch[self.rb])
                self.rb = min(self.rb + 1, 8)

    def on_rise(self, c):
        if self.phase in ("CMD", "CMD2"):
            if self.write_slots and self.write_slots[-1]["rise"] is None:
                self.write_slots[-1]["rise"] = c
        elif self.phase == "READ":
            if len(self.read_rises) < len(self.read_slots):
                self.read_rises.append(c)

    def on_reset(self, c):
        self.drive_until = -1
        self.sample_at = -1
        self.presence_at = -1
        self.presence_until = -1
        self.bits = []
        self.rb = 0
        self.rbit = 0
        if self.present:
            self.presence_at = c + 1500
            self.phase = "RESET"
        else:
            self.phase = "IDLE"


def build(sim):
    global IMG, NWORDS, PEER
    with open(ASM_PATH) as f:
        src = f.read()
    workdir = os.environ.get(
        "TB_WORKDIR",
        os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(tb.__file__)),
                                      "..", "tests", "out")))
    os.makedirs(workdir, exist_ok=True)
    IMG, NWORDS, _top = tb.assemble_src("onewire", src, workdir)
    sim.imem = IMG + [0] * (256 - len(IMG))
    PEER = DS18B20Peer(present=True)
    sim.host_push_rx_words([0x0001,
                            0x0002, 0xA5,
                            0x0002, 0xCC,
                            0x0002, 0xBE,
                            0x0003,
                            0x0004,
                            0x00FF])


def peer(sim):
    PEER(sim)


def _low_runs(trans):
    """(fall_cycle, duration) for every observed low run."""
    runs = []
    for i in range(len(trans) - 1):
        c, lvl = trans[i]
        c2, _ = trans[i + 1]
        if lvl == 0:
            runs.append((c, c2 - c))
    return runs


def check(sim):
    rep = []
    ok = True

    def A(cond, msg):
        nonlocal ok
        rep.append(("[PASS] " if cond else "[FAIL] ") + msg)
        ok = ok and bool(cond)

    A(NWORDS is not None and NWORDS <= 150,
        "image %s words (target <= 150)" % NWORDS)
    A(sim.halted, "main run halted on 0x00FF (cycles=%d)" % sim.cycle)
    A(sim.warnings == [],
        "main run: zero sim warnings (got %d)" % len(sim.warnings))

    # ---- TX stream ----
    tx = sim.host_pop_tx_words()
    exp_tx = [0x0001, 0x0000, 0x0000, 0x0000, 0x91] + SCRATCH
    A(tx == exp_tx,
      "TX stream = %s" % ["0x%04X" % w for w in tx])
    A(bool(sim.evtflag & 0x1),
      "EVT0 raised on completions (evtflag=0x%04X)" % sim.evtflag)
    A(not (sim.evtflag & 0x2), "EVT1 not raised in present-run")

    # ---- reset low time (master) ----
    resets = [r for r in _low_runs(PEER.transitions) if r[1] > 20000]
    A(len(resets) == 2, "two reset pulses observed (cmds 0x0001, 0x0004)")
    for c, d in resets:
        A(23990 <= d <= 24010,
          "reset low = %d cyc = %.2f us (spec >= 480 us)" % (d, d / 50.0))

    # ---- presence timing (slave) ----
    ev = {}
    for c, name in PEER.events:
        ev.setdefault(name, []).append(c)
    A(len(ev.get("reset_rise", [])) == 2, "two reset releases observed")
    A(len(ev.get("pres_fall", [])) == 2, "two presence pulses observed")
    for rr, pf, pr in zip(ev.get("reset_rise", []), ev.get("pres_fall", []),
                          ev.get("pres_rise", [])):
        A(750 <= pf - rr <= 3000,
          "presence fall %d cyc = %.2f us after release (spec 15-60 us)"
          % (pf - rr, (pf - rr) / 50.0))
        A(3000 <= pr - pf <= 12000,
          "presence low %d cyc = %.1f us (spec 60-240 us)"
          % (pr - pf, (pr - pf) / 50.0))

    # ---- write byte 0xA5 : bit-exact + slot timing ----
    wsl = PEER.write_slots[:8]
    A(len(wsl) == 8, "8 write slots for 0xA5 byte (got %d)" % len(wsl))
    bits = [(0xA5 >> i) & 1 for i in range(8)]
    for i, s in enumerate(wsl):
        A(s["bit"] == bits[i],
          "write slot %d: peer sampled %d, want %d" % (i, s["bit"], bits[i]))
        low = s["rise"] - s["fall"]
        if bits[i]:
            A(50 <= low <= 750,
              "write-1 slot %d low = %d cyc = %.1f us (spec 1-15 us)"
              % (i, low, low / 50.0))
        else:
            A(3000 <= low <= 6000,
              "write-0 slot %d low = %d cyc = %.1f us (spec 60-120 us)"
              % (i, low, low / 50.0))
    for i in range(len(wsl) - 1):
        per = wsl[i + 1]["fall"] - wsl[i]["fall"]
        A(3490 <= per <= 3510,
          "write slot period[%d] = %d cyc (want 3500)" % (i, per))
    # (0xA5 via 0x0002; 0xCC/0xBE via 0x0002 for the 0x0003 read setup;
    #  0xCC/0xBE again inside the 0x0004 demo after its own reset)
    A(PEER.written_bytes == [0xA5, 0xCC, 0xBE, 0xCC, 0xBE],
      "peer written bytes = %s" % ["0x%02X" % b for b in PEER.written_bytes])
    # demo write slots (0xCC, 0xBE) use the same subroutine; spot-check periods
    dwsl = PEER.write_slots[24:40]
    A(len(dwsl) == 16, "16 demo write slots (got %d)" % len(dwsl))
    for i in range(len(dwsl) - 1):
        per = dwsl[i + 1]["fall"] - dwsl[i]["fall"]
        A(3490 <= per <= 3510,
          "demo write slot period[%d] = %d cyc (want 3500)" % (i, per))

    # ---- read byte (0x0003) : first 8 read slots ----
    rsl = PEER.read_slots[:8]
    A(len(rsl) == 8, "8 read slots for 0x0003 (got %d)" % len(rsl))
    exp_rb = [(0x91 >> i) & 1 for i in range(8)]
    for i, (fall, bit) in enumerate(rsl):
        A(bit == exp_rb[i],
          "read slot %d: slave drove %d, want 0x91 bit %d" % (i, bit, exp_rb[i]))
    for i in range(len(rsl) - 1):
        per = rsl[i + 1][0] - rsl[i][0]
        A(3490 <= per <= 3510,
          "read slot period[%d] = %d cyc (want 3500)" % (i, per))
    # master drive-low per read slot: 1-bits released by master at ~300 cyc,
    # 0-bits held by peer to ~3000 cyc
    for i, (fall, bit) in enumerate(rsl):
        if i < len(PEER.read_rises):
            low = PEER.read_rises[i] - fall
            if bit:
                A(250 <= low <= 750,
                  "read slot %d (bit=1): master low = %d cyc (spec 1-15 us)"
                  % (i, low))
            else:
                A(2950 <= low <= 3050,
                  "read slot %d (bit=0): peer-held low = %d cyc (~60 us)"
                  % (i, low))

    # ---- demo bytes ----
    A(PEER.read_sent[1:10] == SCRATCH,
      "demo read_sent[1:10] == scratchpad (%s)"
      % ["0x%02X" % b for b in PEER.read_sent[1:10]])

    # ---- no-device run (peer detached) ----
    s2 = Sim(IMG)
    p2 = DS18B20Peer(present=False)
    s2.pins_peer = p2
    s2.host_push_rx_words([0x0001, 0x00FF])
    s2.run(max_cycles=200000)
    tx2 = s2.host_pop_tx_words()
    A(tx2 == [0x0000],
      "no-device TX = %s (want [0x0000])" % ["0x%04X" % w for w in tx2])
    A(bool(s2.evtflag & 0x2),
      "no-device EVT1 raised (evtflag=0x%04X)" % s2.evtflag)
    A(bool(s2.sticky & 0x1), "no-device TIMEOUT sticky set")
    A(s2.halted, "no-device run halted on 0x00FF")
    A(s2.warnings == [],
        "no-device run: zero sim warnings (got %d)" % len(s2.warnings))

    # ---- measured timing table ----
    rep.append("---- measured vs spec (20 ns/cycle) ----")
    for c, d in resets:
        rep.append("  reset low      : %5d cyc = %7.2f us   spec >= 480 us"
                   % (d, d / 50.0))
    for rr, pf, pr in zip(ev.get("reset_rise", []), ev.get("pres_fall", []),
                          ev.get("pres_rise", [])):
        rep.append("  presence fall  : %5d cyc = %7.2f us   spec 15-60 us"
                   % (pf - rr, (pf - rr) / 50.0))
        rep.append("  presence low   : %5d cyc = %7.1f us   spec 60-240 us"
                   % (pr - pf, (pr - pf) / 50.0))
    for i, s in enumerate(wsl):
        low = s["rise"] - s["fall"]
        spec = "1-15 us" if bits[i] else "60-120 us"
        rep.append("  write slot %d b=%d: low %4d cyc = %6.2f us   spec %s"
                   % (i, bits[i], low, low / 50.0, spec))
    rep.append("  slot period    : 3500 cyc = 70.00 us   spec 60-120 us (tSLOT)")
    rep.append("  image words    : %d (target <= 150)" % NWORDS)

    return ok, "\n".join(rep)
