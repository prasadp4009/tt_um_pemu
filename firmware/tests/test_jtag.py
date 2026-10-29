"""Tarang JTAG (IEEE 1149.1) master test: IDCODE read + BYPASS test vs a
faithful TAP-controller target model.

TEST PLAN
  host: [0x0001]            -> IDCODE read  (PUSH 0x0477, PUSH 0x1BA0)
        [0x0002]            -> BYPASS test  (PUSH 0x004A)
        [0x00FF]            -> HLT
  peer: 16-state TAP controller, 4-bit IR (capture 0b1101),
        opcode 0b0001 = IDCODE (TLR default), 0b1111 = BYPASS, any other
        opcode acts as BYPASS. DR = 32-bit IDCODE register
        (IDCODE = 0x1BA00477) or 1-bit bypass register (captures 0).
        TMS/TDI sampled on TCK rising edge, TDO changes on TCK falling
        edge, TDO driven (not Hi-Z) only in Shift-DR / Shift-IR.
  check (protocol-specific, wire-decoding):
        * re-walk the TAP state machine from the recorded pin history
          alone; every observed transition must be a legal 1149.1
          transition for the TMS value on the wire, a run of >=5 TMS=1
          clocks must land in Test-Logic-Reset, and the walk must end
          in Run-Test/Idle;
        * exactly 83 TCK rising edges total (1 boot R_ONE edge + 53 for
          the IDCODE command + 29 for the BYPASS command);
        * Shift-DR episodes on the wire: lengths 32 and 8 -- the 32-bit
          episode's TDO bits (sampled in the low phase before each
          rising edge, assembled LSB-first) == 0x1BA00477, its TDI == 0;
          the 8-bit episode's TDI == 0xA5 and its TDO == 0x4A (the TDI
          pattern delayed by the 1-bit bypass register, capture bit 0);
        * Shift-IR episodes: lengths 4 and 4, TDI == 0b0001 then
          0b1111, TDO == 0b1101 (IR capture pattern) both times;
        * TX FIFO words == [0x0477, 0x1BA0, 0x004A] (firmware PUSHed
          exactly what the wire carried);
        * target model's own bookkeeping agrees (IR latches [1, 15],
          DR episode lengths [32, 8], final state RTI);
        * TCK period: every rising->rising delta >= 25 cycles (the
          2 MHz bound) -- measured min reported; IDCODE Shift-DR deltas
          in {37, 38} per the cycle accounting in jtag.asm;
        * TCK idle low at end; pdir bit3 == 0 on EVERY sim cycle
          (firmware never drives TDO -> contention impossible);
        * zero sim warnings; PE halted; no FIFO stickies.
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim
import tb

TEST = {"name": "jtag", "proto": "jtag"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/jtag/jtag.asm"
IDCODE = 0x1BA00477
BYPASS_PATTERN = 0xA5
BYPASS_EXPECT = 0x4A          # [capture 0, TDI0..TDI6] assembled LSB-first
IR_CAPTURE = 0b1101

# pin bit positions
TCK, TMS, TDI, TDO = 0, 1, 2, 3

# 1149.1 TAP state machine: NEXT[state][tms] -> next state
NEXT = {
    "TLR":     {0: "RTI",     1: "TLR"},
    "RTI":     {0: "RTI",     1: "SEL_DR"},
    "SEL_DR":  {0: "CAP_DR",  1: "SEL_IR"},
    "CAP_DR":  {0: "SHIFT_DR", 1: "EXIT1_DR"},
    "SHIFT_DR": {0: "SHIFT_DR", 1: "EXIT1_DR"},
    "EXIT1_DR": {0: "PAUSE_DR", 1: "UPDATE_DR"},
    "PAUSE_DR": {0: "PAUSE_DR", 1: "EXIT2_DR"},
    "EXIT2_DR": {0: "SHIFT_DR", 1: "UPDATE_DR"},
    "UPDATE_DR": {0: "RTI",   1: "SEL_DR"},
    "SEL_IR":  {0: "CAP_IR",  1: "TLR"},
    "CAP_IR":  {0: "SHIFT_IR", 1: "EXIT1_IR"},
    "SHIFT_IR": {0: "SHIFT_IR", 1: "EXIT1_IR"},
    "EXIT1_IR": {0: "PAUSE_IR", 1: "UPDATE_IR"},
    "PAUSE_IR": {0: "PAUSE_IR", 1: "EXIT2_IR"},
    "EXIT2_IR": {0: "SHIFT_IR", 1: "UPDATE_IR"},
    "UPDATE_IR": {0: "RTI",   1: "SEL_IR"},
}


class JTAGTarget:
    """Faithful 1149.1 TAP target. Observes PE-driven TCK/TMS/TDI via
    sim.pin_drv/sim.pdir each cycle; drives TDO (pin3) or leaves it
    Hi-Z (None) outside the Shift states."""

    def __init__(self):
        self.state = "TLR"
        self.ir_op = 0b0001            # TLR default instruction: IDCODE
        self.ir_shift = 0
        self.dr_shift = 0
        self.dr_len = 32
        self.tdo = None
        self.prev_tck = 0
        self.ir_latches = []           # opcodes latched at Update-IR
        self.dr_episodes = []          # completed Shift-DR lengths
        self.ir_episodes = []          # completed Shift-IR lengths
        self._dr_cnt = 0
        self._ir_cnt = 0
        self.pdir_hist = []            # pdir on every cycle (contention audit)

    def __call__(self, sim):
        self.pdir_hist.append(sim.pdir)
        drv, pdir = sim.pin_drv, sim.pdir
        tck = (drv >> TCK) & 1 if (pdir >> TCK) & 1 else 0
        tms = (drv >> TMS) & 1 if (pdir >> TMS) & 1 else 0
        tdi = (drv >> TDI) & 1 if (pdir >> TDI) & 1 else 0

        if self.prev_tck == 0 and tck == 1:      # rising: sample, shift, move
            st = self.state
            if st == "CAP_DR":
                if self.ir_op == 0b0001:
                    self.dr_shift, self.dr_len = IDCODE, 32
                else:                            # BYPASS (or acts-as-BYPASS)
                    self.dr_shift, self.dr_len = 0, 1
            elif st == "SHIFT_DR":
                self.dr_shift = ((self.dr_shift >> 1) |
                                  (tdi << (self.dr_len - 1))) & \
                                 ((1 << self.dr_len) - 1)
                self._dr_cnt += 1
            elif st == "CAP_IR":
                self.ir_shift = IR_CAPTURE
            elif st == "SHIFT_IR":
                self.ir_shift = ((self.ir_shift >> 1) | (tdi << 3)) & 0xF
                self._ir_cnt += 1
            elif st == "UPDATE_IR":
                self.ir_op = self.ir_shift & 0xF
                self.ir_latches.append(self.ir_op)
            nxt = NEXT[st][tms]
            if st == "SHIFT_DR" and nxt != "SHIFT_DR":
                self.dr_episodes.append(self._dr_cnt)
                self._dr_cnt = 0
            if st == "SHIFT_IR" and nxt != "SHIFT_IR":
                self.ir_episodes.append(self._ir_cnt)
                self._ir_cnt = 0
            self.state = nxt
            if nxt == "TLR":
                self.ir_op = 0b0001
        elif self.prev_tck == 1 and tck == 0:    # falling: TDO changes here
            if self.state == "SHIFT_DR":
                self.tdo = self.dr_shift & 1
            elif self.state == "SHIFT_IR":
                self.tdo = self.ir_shift & 1
            else:
                self.tdo = None                  # Hi-Z outside Shift states

        self.prev_tck = tck
        sim.peer_drv[TDO] = self.tdo


_target = None


def peer(sim):
    _target(sim)


def build(sim):
    global _target
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("jtag", src, workdir)
    sim.imem = img + [0] * (256 - len(img))
    sim.host_push_rx_words([0x0001, 0x0002, 0x00FF])
    _target = JTAGTarget()


def _wire_events(snaps):
    """Decode TCK rising edges from recorded pin snapshots. Returns a list
    of dicts: cycle (commit cycle of the rising edge), tms/tdi (values on
    the wire at the rise), tdo (physical TDO during the low phase just
    before the rise = the previous snapshot's pins)."""
    events = []
    prev_pins = 0
    for (cyc, pc, pins, sync, ts) in snaps:
        if ((pins >> TCK) & 1) and not ((prev_pins >> TCK) & 1):
            events.append({
                "cycle": cyc - 1,
                "tms": (pins >> TMS) & 1,
                "tdi": (pins >> TDI) & 1,
                "tdo": (prev_pins >> TDO) & 1,
            })
        prev_pins = pins
    return events


def _episodes(events, walk, state_name):
    """Group consecutive events whose pre-transition state == state_name."""
    eps, cur = [], []
    for ev, (pre, post) in zip(events, walk):
        if pre == state_name:
            cur.append(ev)
        elif cur:
            eps.append(cur)
            cur = []
    if cur:
        eps.append(cur)
    return eps


def _assemble_lsb_first(events, key):
    v = 0
    for i, ev in enumerate(events):
        v |= (ev[key] & 1) << i
    return v


def check(sim):
    errs = []
    rep = []

    if sim.warnings:
        errs.append(f"{len(sim.warnings)} sim warnings (want 0)")
        for c, w in sim.warnings[:5]:
            rep.append(f"  warn @{c}: {w}")

    # ---- wire decode: re-walk the TAP from pin history alone ----------------
    events = _wire_events(sim.vcd_signals)
    state = "TLR"
    walk = []                     # (pre_state, post_state) per rising edge
    ones_run = 0
    reset_landings = 0
    for ev in events:
        nxt = NEXT[state][ev["tms"]]      # legal transition by table lookup
        walk.append((state, nxt))
        ev["pre"], ev["post"] = state, nxt
        if ev["tms"] == 1:
            ones_run += 1
            if ones_run >= 5:
                if nxt != "TLR":
                    errs.append(f"TMS=1 run of {ones_run} did not land in "
                                f"TLR (walk state {nxt})")
                else:
                    reset_landings += 1
        else:
            ones_run = 0
        state = nxt
    rep.append(f"wire walk: {len(events)} TCK rises, TAP transitions all "
               f"legal per 1149.1 table, {reset_landings} reset landings "
               f"in TLR, final wire state {state}")
    if state != "RTI":
        errs.append(f"wire walk final state {state}, want RTI")
    if len(events) != 83:
        errs.append(f"{len(events)} TCK rising edges, want 83 "
                    f"(1 boot + 53 IDCODE cmd + 29 BYPASS cmd)")

    # ---- Shift-DR episodes -----------------------------------------------------
    dr_eps = _episodes(events, walk, "SHIFT_DR")
    if [len(e) for e in dr_eps] != [32, 8]:
        errs.append(f"Shift-DR episode lengths {[len(e) for e in dr_eps]}, "
                    f"want [32, 8] (exactly 32 clocks for IDCODE, no extras)")
    else:
        rep.append("Shift-DR episodes: 32 clocks (IDCODE) + 8 clocks "
                   "(BYPASS), no extra clocks")
        idc_wire = _assemble_lsb_first(dr_eps[0], "tdo")
        if idc_wire != IDCODE:
            errs.append(f"wire IDCODE {idc_wire:#010x} != {IDCODE:#010x}")
        else:
            rep.append(f"wire-decoded IDCODE = {idc_wire:#010x} == target "
                       f"IDCODE (LSB-first, sampled pre-rise in low phase)")
        if _assemble_lsb_first(dr_eps[0], "tdi") != 0:
            errs.append("IDCODE Shift-DR TDI != 0")
        byp_tdi = _assemble_lsb_first(dr_eps[1], "tdi")
        byp_tdo = _assemble_lsb_first(dr_eps[1], "tdo")
        if byp_tdi != BYPASS_PATTERN:
            errs.append(f"BYPASS Shift-DR TDI {byp_tdi:#04x} != 0xA5")
        if byp_tdo != BYPASS_EXPECT:
            errs.append(f"BYPASS captured {byp_tdo:#04x} != want 0x4A "
                        f"(pattern delayed by 1-bit bypass register)")
        else:
            rep.append(f"BYPASS: TDI 0xA5 in, captured {byp_tdo:#04x} out "
                       f"== [capture 0 | TDI delayed 1 bit] -- IR+DR paths "
                       f"both proven")

    # ---- Shift-IR episodes -------------------------------------------------------
    ir_eps = _episodes(events, walk, "SHIFT_IR")
    if [len(e) for e in ir_eps] != [4, 4]:
        errs.append(f"Shift-IR episode lengths {[len(e) for e in ir_eps]}, "
                    f"want [4, 4]")
    else:
        ir0 = _assemble_lsb_first(ir_eps[0], "tdi")
        ir1 = _assemble_lsb_first(ir_eps[1], "tdi")
        cap0 = _assemble_lsb_first(ir_eps[0], "tdo")
        cap1 = _assemble_lsb_first(ir_eps[1], "tdo")
        if (ir0, ir1) != (0b0001, 0b1111):
            errs.append(f"Shift-IR TDI opcodes {ir0:#b}, {ir1:#b}, "
                        f"want 0b0001 (IDCODE), 0b1111 (BYPASS)")
        elif (cap0, cap1) != (IR_CAPTURE, IR_CAPTURE):
            errs.append(f"Shift-IR TDO capture {cap0:#b}, {cap1:#b}, "
                        f"want 0b1101 both")
        else:
            rep.append("Shift-IR: opcodes 0b0001 then 0b1111 shifted in, "
                       "capture pattern 0b1101 shifted out both times")

    # ---- firmware PUSHed results == what the wire carried ------------------------
    tx_words = sim.host_pop_tx_words()
    want_tx = [IDCODE & 0xFFFF, (IDCODE >> 16) & 0xFFFF, BYPASS_EXPECT]
    if tx_words != want_tx:
        errs.append(f"TX words {[hex(w) for w in tx_words]} != "
                    f"want {[hex(w) for w in want_tx]}")
    else:
        rep.append(f"TX words OK: IDCODE low=0x0477 high=0x1BA0, "
                   f"BYPASS captured=0x004A")

    # ---- target model bookkeeping agrees with the wire ---------------------------
    if _target.ir_latches != [0b0001, 0b1111]:
        errs.append(f"model IR latches {_target.ir_latches}, want [1, 15]")
    if _target.dr_episodes != [32, 8]:
        errs.append(f"model DR episodes {_target.dr_episodes}, want [32, 8]")
    if _target.state != "RTI":
        errs.append(f"model final state {_target.state}, want RTI")
    if not errs:
        rep.append("model bookkeeping agrees: IR latches [IDCODE, BYPASS], "
                   "DR episodes [32, 8], final state RTI")

    # ---- TCK timing ----------------------------------------------------------------
    rises = [ev["cycle"] for ev in events]
    deltas = [b - a for a, b in zip(rises, rises[1:])]
    if deltas and min(deltas) < 25:
        errs.append(f"TCK period below 25 cycles (2 MHz bound): "
                    f"min={min(deltas)}")
    elif dr_eps and len(dr_eps[0]) == 32:
        ep = dr_eps[0]
        ep_deltas = [b["cycle"] - a["cycle"] for a, b in zip(ep, ep[1:])]
        bad = [d for d in ep_deltas if d not in (37, 38)]
        if bad:
            errs.append(f"IDCODE Shift-DR period deviations: {bad[:8]} "
                        f"(want 37, 38 at word/final boundaries)")
        rep.append(f"TCK period: min={min(deltas)} max={max(deltas)} cycles "
                   f"overall; IDCODE Shift-DR 37c (1.35 MHz), 38c at the "
                   f"two setup boundaries; bound 25c (2 MHz) respected")

    # ---- idle + contention -----------------------------------------------------------
    final_pins = sim.vcd_signals[-1][2] if sim.vcd_signals else 0
    if (final_pins >> TCK) & 1:
        errs.append("TCK not idle-low at end")
    else:
        rep.append("TCK idle low at end")
    bad_pdir = [p for p in _target.pdir_hist if (p >> TDO) & 1]
    if bad_pdir:
        errs.append(f"pdir bit3 (TDO) set on {len(bad_pdir)} cycles -- "
                    f"firmware drove TDO!")
    else:
        rep.append(f"pdir bit3 == 0 on all {len(_target.pdir_hist)} cycles "
                   f"(TDO never driven by firmware, no contention)")

    # ---- clean halt ---------------------------------------------------------------------
    if not sim.halted:
        errs.append("PE did not halt on 0x00FF")
    else:
        rep.append(f"PE halted after {sim.cycle} cycles")
    if sim.sticky & 0x06:
        errs.append(f"FIFO stickies set: {sim.sticky & 0x06:#04x} "
                    f"(TX_OVERRUN/RX_UNDERRUN)")

    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
