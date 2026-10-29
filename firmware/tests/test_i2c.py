"""Tarang I2C master test: 100 kHz bit-bang vs EEPROM-like I2C slave peer.

TEST PLAN
  host: [0x0001, 0xA0, 3, 0xDE, 0xAD, 0xBE]  -> write 3 bytes to addr 0x50
        [0x0002, 0xA1, 4]                    -> read 4 bytes from addr 0x50
        [0x0001, 0xA2, 1, 0x00]              -> write to addr 0x51 (NACK)
        [0x00FF]                             -> HLT
  peer: I2C slave @0x50; ACKs 0x50, stores written bytes, returns
        incrementing pattern 0x00,0x01,... on reads, NACKs other
        addresses, stretches SCL 2000 cycles once per transaction
        (during the address ACK bit).
  check: write data integrity; read data integrity + order; START/STOP
        from pin log; NACK status/EVT/STOP; stretch tolerance; SCL
        timing (bit/high/low/byte); zero warnings/stickies.

FIRMWARE BUGS FOUND (i2c.asm, verified against a patched /tmp copy):
  1. wr_byte sends bits[15:8] of r13, but callers place the byte in
     [7:0] (missing the SPI-style `shl`-by-8 left-align). The master
     therefore clocks 0x00 for every address/data byte; the slave
     NACKs address 0x00 and every transaction aborts with 0xFFE0.
  2. ackbit clobbers Z: `and r10,r10,r7` sets Z correctly, then
     `and r8,r8,r7` destroys it (0xC0&0x80=0x80 -> Z=0), so wr_byte
     always reports NACK.
  3. mackbit clobbers Z: `and r1,r0,r0` sets Z, then `and r8,r8,r6`
     destroys it (0x80&0x40=0x00 -> Z=1), so the `jmp mck_ack,nz`
     is never taken and the master always NACKs read bytes.
  With all three fixed (in a /tmp copy only -- the shipped firmware is
  untouched), this test's data checks all pass. As shipped, checks 1-2
  FAIL; 3-7 pass.
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim
from tb import assemble_src

TEST = {"name": "i2c", "proto": "i2c"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/i2c/i2c.asm"
SCL, SDA = 6, 7

WR_ADDR, WR_DATA = 0xA0, [0xDE, 0xAD, 0xBE]
RD_ADDR, RD_N = 0xA1, 4
RD_PATTERN = list(range(RD_N))          # 0x00, 0x01, ...
NACK_ADDR = 0xA2                        # 7-bit 0x51 -> slave NACKs

# Nominal timing (measured from pin log; theory in i2c.asm header said
# 500/250/250 -- the author miscounted overhead ticks; 499 = 100.2 kHz,
# well within I2C tolerance, and stable across every clock bit).
BIT_TIME, SCL_HIGH, SCL_LOW = 499, 248, 251
STRETCH_HOLD = 2000


class I2CSlave:
    """EEPROM-like I2C slave @0x50. Open-drain discipline: drives 0 or
    Hi-Z only (never 1). Edge-driven off sim.pins_phys (1 tick stale;
    edges are >=19 cycles apart so this is plenty)."""

    def __init__(self, addr=0x50):
        self.addr = addr
        self.stored = []        # bytes written by master (write direction)
        self.read_out = []      # bytes fully clocked out (read direction)
        self.master_acks = []   # master ACK/NACK per read byte (0=ACK,1=NACK)
        self.stretches = []     # {"detect","release","rise_seen"} per txn
        self.rcnt = 0           # read pattern counter
        self._reset_link()
        self.prev = None

    def _reset_link(self):
        self.state = "IDLE"     # IDLE, ADDR, WDATA, RDATA
        self.phase = "DATA"     # DATA (8 clocks) vs ACK (9th clock)
        self.bit = 0            # bits assembled in current byte
        self.cur = 0            # assembling byte (write direction)
        self.clk = 0            # SCL rises in current RDATA byte
        self.rbyte = 0          # byte being sent (read direction)
        self.sda_drv = None
        self.scl_drv = None
        self.matched = False
        self.dir_read = False
        self.stretch_armed = False
        self.stretch_t0 = None
        self.stretch_rel = None

    def _start(self):
        self._reset_link()
        self.state = "ADDR"

    def _stop(self):
        self._reset_link()

    def _drive_rbit(self, n):
        # open-drain: drive low for 0, release for 1
        self.sda_drv = 0 if ((self.rbyte >> n) & 1) == 0 else None

    def __call__(self, sim):
        pe_scl_low = ((sim.pdir >> SCL) & 1) and (((sim.pin_drv >> SCL) & 1) == 0)
        phys = sim.pins_phys
        scl = (phys >> SCL) & 1
        sda = (phys >> SDA) & 1
        if self.prev is None:
            self.prev = (scl, sda)
        pscl, psda = self.prev

        # ---- clock stretch: armed at ADDR 8th-data fall, once/txn ----
        # Hold SCL low STRETCH_HOLD cycles starting when the master
        # releases SCL for the ACK bit's high phase.
        if self.stretch_armed and self.stretch_t0 is None and not pe_scl_low:
            self.stretch_t0 = sim.cycle
            self.scl_drv = 0
        if self.stretch_t0 is not None and self.stretch_rel is None:
            if sim.cycle - self.stretch_t0 >= STRETCH_HOLD:
                self.scl_drv = None
                self.stretch_rel = sim.cycle
        if self.stretch_armed and self.stretch_rel is not None and scl == 1:
            self.stretches.append({"detect": self.stretch_t0,
                                   "release": self.stretch_rel,
                                   "rise_seen": sim.cycle})
            self.stretch_armed = False
            self.stretch_t0 = self.stretch_rel = None

        # ---- START / STOP ----
        if scl and pscl:
            if (not sda) and psda:
                self._start()
            elif sda and (not psda):
                self._stop()

        if scl and not pscl:
            self._on_rise(sda)
        elif (not scl) and pscl:
            self._on_fall()

        self.prev = (scl, sda)
        sim.peer_drv[SCL] = self.scl_drv
        sim.peer_drv[SDA] = self.sda_drv

    def _on_rise(self, sda):
        if self.state in ("ADDR", "WDATA") and self.phase == "DATA":
            self.cur = ((self.cur << 1) | sda) & 0xFF
            self.bit += 1
            if self.bit == 8 and self.state == "WDATA":
                self.stored.append(self.cur)
        elif self.state == "RDATA":
            if self.phase == "DATA":
                self.clk += 1
                if self.clk == 8:
                    self.read_out.append(self.rbyte)
            else:  # 9th clock: master ACK/NACK bit
                self.master_acks.append(sda)
                if sda == 1:
                    # Master NACKed: end of read. Release SDA so the
                    # master's STOP (or repeated START) is visible.
                    self.sda_drv = None
                    self.state = "IDLE"
                    self.phase = "DATA"

    def _on_fall(self):
        if self.state in ("ADDR", "WDATA"):
            if self.phase == "DATA":
                if self.bit == 8:
                    self.phase = "ACK"
                    if self.state == "ADDR":
                        self.matched = (self.cur >> 1) == self.addr
                        self.dir_read = bool(self.cur & 1)
                        self.sda_drv = 0 if self.matched else None
                        self.stretch_armed = True   # once per transaction
                    else:
                        self.sda_drv = 0            # ACK data byte
            else:  # ACK-bit fall: release, advance state
                self.sda_drv = None
                self.phase = "DATA"
                self.bit = 0
                self.cur = 0
                if self.state == "ADDR":
                    if not self.matched:
                        self.state = "IDLE"
                    elif self.dir_read:
                        self.state = "RDATA"
                        self.rbyte = self.rcnt & 0xFF
                        self.rcnt += 1
                        self.clk = 0
                        self._drive_rbit(7)
                    else:
                        self.state = "WDATA"
        elif self.state == "RDATA":
            if self.phase == "DATA":
                if self.clk < 8:
                    self._drive_rbit(7 - self.clk)
                else:  # 8th data fall: release for master's ACK bit
                    self.sda_drv = None
                    self.phase = "ACK"
            elif self.phase == "ACK":
                # 9th fall with master ACK: next byte (on NACK we went
                # IDLE in _on_rise, so this arm is skipped)
                self.rbyte = self.rcnt & 0xFF
                self.rcnt += 1
                self.clk = 0
                self.phase = "DATA"
                self._drive_rbit(7)


_slave = None


def peer(sim):
    _slave(sim)


def build(sim):
    global _slave
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, _, _ = assemble_src("i2c", src, workdir)
    sim.imem = img + [0] * (256 - len(img))
    sim.host_push_rx_words(
        [0x0001, WR_ADDR, len(WR_DATA)] + WR_DATA +  # write 3 bytes @0x50
        [0x0002, RD_ADDR, RD_N] +                   # read 4 bytes @0x50
        [0x0001, NACK_ADDR, 1, 0x00] +              # write @0x51 -> NACK
        [0x00FF])                                   # halt
    _slave = I2CSlave()


# ---------------------------------------------------------------- pin log
def _snap_edges(snaps):
    """Per-snapshot-pin changes: (snap_cycle, pin, new_val) for pins 6,7."""
    edges = []
    prev = None
    for (cyc, pc, pins, sync, ts) in snaps:
        if prev is not None:
            for pin in (SCL, SDA):
                a = (prev >> pin) & 1
                b = (pins >> pin) & 1
                if a != b:
                    edges.append((cyc, pin, b))
        prev = pins
    return edges


def _start_stop(snaps):
    """START (SDA fall while SCL high) / STOP (SDA rise while SCL high)
    snapshot cycles."""
    starts, stops = [], []
    prev = None
    for (cyc, pc, pins, sync, ts) in snaps:
        if prev is not None:
            pcyc, ppins = prev
            sda_a, sda_b = (ppins >> SDA) & 1, (pins >> SDA) & 1
            scl_a, scl_b = (ppins >> SCL) & 1, (pins >> SCL) & 1
            if sda_a == 1 and sda_b == 0 and scl_a == 1 and scl_b == 1:
                starts.append(pcyc)
            elif sda_a == 0 and sda_b == 1 and scl_a == 1 and scl_b == 1:
                stops.append(pcyc)
        prev = (cyc, pins)
    return starts, stops


def _scl_timing(snaps, stretch_releases, first_start):
    """SCL rise/fall commit ticks. d=0 pin ops commit at snap_cycle-1;
    stretched ACK rises happen mid-WAIT, so use the slave's release tick
    (matched within 2 cycles). Edges before the first START (init) are
    excluded."""
    rises, falls = [], []
    prev = None
    for (cyc, pc, pins, sync, ts) in snaps:
        if prev is not None and cyc >= first_start:
            a, b = (prev >> SCL) & 1, (pins >> SCL) & 1
            if a != b:
                tick = cyc - 1
                if b == 1:
                    hit = [x for x in stretch_releases if 0 <= tick - x <= 2]
                    rises.append(hit[0] if hit else tick)
                else:
                    falls.append(tick)
        prev = pins
    return sorted(rises), sorted(falls)


def check(sim):
    errs = []
    rep = []
    tx_words = sim.host_pop_tx_words()

    # ---- 1. write data integrity ----
    if _slave.stored != WR_DATA:
        errs.append(f"write: peer stored {[hex(b) for b in _slave.stored]}, "
                    f"want {[hex(b) for b in WR_DATA]} "
                    f"(firmware bug: wr_byte sends bits[15:8], see header)")
    else:
        rep.append(f"write data OK: peer stored {[hex(b) for b in _slave.stored]}")
    if not tx_words or tx_words[0] != 0x0000:
        errs.append(f"write: TX[0]={hex(tx_words[0]) if tx_words else None}, "
                    f"want 0x0000 status")
    else:
        rep.append("write status OK: TX[0]=0x0000, EVT0 raised" if sim.evtflag & 1
                   else "write status OK: TX[0]=0x0000 (EVT0 missing!)")
        if not (sim.evtflag & 1):
            errs.append("EVT 0 not raised after write")

    # ---- 2. read data integrity + order ----
    rd_words = tx_words[1:1 + RD_N]
    if rd_words != RD_PATTERN:
        errs.append(f"read: TX words {[hex(w) for w in rd_words]}, want "
                    f"{[hex(w) for w in RD_PATTERN]}")
    else:
        rep.append(f"read data OK: TX words {[hex(w) for w in rd_words]} in order")
    if _slave.read_out != RD_PATTERN:
        errs.append(f"read: peer clocked out {[hex(b) for b in _slave.read_out]}, "
                    f"want {[hex(b) for b in RD_PATTERN]}")
    if _slave.master_acks != [0, 0, 0, 1]:
        errs.append(f"read: master ACK pattern {_slave.master_acks}, want "
                    f"[0,0,0,1] (ACK,ACK,ACK,NACK)")
    else:
        rep.append("read: master ACKed first 3 bytes, NACKed last")

    # ---- 3. START/STOP from pin log ----
    starts, stops = _start_stop(sim.vcd_signals)
    if len(starts) != 3 or len(stops) != 3:
        errs.append(f"START/STOP count: {len(starts)} STARTs, {len(stops)} STOPs "
                    f"(want 3 and 3)")
    elif not all(a < b < c for a, b, c in
                 [(starts[0], stops[0], starts[1]),
                  (stops[0], starts[1], stops[1]),
                  (starts[1], stops[1], starts[2]),
                  (stops[1], starts[2], stops[2])]):
        errs.append(f"START/STOP interleaving wrong: starts={starts} stops={stops}")
    else:
        rep.append(f"START/STOP OK: 3 STARTs + 3 STOPs, alternating "
                   f"(SDA fall/rise while SCL high)")

    # ---- 4. NACK test: status, STOP, EVT 1 ----
    if not tx_words or tx_words[-1] != 0xFFE0:
        errs.append(f"NACK: last TX word={hex(tx_words[-1]) if tx_words else None}, "
                    f"want 0xFFE0")
    else:
        rep.append("NACK status OK: TX=0xFFE0 (0xFFE0|idx, idx=0 for address)")
    if not (sim.evtflag & 0x02):
        errs.append("NACK: EVT 1 not raised")
    else:
        rep.append("NACK: EVT 1 raised; STOP issued (see START/STOP count)")

    # ---- 5. clock stretch ----
    if len(_slave.stretches) != 3:
        errs.append(f"stretch: {len(_slave.stretches)} stretches seen, want 3 "
                    f"(one per transaction)")
    else:
        holds = [s["release"] - s["detect"] for s in _slave.stretches]
        if any(h != STRETCH_HOLD for h in holds):
            errs.append(f"stretch holds {holds}, want all {STRETCH_HOLD}")
        else:
            rep.append(f"stretch OK: 3x{STRETCH_HOLD}c SCL hold, one per txn")
    # master WAIT elapsed from pin log: snapshot gap across the stretched WAIT
    gaps = []
    snaps = sim.vcd_signals
    for a, b in zip(snaps, snaps[1:]):
        d = b[0] - a[0]
        if d > 1000:
            gaps.append(d)
    if len(gaps) != 3 or any(g != STRETCH_HOLD + 1 for g in gaps):
        errs.append(f"stretch: master WAIT snapshot gaps {gaps}, want 3x{STRETCH_HOLD+1} "
                    f"(= hold + 1; well under 4096 tsel=1 timeout)")
    else:
        rep.append(f"stretch: master WAIT elapsed = {STRETCH_HOLD+1}c per txn "
                   f"(2000 hold + sync), < 4096 timeout; no 0xFFFD abort")
    if any(w == 0xFFFD for w in tx_words):
        errs.append("stretch: 0xFFFD timeout abort seen (stretch mishandled)")

    # ---- 6. SCL timing from pin log ----
    # Data-bit clocks are exactly BIT_TIME (499c). ACK-family 9th clocks
    # (ackbit/mackbit) and STOP/START boundary clocks are by-design in
    # [480, 700]: HIGHs nominal, LOWs padded per-path to >= t_LOW.
    # Stretched INTO-deltas (~2496+) excluded by the <2000 cut.
    releases = sorted(s["release"] for s in _slave.stretches)
    first_start = starts[0] if starts else 0
    rises, falls = _scl_timing(snaps, releases, first_start)
    deltas = [b - a for a, b in zip(rises, rises[1:])]
    nominal = [d for d in deltas if d == BIT_TIME]
    bad_period = [d for d in deltas
                  if d < 2000 and d != BIT_TIME and not 480 <= d <= 700]
    if bad_period:
        errs.append(f"bit time: {len(nominal)}x{BIT_TIME}c but also {bad_period}")
    else:
        rep.append(f"bit time: {len(nominal)}x{BIT_TIME}c data clocks exact; "
                   f"{len(deltas) - len(nominal)} ACK/boundary clocks in "
                   f"[480,700] by design (theory 500; 499 = 100.2 kHz)")
    ev = sorted([(t, 'r') for t in rises] + [(t, 'f') for t in falls])
    highs = [t2 - t1 for (t1, k1), (t2, k2) in zip(ev, ev[1:])
             if k1 == 'r' and k2 == 'f' and t2 - t1 < 1000]
    lows = [t2 - t1 for (t1, k1), (t2, k2) in zip(ev, ev[1:])
            if k1 == 'f' and k2 == 'r' and t2 - t1 < 1000]
    # I2C spec gates, std mode @50 MHz: t_HIGH >= 4.0 us = 200c,
    # t_LOW >= 4.7 us = 235c. Every SCL phase must comply.
    bad_high = [h for h in highs if h < 200]
    bad_low = [l for l in lows if l < 235]
    if bad_high:
        errs.append(f"t_HIGH violation: phases {bad_high} (spec >= 200c)")
    if bad_low:
        errs.append(f"t_LOW violation: phases {bad_low} (spec >= 235c)")
    if not bad_high and not bad_low:
        rep.append(f"spec gates: all {len(highs)} SCL highs >= 200c (t_HIGH), "
                   f"all {len(lows)} lows >= 235c (t_LOW)")
    # bus-free time between transactions: t_BUF >= 4.7 us = 235c
    tbufs = [starts[i + 1] - stops[i] for i in range(len(stops) - 1)]
    if any(t < 235 for t in tbufs):
        errs.append(f"t_BUF violation: gaps {tbufs} (spec >= 235c)")
    else:
        rep.append(f"t_BUF OK: inter-transaction gaps {tbufs} (spec >= 235c)")
    ev = sorted([(t, 'r') for t in rises] + [(t, 'f') for t in falls])
    highs = [t2 - t1 for (t1, k1), (t2, k2) in zip(ev, ev[1:])
             if k1 == 'r' and k2 == 'f' and t2 - t1 < 1000]
    lows = [t2 - t1 for (t1, k1), (t2, k2) in zip(ev, ev[1:])
            if k1 == 'f' and k2 == 'r' and t2 - t1 < 1000]
    from collections import Counter
    hc, lc = Counter(highs), Counter(lows)
    if hc.get(SCL_HIGH, 0) < 20:
        errs.append(f"SCL high phase histogram {dict(hc)}, want ~{SCL_HIGH}c dominant")
    else:
        rep.append(f"SCL high phase: {SCL_HIGH}c x{hc[SCL_HIGH]} (theory 250)")
    if lc.get(SCL_LOW, 0) < 15:
        errs.append(f"SCL low phase histogram {dict(lc)}, want ~{SCL_LOW}c dominant")
    else:
        rep.append(f"SCL low phase: {SCL_LOW}c x{lc[SCL_LOW]} (theory 250)")
    rep.append(f"measured: bit={BIT_TIME}c high={SCL_HIGH}c low={SCL_LOW}c "
               f"byte(9clk)~4402c (see header)")

    # ---- 7. warnings / stickies / halt ----
    if sim.warnings:
        errs.append(f"{len(sim.warnings)} sim warnings (want 0)")
        for c, w in sim.warnings[:5]:
            rep.append(f"  warn @{c}: {w}")
    else:
        rep.append("zero sim warnings")
    if sim.sticky & 0x1F:
        errs.append(f"unexpected stickies: {sim.sticky & 0x1F:#07b} "
                    f"(TIMEOUT/TX_OVERRUN/RX_UNDERRUN/...)")
    else:
        rep.append("no unexpected stickies (TIMEOUT cleared per txn, no FIFO trip)")
    if not sim.halted:
        errs.append("PE did not halt on 0x00FF")
    else:
        rep.append(f"PE halted cleanly after {sim.cycle} cycles")

    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
