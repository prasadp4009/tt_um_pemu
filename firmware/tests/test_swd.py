"""TEMPO SWD master test: DP IDCODE read vs SWD target (DP) peer model.

TEST PLAN
  host: [0x0001] -> line reset (56 SWCLK with SWDIO=1) + DP IDCODE read
                    request + turnaround + ACK + 32-bit data + parity +
                    turnaround; PUSH ACK, IDCODE lo, IDCODE hi, parity_ok
        [0x00FF] -> HLT
  peer: SWD DP model. Detects line reset as a run of >=50 SWDIO=1 bits on
        SWCLK rising edges (the request start bit is itself a 1, so the
        model syncs on the first 0 after the run: that 0 is APnDP and the
        immediately preceding 1 was the start bit). Parses the 8-bit
        request on rising edges; asserts (raises) on a malformed request
        so firmware bugs fail the run, not just the checker. On a valid
        IDCODE read it waits one turnaround rising edge, then presents,
        on successive SWCLK falling edges: ACK OK (wire bits 1,0,0),
        IDCODE 0x2BA01477 LSB-first, the correct even-parity bit, then
        releases SWDIO.
  check: PROTOCOL-SPECIFIC, from the wire history alone (vcd snapshots +
        the peer's per-tick drive log): re-decode the whole transaction:
        >=50 reset ones (exact run = 56 reset + 1 start = 57 ones before
        the first 0), request wire bits == [1,0,1,0,0,1,0,1], turnaround
        lengths == 1 SWCLK with SWDIO undriven by BOTH sides, ACK wire
        bits == OK, data wire bits == 0x2BA01477, parity wire bit ==
        even parity of the data, firmware PUSH words == {ACK=1,
        0x1477, 0x2BA0, parity_ok=1}, NO contention at any tick (PE and
        target never drive SWDIO simultaneously), intra-phase SWCLK
        period == 32 cycles, total SWCLK rising edges == 102 decoded
        bits (+1 boot R_ONE rise), zero warnings, PE halted.
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim
import tb

TEST = {"name": "swd", "proto": "swd"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/swd/swd.asm"
IDCODE = 0x2BA01477

SWCLK, SWDIO = 0, 1

# expected wire bits, LSB-first order of transmission
REQ_BITS = [1, 0, 1, 0, 0, 1, 0, 1]           # start,APnDP,RnW,A2,A3,par,stop,park
ACK_BITS = [1, 0, 0]                          # OK, LSB-first
DATA_BITS = [(IDCODE >> i) & 1 for i in range(32)]
PARITY_BIT = bin(IDCODE).count("1") & 1       # even-parity bit = XOR of data


class SWDTarget:
    """SWD DP peer model. Drives SWDIO (pin1) during ACK/data/parity;
    observes PE drives via sim.pin_drv/sim.pdir each tick (same
    granularity contract as the SPI slave)."""

    def __init__(self):
        self.drive = None            # current SWDIO drive 0/1/None
        self.prev_clk = 0
        self.state = "reset"         # reset|request|turn1|drive|turn2|done
        self.ones_run = 0            # consecutive 1 bits seen on rises
        self.initial_one_run = 0     # run length at first 0 (reset+start)
        self.req_bits = []
        self.drive_queue = []
        self.turn_pe = None          # (pe_driving, peer_driving) at turn rises
        self.turn2_pe = None
        self.tick_log = []           # (cycle, pdir, pin_drv, peer_drive_pin1)
        self.rise_states = []        # state name at each counted rise

    def _line_swdio(self, sim):
        if (sim.pdir >> SWDIO) & 1:
            return (sim.pin_drv >> SWDIO) & 1
        if self.drive is not None:
            return self.drive
        return 0

    def __call__(self, sim):
        clk = (sim.pin_drv >> SWCLK) & 1   # SWCLK is always PE-driven here
        rise = (self.prev_clk == 0 and clk == 1)
        fall = (self.prev_clk == 1 and clk == 0)

        if fall and self.state == "drive":
            # present next target bit (ACK/data/parity), or release
            if self.drive_queue:
                self.drive = self.drive_queue.pop(0)
            else:
                self.drive = None
                self.state = "turn2"

        if rise:
            bit = self._line_swdio(sim)
            self.rise_states.append(self.state)
            if self.state == "reset":
                if bit == 1:
                    self.ones_run += 1
                else:
                    if self.ones_run >= 50:
                        # this 0 is APnDP; last 1 of the run was start
                        self.initial_one_run = self.ones_run
                        self.req_bits = [1, 0]
                        self.state = "request"
                    self.ones_run = 0
            elif self.state == "request":
                self.req_bits.append(bit)
                if len(self.req_bits) == 8:
                    if self.req_bits != REQ_BITS:
                        raise AssertionError(
                            f"SWD model: malformed request bits "
                            f"{self.req_bits} != {REQ_BITS}")
                    byte = sum(b << i for i, b in enumerate(self.req_bits))
                    if byte != 0xA5:
                        raise AssertionError(
                            f"SWD model: request byte {byte:#04x} != 0xA5")
                    # parity field check: bit5 must be XOR of bits1..4
                    par = self.req_bits[1] ^ self.req_bits[2] ^ \
                        self.req_bits[3] ^ self.req_bits[4]
                    if par != self.req_bits[5]:
                        raise AssertionError("SWD model: request parity bad")
                    self.state = "turn1"
            elif self.state == "turn1":
                self.turn_pe = ((sim.pdir >> SWDIO) & 1, self.drive)
                self.drive_queue = (ACK_BITS + DATA_BITS + [PARITY_BIT])
                self.state = "drive"
            elif self.state == "turn2":
                self.turn2_pe = ((sim.pdir >> SWDIO) & 1, self.drive)
                self.state = "done"

        self.prev_clk = clk
        sim.peer_drv[SWDIO] = self.drive
        self.tick_log.append((sim.cycle, sim.pdir, sim.pin_drv, self.drive))


_target = None


def peer(sim):
    _target(sim)


def build(sim):
    global _target
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("swd", src, workdir)
    sim.imem = img + [0] * (256 - len(img))
    sim.host_push_rx_words([0x0001, 0x00FF])
    _target = SWDTarget()


def _wire_bits(snaps):
    """Decode (commit_cycle, swdio_bit) at every SWCLK rising edge, plus
    (commit_cycle, ...) at every falling edge, from physical snapshots.
    Commit cycle = snapshot cycle - 1 (edges are made by 1-cycle pin
    instructions; see test_spi.py convention)."""
    rises, falls = [], []
    prev = 0
    for (cyc, pc, pins, sync, ts) in snaps:
        clk = (pins >> SWCLK) & 1
        pclk = (prev >> SWCLK) & 1
        if clk and not pclk:
            rises.append((cyc - 1, (pins >> SWDIO) & 1))
        elif pclk and not clk:
            falls.append((cyc - 1, (pins >> SWDIO) & 1))
        prev = pins
    return rises, falls


def check(sim):
    errs, rep = [], []

    if sim.warnings:
        errs.append(f"{len(sim.warnings)} sim warnings (want 0)")
        for c, w in sim.warnings[:5]:
            rep.append(f"  warn @{c}: {w}")

    rises, falls = _wire_bits(sim.vcd_signals)
    # first rise is the boot R_ONE SWCLK-high (SWDIO=0); drop it
    if not rises or rises[0][1] != 0:
        errs.append("first wire rise is not the boot R_ONE rise (SWDIO=0)")
        boot = []
    else:
        boot, rises = rises[:1], rises[1:]
        rep.append("boot R_ONE rise present (SWDIO=0), excluded from decode")
    bits = [b for (_, b) in rises]
    rep.append(f"SWCLK rising edges decoded: {len(bits)} "
               f"(+{len(boot)} boot)")

    # ---- full-transaction decode -------------------------------------------
    if len(bits) != 102:
        errs.append(f"decoded {len(bits)} SWCLK bits, want 102 "
                    f"(56 reset + 8 req + 1 turn + 3 ACK + 32 data + "
                    f"1 parity + 1 turn)")
    else:
        # initial run of ones: 56 reset + start bit = 57, then APnDP=0
        run = 0
        while run < len(bits) and bits[run] == 1:
            run += 1
        if run - 1 < 50:
            errs.append(f"line reset too short: {run-1} ones before start")
        if run != 57:
            errs.append(f"initial 1-run = {run}, want 57 (56 reset + start)")
        else:
            rep.append("line reset OK: 56 SWCLK with SWDIO=1 "
                       "(57 ones incl. request start bit, >= 50 required)")
        req = bits[56:64]
        if req != REQ_BITS:
            errs.append(f"request wire bits {req} != {REQ_BITS}")
        else:
            rep.append(f"request OK: wire bits {req} = start1 APnDP0 RnW1 "
                       f"A2=0 A3=0 parity1 stop0 park1 (byte 0xA5 LSB-first)")
        turn1_bit = bits[64]
        ack = bits[65:68]
        if ack != ACK_BITS:
            errs.append(f"ACK wire bits {ack} != OK {ACK_BITS}")
        else:
            rep.append(f"ACK OK: wire bits {ack} -> ACK value 1 (OK)")
        data_bits = bits[68:100]
        data = sum(b << i for i, b in enumerate(data_bits))
        if data != IDCODE:
            errs.append(f"data wire value {data:#010x} != IDCODE {IDCODE:#010x}")
        else:
            rep.append(f"data OK: 32 wire bits LSB-first = {data:#010x}")
        par = bits[100]
        if par != PARITY_BIT:
            errs.append(f"parity wire bit {par} != even parity {PARITY_BIT} "
                        f"of data")
        else:
            rep.append(f"parity OK: wire bit {par} == even parity of "
                       f"0x2BA01477 (popcount {bin(IDCODE).count('1')} even)")

    # ---- turnaround + contention -------------------------------------------
    if _target.turn_pe is None:
        errs.append("peer never saw turnaround-1 rising edge")
    elif _target.turn_pe != (0, None):
        errs.append(f"turnaround-1: PE_driving={_target.turn_pe[0]} "
                    f"peer_driving={_target.turn_pe[1]}, want (0, None)")
    else:
        rep.append("turnaround-1 OK: 1 SWCLK, SWDIO driven by neither side")
    if _target.turn2_pe is None:
        errs.append("peer never saw turnaround-2 rising edge")
    elif _target.turn2_pe != (0, None):
        errs.append(f"turnaround-2: PE_driving={_target.turn2_pe[0]} "
                    f"peer_driving={_target.turn2_pe[1]}, want (0, None)")
    else:
        rep.append("turnaround-2 OK: 1 SWCLK, SWDIO driven by neither side")
    contention = [(c, pd, pv) for (c, pd, drv, pv) in _target.tick_log
                  if ((pd >> SWDIO) & 1) and pv is not None]
    if contention:
        errs.append(f"SWDIO contention at {len(contention)} ticks, "
                    f"first {contention[:3]}")
    else:
        rep.append(f"no SWDIO contention in {len(_target.tick_log)} ticks "
                   f"(PE and target never drive simultaneously)")

    # ---- SWCLK period: intra-phase == 32 ------------------------------------
    if len(rises) == 102:
        cyc = [c for (c, _) in rises]
        def seg(name, i0, i1, want):
            bad = [(i, cyc[i + 1] - cyc[i]) for i in range(i0, i1)
                   if cyc[i + 1] - cyc[i] != want]
            if bad:
                errs.append(f"{name} SWCLK period deviations: {bad[:6]}")
            else:
                rep.append(f"{name}: SWCLK period {want}c x{i1 - i0} "
                           f"(32c = 1.5625 MHz at 50 MHz core)")
        seg("reset phase", 0, 55, 32)        # rises 0..55 within phase
        seg("request phase", 56, 63, 32)
        # RX stream: ACK+data+parity are one clock stream; boundaries
        # between the firmware's rx_bits calls carry +6 setup cycles
        # (ret + result-store mov + count setup + call + mov/ldi init)
        rx_bad = []
        for i in range(65, 100):
            d = cyc[i + 1] - cyc[i]
            want = 38 if i in (67, 83, 99) else 32
            if d != want:
                rx_bad.append((i, d, want))
        if rx_bad:
            errs.append(f"RX stream period deviations: {rx_bad[:6]}")
        else:
            rep.append("RX stream (ACK+data+parity): period 32c, "
                       "38c at the 3 rx_bits call boundaries (+6 setup)")
        rep.append(f"total SWCLK cycles (rises) == decoded bits == "
                   f"{len(rises)}")

    # ---- PUSHed results -------------------------------------------------------
    tx_words = sim.host_pop_tx_words()
    want_tx = [0x0001, 0x1477, 0x2BA0, 0x0001]
    if tx_words != want_tx:
        errs.append(f"TX words {[hex(w) for w in tx_words]} != want "
                    f"{[hex(w) for w in want_tx]} (ACK, IDCODE lo, hi, "
                    f"parity_ok)")
    else:
        rep.append(f"PUSH words OK: ACK=0x0001 IDCODE_lo=0x1477 "
                   f"IDCODE_hi=0x2BA0 parity_ok=1")

    if _target.req_bits != REQ_BITS:
        errs.append(f"peer parsed request {_target.req_bits} != {REQ_BITS}")
    if _target.state != "done":
        errs.append(f"peer final state {_target.state} != done")

    if not sim.halted:
        errs.append("PE did not halt on 0x00FF")
    else:
        rep.append(f"PE halted after {sim.cycle} cycles")
    if sim.sticky & 0x06:
        errs.append(f"FIFO stickies set: {sim.sticky & 0x06:#04x}")

    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
