#!/usr/bin/env python3
"""Tarang-32 PS/2 host firmware test (stretch-protocol worker).

TEST={"name":"ps2","proto":"ps2"}

Pin map: pin0 = CLK, pin1 = DATA, both open-drain + pull-up (see ps2.asm).

TEST PLAN (host stream via RX FIFO)
  [0x0001]          receive frame 1: keyboard sends scancode 0x1C,
                    correct odd parity -> expect PUSH 0x1C, PUSH 0x0000
  [0x0001]          receive frame 2: keyboard sends 0x1C with
                    DELIBERATELY WRONG parity -> PUSH 0x1C, PUSH != 0
                    (status 0x0001: parity error flagged, byte kept)
  [0x0002, 0x00ED]  transmit 0xED (Set/Reset LEDs): inhibit >= 5000c,
                    RTS, device clocks 11 frame bits + ACK clock ->
                    PUSH 0x0000 (ACK seen)
  [0x00FF]          HLT

Keyboard model: open-drain peer (drives 0 or releases only), generates
CLK in both directions at ~12 kHz (bit cell 4167 cycles @50 MHz:
CLK high 2084c, low 2083c). Convention (both directions): transmitter
changes DATA while CLK is high; receiver samples on the CLK falling
edge. Host->device ACK: device drives DATA low for the 12th clock.

Checker (protocol-specific, from the per-cycle wire history -- NOT from
firmware outputs alone): decodes all three frames off pins_phys,
verifies start/data/parity/stop content, the bad-parity flag, the
model-decoded TX byte == 0xED with odd-correct parity, the ACK bit,
the >= 5000-cycle inhibit before RTS, and the open-drain invariant
(PE never drives CLK/DATA high push-pull; highs come from pull-ups).
"""
import os
import sys

TOOLS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "tools"))
sys.path.insert(0, TOOLS)
import tb
from sim import Sim

TEST = {"name": "ps2", "proto": "ps2"}

CLK, DATA = 0, 1
RX_BYTE = 0x1C
TX_BYTE = 0xED

# PS/2 clock ~12 kHz @50 MHz: bit cell 4167 cycles (high 2084, low 2083)
HI_CYC, LO_CYC = 2084, 2083
CELL = HI_CYC + LO_CYC


def odd_parity_bit(byte):
    return 1 if bin(byte & 0xFF).count("1") % 2 == 0 else 0


class PS2Keyboard:
    """PS/2 keyboard (device) model. Open-drain discipline: peer_drv is
    only ever 0 (drive low) or None (release) on CLK and DATA.

    Device->host: sends queued frames; DATA set while CLK high, host
    samples on falling edges (model just generates the wire).
    Host->device: watches for inhibit (CLK low >= ~4900c) + RTS (DATA
    fall while CLK low), then generates 12 clocks, samples DATA on each
    falling edge, and drives the ACK bit (DATA low) on the 12th clock.
    """

    def __init__(self, hi=HI_CYC, lo=LO_CYC, frames=(True, False),
                 start_delay=300, inter_delay=2500, tx_start_delay=800):
        self.hi, self.lo = hi, lo
        self.frames = list(frames)      # parity-good flags per RX frame
        self.start_delay = start_delay
        self.inter_delay = inter_delay
        self.tx_start_delay = tx_start_delay
        # wire / invariant log (one entry per peer call = per core tick)
        self.wire = []                  # pins_phys (1 tick stale, uniform)
        self.drv_log = []               # (pin_drv, pdir, pmode)
        # RX sender state
        self.state = "idle"             # idle, rx_high, rx_low, inter,
                                        # tx_wait_rise, tx_high, tx_low, done
        self.high_run = 0
        self.timer = 0
        self.bits = []
        self.bit_idx = 0
        self.frames_sent = 0
        # TX receiver state
        self.clk_low_run = 0
        self.low_run_start = None
        self.rts_cycle = None           # DATA fall cycle inside inhibit run
        self.inhibit_start = None
        self.tx_bits = []               # DATA sampled at clocks 0..10
        self.ack_driven = False
        self.tx_clock = 0
        self.prev_clk = 1
        self.prev_data = 1

    # -- helpers ------------------------------------------------------
    def _frame_bits(self, good_parity):
        p = odd_parity_bit(RX_BYTE)
        if not good_parity:
            p ^= 1
        return [0] + [(RX_BYTE >> i) & 1 for i in range(8)] + [p, 1]

    def _set_data(self, sim, bit):
        sim.peer_drv[DATA] = 0 if bit == 0 else None

    def _start_frame(self, sim):
        good = self.frames[self.frames_sent]
        self.bits = self._frame_bits(good)
        self.bit_idx = 0
        self._set_data(sim, self.bits[0])   # set DATA while CLK high
        self.timer = self.hi
        self.state = "rx_high"

    # -- per-cycle callback -------------------------------------------
    def __call__(self, sim):
        phys = sim.pins_phys
        self.wire.append(phys)
        self.drv_log.append((sim.pin_drv, sim.pdir, sim.pmode))
        clk = (phys >> CLK) & 1
        data = (phys >> DATA) & 1
        # default: release everything unless a state below drives
        sim.peer_drv[CLK] = None
        sim.peer_drv[DATA] = None

        # ---- inhibit / RTS tracking (always) ----
        if clk == 0:
            if self.prev_clk == 1:
                self.low_run_start = sim.cycle
            self.clk_low_run += 1
        else:
            if self.prev_clk == 0 and self.state == "tx_armed":
                # CLK released after RTS: start clocking shortly
                self.timer = self.tx_start_delay
                self.state = "tx_wait"
            self.clk_low_run = 0
            self.low_run_start = None
        if (self.prev_data == 1 and data == 0 and clk == 0
                and self.clk_low_run >= 100 and self.state == "idle_done"):
            # DATA fall while CLK held low, after frames done = RTS
            self.rts_cycle = sim.cycle
            self.inhibit_start = self.low_run_start
            self.state = "tx_armed"

        # ---- state machine ----
        if self.state == "idle":
            if clk == 1 and data == 1:
                self.high_run += 1
                if self.high_run >= self.start_delay and self.frames:
                    self._start_frame(sim)
            else:
                self.high_run = 0
        elif self.state == "rx_high":
            self._set_data(sim, self.bits[self.bit_idx])
            self.timer -= 1
            if self.timer <= 0:
                sim.peer_drv[CLK] = 0       # falling edge (host samples)
                self.timer = self.lo
                self.state = "rx_low"
        elif self.state == "rx_low":
            self._set_data(sim, self.bits[self.bit_idx])
            sim.peer_drv[CLK] = 0
            self.timer -= 1
            if self.timer <= 0:
                self.bit_idx += 1
                if self.bit_idx >= len(self.bits):
                    self.frames_sent += 1
                    if self.frames_sent < len(self.frames):
                        self.timer = self.inter_delay
                        self.state = "inter"
                    else:
                        self.state = "idle_done"
                else:
                    self._set_data(sim, self.bits[self.bit_idx])
                    self.timer = self.hi
                    self.state = "rx_high"
        elif self.state == "inter":
            self.timer -= 1
            if self.timer <= 0:
                self._start_frame(sim)
        elif self.state == "idle_done":
            pass                            # RTS watch handled above
        elif self.state == "tx_armed":
            pass                            # waiting for CLK release
        elif self.state == "tx_wait":
            self.timer -= 1
            if self.timer <= 0:
                self.tx_clock = 0
                self.timer = self.hi
                self.state = "tx_high"
        elif self.state == "tx_high":
            self.timer -= 1
            if self.timer <= 0:
                # falling edge: device samples DATA now (stale phys is
                # the value from just before the fall -- the bit the
                # host presented during the high phase)
                if self.tx_clock < 11:
                    self.tx_bits.append(data)
                sim.peer_drv[CLK] = 0
                if self.tx_clock == 11:
                    sim.peer_drv[DATA] = 0  # ACK bit: DATA low, 12th clock
                    self.ack_driven = True
                self.timer = self.lo
                self.state = "tx_low"
        elif self.state == "tx_low":
            sim.peer_drv[CLK] = 0
            if self.tx_clock == 11:
                sim.peer_drv[DATA] = 0      # hold ACK through the low phase
            self.timer -= 1
            if self.timer <= 0:
                self.tx_clock += 1
                if self.tx_clock >= 12:
                    self.state = "done"
                else:
                    self.timer = self.hi
                    self.state = "tx_high"

        self.prev_clk, self.prev_data = clk, data


ASM_PATH = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "..", "ps2", "ps2.asm"))
IMG = None
NWORDS = None
PEER = None


def build(sim):
    global IMG, NWORDS, PEER
    with open(ASM_PATH) as f:
        src = f.read()
    workdir = os.environ.get(
        "TB_WORKDIR",
        os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(tb.__file__)),
                                      "..", "tests", "out")))
    os.makedirs(workdir, exist_ok=True)
    IMG, NWORDS, _top = tb.assemble_src("ps2", src, workdir)
    sim.imem = IMG + [0] * (256 - len(IMG))
    PEER = PS2Keyboard()
    sim.host_push_rx_words([0x0001,          # receive frame 1 (good parity)
                            0x0001,          # receive frame 2 (bad parity)
                            0x0002, TX_BYTE,  # transmit 0xED
                            0x00FF])         # halt


def peer(sim):
    PEER(sim)


# ---------------------------------------------------------------- checker
def _clk_falls(wire):
    """Indices in wire[] where CLK goes 1 -> 0."""
    return [i for i in range(1, len(wire))
            if ((wire[i - 1] >> CLK) & 1) == 1 and ((wire[i] >> CLK) & 1) == 0]


def _decode_frame(wire, falls):
    """Sample DATA at each falling edge -> bit list."""
    return [(wire[i] >> DATA) & 1 for i in falls]


def _bits_to_byte(bits):
    b = 0
    for i, bit in enumerate(bits):
        b |= (bit & 1) << i
    return b


def check(sim):
    rep = []
    ok = True

    def A(cond, msg):
        nonlocal ok
        rep.append(("[PASS] " if cond else "[FAIL] ") + msg)
        ok = ok and bool(cond)

    A(NWORDS is not None and NWORDS <= 256,
      "image %s words (hard limit 256)" % NWORDS)
    A(sim.halted, "PE halted on 0x00FF (cycles=%d)" % sim.cycle)
    A(sim.warnings == [], "zero sim warnings (got %d)" % len(sim.warnings))
    A(not (sim.sticky & 0x1F),
      "no stickies set (sticky=0x%02X; TIMEOUT cleared by WAIT helpers)"
      % (sim.sticky & 0x1F))

    # ---- firmware outputs ----
    tx = sim.host_pop_tx_words()
    A(tx == [RX_BYTE, 0x0000, RX_BYTE, 0x0001, 0x0000],
      "TX words = %s (want [0x1C, 0x0000, 0x1C, 0x0001, 0x0000]: "
      "rx1 ok, rx2 parity-flagged, tx ACK ok)"
      % ["0x%04X" % w for w in tx])
    A(bool(sim.evtflag & 0x1), "EVT0 raised (evtflag=0x%04X)" % sim.evtflag)

    # ---- wire decode ----
    wire = PEER.wire
    falls = _clk_falls(wire)
    A(len(falls) == 35,
      "CLK falling edges on wire = %d (want 35 = 11 rx + 11 rx + 1 inhibit "
      "+ 12 tx clocks)" % len(falls))
    if len(falls) == 35:
        f1 = _decode_frame(wire, falls[0:11])
        f2 = _decode_frame(wire, falls[11:22])
        ftx = _decode_frame(wire, falls[23:35])

        # (a) frame 1: good parity 0x1C
        A(f1[0] == 0, "rx frame1 start bit == 0")
        A(_bits_to_byte(f1[1:9]) == RX_BYTE,
          "rx frame1 data == 0x%02X (wire-decoded 0x%02X)"
          % (RX_BYTE, _bits_to_byte(f1[1:9])))
        exp_p = odd_parity_bit(RX_BYTE)
        A(f1[9] == exp_p and (bin(RX_BYTE).count("1") + f1[9]) % 2 == 1,
          "rx frame1 parity bit == %d (odd parity correct)" % f1[9])
        A(f1[10] == 1, "rx frame1 stop bit == 1")

        # (a) frame 2: deliberately wrong parity; firmware must flag it
        A(_bits_to_byte(f2[1:9]) == RX_BYTE and f2[0] == 0 and f2[10] == 1,
          "rx frame2 start/data/stop intact (data 0x%02X)"
          % _bits_to_byte(f2[1:9]))
        A(f2[9] == (exp_p ^ 1) and (bin(RX_BYTE).count("1") + f2[9]) % 2 == 0,
          "rx frame2 parity bit == %d is WRONG on the wire (even total) "
          "-- and firmware status was 0x0001 (see TX words)" % f2[9])

        # (b) host->device frame, wire-decoded
        A(ftx[0] == 0, "tx frame start bit == 0 (request-to-send)")
        txb = _bits_to_byte(ftx[1:9])
        A(txb == TX_BYTE, "tx frame data == 0x%02X (wire-decoded 0x%02X)"
          % (TX_BYTE, txb))
        A(ftx[9] == odd_parity_bit(TX_BYTE)
          and (bin(TX_BYTE).count("1") + ftx[9]) % 2 == 1,
          "tx parity bit == %d (odd parity correct for 0xED)" % ftx[9])
        A(ftx[10] == 1, "tx frame stop bit == 1")
        A(ftx[11] == 0, "tx ACK bit == 0 on wire (device ACK, 12th clock)")
        A(PEER.tx_bits == ftx[0:11],
          "keyboard model falling-edge samples == wire decode %s" % PEER.tx_bits)
        A(PEER.ack_driven, "keyboard model drove the ACK bit")

        # (b) inhibit: CLK low run that contains the RTS DATA fall
        inh_fall = falls[22]
        j = inh_fall
        while j + 1 < len(wire) and ((wire[j + 1] >> CLK) & 1) == 0:
            j += 1
        run_len = j - inh_fall + 1
        # DATA fall inside the run (RTS)
        rts = None
        for i in range(inh_fall + 1, j + 1):
            if ((wire[i - 1] >> DATA) & 1) == 1 and ((wire[i] >> DATA) & 1) == 0:
                rts = i
                break
        A(rts is not None, "RTS found: DATA fell while CLK held low")
        if rts is not None:
            A(rts - inh_fall >= 5000,
              "inhibit: CLK low for %d cycles before RTS (spec >= 5000c = "
              "100 us)" % (rts - inh_fall))
        A(run_len >= 5000, "inhibit CLK-low run total = %d cycles" % run_len)

    # ---- open-drain invariant over the whole run ----
    viol = []
    for idx, (drv, pdir, pmode) in enumerate(PEER.drv_log):
        for pin in (CLK, DATA):
            od = (pmode >> (2 * pin + 1)) & 1
            en = (pdir >> pin) & 1
            dv = (drv >> pin) & 1
            if en and not od and dv:
                viol.append((idx, pin, "push-pull high drive"))
            if en and od and dv and False:
                pass  # dv=1 in OD mode = release (Hi-Z), by definition
    A(not viol,
      "open-drain invariant: PE never drove CLK/DATA high push-pull in "
      "%d logged cycles (violations: %s); highs come only from pull-ups"
      % (len(PEER.drv_log), viol[:3]))
    od_ok = all(((pm >> (2 * pin + 1)) & 1) == 1 and ((pm >> (2 * pin)) & 1) == 1
                for (drv, pdir, pm), pin in
                [(rec, p) for rec in PEER.drv_log[20:] for p in (CLK, DATA)]
                if (pdir >> pin) & 1)
    A(od_ok, "PMODE: pins 0/1 are {open_drain=1, pull_up=1} whenever driven")

    rep.append("---- measured ----")
    rep.append("  device clock: bit cell %d cycles = %.2f us -> %.2f kHz "
               "(spec 10.0-16.7 kHz)" % (CELL, CELL / 50.0, 50000.0 / CELL))
    rep.append("  golden run: %d cycles total (rx x2 + tx + halt)" % sim.cycle)
    rep.append("  image: %d words / 256" % NWORDS)
    return ok, "\n".join(rep)
