"""TEMPO CAN 2.0A test: 1 Mbit/s bit-bang vs bus model + independent monitor.

TEST PLAN
  host: [0x0001, 0x123, 2, 0xFF, 0x00]  -> TX frame ID=0x123 DLC=2
        [0x0001, 0x7FF, 0]              -> TX frame ID=0x7FF DLC=0
                                           (all-ones ID: stuffing in ID)
        [0x0002, 0x155]                 -> arbitration test: bus model
                                           drives dominant during the first
                                           recessive ID bit cell (cell 3);
                                           firmware must lose, release bus,
                                           PUSH 0xFFA0
        [0x00FF]                        -> HLT
  bus model (peer): bus = dominant iff firmware TXD==0 OR peer drives
        dominant; peer drives pin1=bus each cycle. It tracks the frame
        (own de-stuffing bit counter) and drives dominant for the whole
        ACK slot cell of every frame; for frame #2 (0-based) it also
        drives dominant for the whole of ID cell 3 (first recessive ID
        bit of 0x155 = 0b00101010101).
  check: INDEPENDENT CAN monitor (written from the CAN spec below, shares
        no code with the firmware): syncs on each SOF edge in the recorded
        pin snapshots, reconstructs bits in 50-cycle cells, de-stuffs,
        parses fields, asserts ID/DLC/data == host args, recomputes
        CRC-15 (poly 0x4599, init 0) over the destuffed stream and
        compares with the on-wire CRC, asserts the stuff rule (no 6
        consecutive equal bits in SOF..CRC; a complement bit follows
        every run of 5), asserts ACK slot dominant while TXD recessive,
        asserts EOF/IFS recessive, asserts every bus-edge delta is an
        exact multiple of 50 cycles; for the arbitration frame asserts
        TXD recessive for every cycle from cell 4 on and status 0xFFA0.
"""
import os, sys

TOOLS = "/home/hatch/workspace/janestreet-pemu/firmware/tools"
sys.path.insert(0, TOOLS)
from sim import Sim
import tb

TEST = {"name": "can", "proto": "can"}

SRC_PATH = "/home/hatch/workspace/janestreet-pemu/firmware/can/can.asm"
TXD, RXD = 0, 1
BIT = 50

FRAMES = [  # (id, dlc, data) for the two 0x0001 commands
    (0x123, 2, [0xFF, 0x00]),
    (0x7FF, 0, []),
]
ARB_ID = 0x155
ARB_FRAME_IDX = 2          # 0-based frame index of the arbitration test
ARB_CELL = 3               # SOF=0, ID bits at cells 1..11; 0x155 MSB-first
                           # is 0,0,1,... -> first recessive ID bit = cell 3


class CANBus:
    """Bus + minimal receiver/arbitrator peer. Drives pin1 (RXD) = bus.

    ACK timing uses this peer's OWN bit tracker (sample mid-cell,
    de-stuff, count fields) -- it is a bus participant, not the checker:
    the checker in check() re-decodes everything from pin snapshots.
    """

    def __init__(self):
        self.prev_bus = 1
        self.state = "IDLE"      # IDLE, FRAME
        self.t0 = None
        self.frame_idx = -1
        self.next_sample = None  # cycle of next mid-cell sample
        self.raw_idx = 0         # raw cell index in current frame
        self.destuffed = 0       # destuffed bits counted
        self.run = 0
        self.last = None
        self.dlc = None
        self.ack_window = None   # (start, end) cycles of ACK cell
        self.arb_window = None
        self.frame_end = None

    def _start_frame(self, cyc):
        self.state = "FRAME"
        self.t0 = cyc
        self.frame_idx += 1
        self.next_sample = cyc + 25
        self.raw_idx = 0
        self.destuffed = 0
        self.run = 0
        self.last = None
        self.dlc = None
        self._dlc_bits = 0
        self.ack_window = None
        self.frame_end = cyc + 50 * 140   # generous upper bound
        if self.frame_idx == ARB_FRAME_IDX:
            self.arb_window = (cyc + ARB_CELL * BIT,
                               cyc + (ARB_CELL + 1) * BIT)
        else:
            self.arb_window = None

    def _sample(self, bus):
        """Process one mid-cell bus sample for ACK scheduling."""
        # de-stuff: a bit after a run of 5 equal bits is a stuff bit
        if self.run == 5:
            self.run = 1
            self.last = bus
            self.raw_idx += 1
            return
        if bus == self.last:
            self.run += 1
        else:
            self.run = 1
            self.last = bus
        self.destuffed += 1
        self.raw_idx += 1
        # DLC field ends at destuffed index 19 (SOF+11 ID+RTR+IDE+r0+4 DLC)
        if self.destuffed == 19:
            self.dlc = self._dlc_bits
        if self.dlc is not None:
            ack_destuffed = 19 + 8 * self.dlc + 15 + 1  # +CRC +delim
            if self.destuffed == ack_destuffed:
                nxt = self.raw_idx  # next raw cell index = ACK slot cell
                self.ack_window = (self.t0 + BIT * nxt,
                                   self.t0 + BIT * (nxt + 1))
                self.frame_end = self.t0 + BIT * (nxt + 13)

    # track DLC bits as they are sampled
    _dlc_bits = 0

    def __call__(self, sim):
        txd = (sim.pin_drv >> TXD) & 1 if (sim.pdir >> TXD) & 1 else 1
        cyc = sim.cycle
        peer_dom = False
        if self.ack_window and self.ack_window[0] <= cyc < self.ack_window[1]:
            peer_dom = True
        if self.arb_window and self.arb_window[0] <= cyc < self.arb_window[1]:
            peer_dom = True
        bus = 0 if (txd == 0 or peer_dom) else 1

        if self.state == "IDLE":
            if cyc >= 60 and self.prev_bus == 1 and bus == 0:
                self._start_frame(cyc)
        elif self.state == "FRAME":
            if cyc == self.next_sample:
                # capture DLC bits (destuffed idx 16..19, 1-based below)
                if self.run != 5 or True:
                    pass
                # sample BEFORE this cell's bit is processed: record the
                # raw bit for DLC extraction in _sample via hook below
                self._sample_with_dlc(bus)
                self.next_sample += BIT
            if cyc >= self.frame_end:
                self.state = "IDLE"
                self.ack_window = None
                self.arb_window = None
        self.prev_bus = bus
        sim.peer_drv[RXD] = bus

    def _sample_with_dlc(self, bus):
        # mirror _sample but capture DLC nibble (destuffed bits 15..18
        # 0-based: after SOF(0), ID(1-11), RTR(12), IDE(13), r0(14))
        is_stuff = (self.run == 5)
        if not is_stuff:
            idx = self.destuffed  # 0-based index of this destuffed bit
            if 15 <= idx <= 18:
                self._dlc_bits = (self._dlc_bits << 1) | bus
        self._sample(bus)


_bus = None


def peer(sim):
    _bus(sim)


def build(sim):
    global _bus
    with open(SRC_PATH) as f:
        src = f.read()
    workdir = os.environ.get("TB_WORKDIR",
                             "/home/hatch/workspace/janestreet-pemu/firmware/tests/out")
    img, nwords, top = tb.assemble_src("can", src, workdir)
    build.nwords = nwords
    sim.imem = img + [0] * (256 - len(img))
    words = []
    for (fid, dlc, data) in FRAMES:
        words += [0x0001, fid, dlc] + data
    words += [0x0002, ARB_ID]
    words += [0x00FF]
    sim.host_push_rx_words(words)
    _bus = CANBus()


# ---------------------------------------------------------------------------
# Independent CAN monitor (from the CAN 2.0A spec; no firmware code shared)
# ---------------------------------------------------------------------------

def crc15_can(bits):
    """CRC-15/CAN: poly 0x4599, init 0x0000, over a destuffed bit list."""
    crc = 0
    for b in bits:
        top = (crc >> 14) & 1
        crc = ((crc << 1) & 0x7FFF)
        if top ^ b:
            crc ^= 0x4599
    return crc


def monitor_frame(snaps, t0):
    """Decode one frame starting at snapshot-cycle t0 (first dominant
    snapshot of SOF). Returns dict of parsed fields + raw bit list."""
    by_cycle = {c: pins for (c, pc, pins, sync, ts) in snaps}

    def bus_at(cyc):
        # nearest snapshot at or before cyc
        if cyc in by_cycle:
            return (by_cycle[cyc] >> RXD) & 1
        cand = [c for c in by_cycle if c <= cyc]
        return (by_cycle[max(cand)] >> RXD) & 1

    def txd_at(cyc):
        if cyc in by_cycle:
            return (by_cycle[cyc] >> TXD) & 1
        cand = [c for c in by_cycle if c <= cyc]
        return (by_cycle[max(cand)] >> TXD) & 1

    raw = []
    k = 0
    while True:
        raw.append(bus_at(t0 + 25 + BIT * k))
        k += 1
        if k > 140:
            break
        # stop after IFS: 10 recessive cells after ACK delim detected in
        # parse stage; simple bound: if we have >= 60 bits and last 12
        # samples all recessive beyond a complete frame, stop in parse.
        if k >= 60 and all(b == 1 for b in raw[-12:]):
            break
    # de-stuff SOF..CRC region
    destuffed = []
    run = 0
    last = None
    stuff_positions = []
    i = 0
    crc_end_raw = None
    while i < len(raw):
        b = raw[i]
        if run == 5:
            # this raw bit must be a stuff bit (complement of last)
            stuff_positions.append((i, b, last))
            run = 1
            last = b
            i += 1
            continue
        destuffed.append(b)
        if b == last:
            run += 1
        else:
            run = 1
            last = b
        i += 1
        # destuffed layout: SOF(1) ID(11) RTR IDE r0 DLC(4) data CRC(15)
        if len(destuffed) >= 19:
            dlc = int("".join(str(x) for x in destuffed[15:19]), 2)
            total = 19 + 8 * dlc + 15
            if len(destuffed) == total:
                crc_end_raw = i  # raw index just past CRC field
                break
    dlc = int("".join(str(x) for x in destuffed[15:19]), 2)
    data_bits = destuffed[19:19 + 8 * dlc]
    data = []
    for j in range(dlc):
        data.append(int("".join(str(x) for x in data_bits[8 * j:8 * j + 8]), 2))
    crc_wire = int("".join(str(x) for x in destuffed[19 + 8 * dlc:34 + 8 * dlc]), 2)
    rest = raw[crc_end_raw:] if crc_end_raw is not None else []
    return {
        "t0": t0, "raw": raw, "destuffed": destuffed,
        "sof": destuffed[0],
        "id": int("".join(str(x) for x in destuffed[1:12]), 2),
        "rtr": destuffed[12], "ide": destuffed[13], "r0": destuffed[14],
        "dlc": dlc, "data": data, "crc_wire": crc_wire,
        "crc_calc": crc15_can(destuffed[:19 + 8 * dlc]),
        "stuff": stuff_positions, "crc_end_raw": crc_end_raw,
        "rest": rest, "bus_at": bus_at, "txd_at": txd_at,
    }


def check(sim):
    errs = []
    rep = []
    snaps = sim.vcd_signals

    if sim.warnings:
        errs.append(f"{len(sim.warnings)} sim warnings (want 0)")
        for c, w in sim.warnings[:5]:
            rep.append(f"  warn @{c}: {w}")
    if not sim.halted:
        errs.append("PE did not halt on 0x00FF")
    else:
        rep.append(f"PE halted after {sim.cycle} cycles")
    if sim.sticky & 0x06:
        errs.append(f"FIFO stickies set: {sim.sticky & 0x06:#04x}")

    # bus edges + frame starts (SOF falling edges after >=10 recessive)
    edges = []
    prev = 1
    rise_cyc = -10000   # startup: bus idles recessive "forever" before t=0
    sof_starts = []
    for (cyc, pc, pins, sync, ts) in snaps:
        bus = (pins >> RXD) & 1
        if prev == 1 and bus == 0:
            edges.append(cyc)
            # SOF only if bus was recessive >= 400 cycles (mid-frame
            # recessive runs are <= 6 cells = 300 cycles by stuffing);
            # cyc >= 60 skips the power-on transient in the pin log
            if cyc >= 60 and cyc - rise_cyc >= 400:
                sof_starts.append(cyc)
        elif prev == 0 and bus == 1:
            edges.append(cyc)
            rise_cyc = cyc
        prev = bus
    bad_deltas = []
    if sof_starts:
        edges = [e for e in edges if e >= sof_starts[0]]
    sof_set = set(sof_starts)
    for a, b in zip(edges, edges[1:]):
        if b in sof_set:
            continue  # inter-frame gap (command decode) is not a bit cell
        d = b - a
        if d % BIT != 0:
            bad_deltas.append((a, d))
    if bad_deltas:
        errs.append(f"bus edge deltas not multiples of 50: {bad_deltas[:8]}")
    else:
        rep.append(f"bus edges: {len(edges)}, all deltas exact multiples "
                   f"of 50 cycles")

    if len(sof_starts) != 3:
        errs.append(f"found {len(sof_starts)} SOF edges, want 3")
        rep.append(f"SOF starts: {sof_starts}")
        ok = False
        return ok, "\n".join(rep + ["ERRORS:"] + errs)

    frames = [monitor_frame(snaps, t0) for t0 in sof_starts]

    # --- frames 1-2: full decode ------------------------------------------------
    for fi, (want_id, want_dlc, want_data) in enumerate(FRAMES):
        f = frames[fi]
        tag = f"frame{fi}"
        if f["sof"] != 0:
            errs.append(f"{tag}: SOF != 0")
        if f["id"] != want_id:
            errs.append(f"{tag}: ID {f['id']:#05x} != {want_id:#05x}")
        if (f["rtr"], f["ide"], f["r0"]) != (0, 0, 0):
            errs.append(f"{tag}: RTR/IDE/r0 = {f['rtr']}/{f['ide']}/{f['r0']}")
        if f["dlc"] != want_dlc:
            errs.append(f"{tag}: DLC {f['dlc']} != {want_dlc}")
        if f["data"] != want_data:
            errs.append(f"{tag}: data {f['data']} != {want_data}")
        if f["crc_wire"] != f["crc_calc"]:
            errs.append(f"{tag}: CRC wire {f['crc_wire']:#06x} != "
                        f"recomputed {f['crc_calc']:#06x}")
        # stuff rule: every stuff bit must be complement of run bit, and
        # de-stuffing above only succeeds if runs never exceed 5 in the
        # stuffed region; also explicitly verify no 6-in-a-row in raw
        raw_reg = f["raw"][:f["crc_end_raw"]]
        run = 1
        for a, b in zip(raw_reg, raw_reg[1:]):
            run = run + 1 if b == a else 1
            if run >= 6:
                errs.append(f"{tag}: 6-in-a-row in SOF..CRC raw stream")
                break
        for (pos, bit, last) in f["stuff"]:
            if bit == last:
                errs.append(f"{tag}: stuff bit at raw {pos} not complement")
        # ACK slot: first rest bit is CRC delim, second is ACK slot
        if len(f["rest"]) < 12:
            errs.append(f"{tag}: only {len(f['rest'])} post-CRC cells")
        else:
            if f["rest"][0] != 1:
                errs.append(f"{tag}: CRC delimiter not recessive")
            if f["rest"][1] != 0:
                errs.append(f"{tag}: ACK slot not dominant")
            ack_txd = f["txd_at"](f["t0"] + 25 + BIT * (f["crc_end_raw"] + 1))
            if ack_txd != 1:
                errs.append(f"{tag}: TXD not recessive during ACK slot")
            if f["rest"][2] != 1:
                errs.append(f"{tag}: ACK delimiter not recessive")
            if any(b != 1 for b in f["rest"][3:13]):
                errs.append(f"{tag}: EOF/IFS not all recessive")
        rep.append(f"monitor {tag}: ID={f['id']:#05x} DLC={f['dlc']} "
                   f"data={[hex(d) for d in f['data']]} "
                   f"CRC wire={f['crc_wire']:#06x} recomputed="
                   f"{f['crc_calc']:#06x} stuff_bits={len(f['stuff'])} "
                   f"ACK=dominant EOF/IFS=recessive")

    # --- frame 3: arbitration -----------------------------------------------------
    f = frames[2]
    t0 = f["t0"]
    # firmware TXD must be recessive for every snapshot from cell 4 start
    txd_bad = [cyc for (cyc, pc, pins, sync, ts) in snaps
               if cyc >= t0 + 4 * BIT and cyc < t0 + 30 * BIT
               and ((pins >> TXD) & 1) == 0]
    if txd_bad:
        errs.append(f"arb: firmware TXD dominant after loss: {txd_bad[:6]}")
    else:
        rep.append("monitor arb: TXD recessive for all cycles from cell 4 "
                   "on (no dominant drive after arbitration loss)")
    if f["id"] != ARB_ID:
        rep.append(f"monitor arb: partial ID decoded as {f['id']:#05x} "
                   f"(frame aborted early, decode is best-effort)")
    # abort latency: resolve the 'abort' label via the assembler directly
    abort_pc = None
    try:
        from asm import Assembler, load_isa
        from sim import YAML_PATH
        with open(SRC_PATH) as fh:
            src = fh.read()
        _asm = Assembler(load_isa(YAML_PATH))
        _words, _listing, labels = _asm.assemble(src)
        abort_pc = labels["abort"]
    except Exception as e:
        rep.append(f"abort-pc lookup failed: {e}")
    if abort_pc is not None:
        dec = [cyc for (cyc, pc, pins, sync, ts) in snaps
               if pc == abort_pc and cyc > t0]
        if dec:
            sample_cyc = t0 + ARB_CELL * BIT + 20
            rep.append(f"arb latency: sample@{sample_cyc} abort-pc first "
                       f"seen @{dec[0]} -> decision {dec[0] - sample_cyc} "
                       f"cycles after sample point, "
                       f"{t0 + (ARB_CELL + 1) * BIT - dec[0]} cycles before "
                       f"next bit cell")
        else:
            errs.append("arb: abort PC never reached")
    else:
        rep.append("arb: abort PC not found in listing (latency unmeasured)")

    tx_words = sim.host_pop_tx_words()
    want_tx = [0x0000, 0x0000, 0xFFA0]
    if tx_words != want_tx:
        errs.append(f"TX words {[hex(w) for w in tx_words]} != "
                    f"want {[hex(w) for w in want_tx]}")
    else:
        rep.append("TX words OK: [ack-status 0, ack-status 0, arb 0xFFA0]")

    rep.append(f"firmware size: {getattr(build, 'nwords', '?')} words / 256")
    ok = not errs
    report = "\n".join(rep + (["ERRORS:"] + errs if errs else []))
    return ok, report
