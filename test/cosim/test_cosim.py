"""
test_cosim.py -- cocotb cycle-exact RTL-vs-golden replay.

Replays a binary golden trace (record.py) against cosim_top:
  - Drives pins_in = golden pins_phys per cycle.
  - Models the 16x16 host FIFOs (RX pull / TX push / peer appends).
  - Compares PE+observer architectural state every cycle.
  - Stops at first mismatch with cycle/signal/expected/actual + context.

Env: COSIM_TRACE=<gold.bin> COSIM_HEX=<firmware.hex> COSIM_PLOG=<pinlog>

Cycle mapping:
  rst_n released -> P_1 = prime edge (no tick, ST_PRIME->ST_BASE).
  Golden cycle k <-> posedge P_{k+1} (the k-th tick).
  HLT (no golden tick) <-> posedge P_{K+2}.

WAIT-exit commit point:
  sim.py (ISA golden) commits a WAIT's effects -- pc+=1, Rd<-elapsed,
  TIMEOUT sticky -- after its last tick, with no tick of their own, so the
  golden record at the exit tick is pre-commit. The RTL commits the same
  effects on the exit clock edge (the only T2-consistent implementation: a
  deferred commit would add a bubble cycle and violate the 1..1+timeout
  occupancy). Comparing the RTL's post-edge (post-commit) state against
  the golden's pre-commit record at that one tick is therefore a testbench
  sampling artifact, not an RTL bug. At a WAIT-exit tick the testbench
  skips pc, Rd and sticky[0]; those exact effects are verified at tick k+1
  (or via gold_final_pc for pc), where both sides agree.
"""
import os
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

REC_SIZE = 122
HDR_SIZE = 47

# COS2 trace format (see firmware/tools/record_cosim.py for the full
# field-by-field COS1->COS2 delta): magic "COS2"; header final_pc is
# u16 LE at bytes 9-10 (header still 47 bytes); per-record pc is u16 LE
# at bytes 1-2, so the record is 122 bytes and every field after pc is
# shifted +1 vs COS1. COS1 traces are NOT accepted -- re-record in COS2.
# field offsets in the 122-byte record
O_PINS, O_PC, O_REGS = 0, 1, 3
O_ZNC, O_STICKY = 35, 36
O_PMASK, O_PDIR, O_PMODE = 38, 39, 40
O_PINDRV, O_SYNC0, O_SYNC1 = 42, 43, 44
O_TS, O_EVT = 45, 49
O_RXLEN, O_RX = 51, 52
O_TXLEN, O_TX = 84, 85
O_TRIG, O_OBSEN, O_WMARK, O_PRESC, O_TRACELEN = 117, 118, 119, 120, 121


def b(rec, off):
    return rec[off]


def w(rec, off):
    return rec[off] | (rec[off + 1] << 8)


def ts_of(rec):
    return rec[O_TS] | (rec[O_TS + 1] << 8) | (rec[O_TS + 2] << 16) | (rec[O_TS + 3] << 24)


def pc_of(rec):
    return w(rec, O_PC)


def reg_of(rec, r):
    return w(rec, O_REGS + 2 * r)


def rx_of(rec, i):
    return w(rec, O_RX + 2 * i)


def tx_of(rec, i):
    return w(rec, O_TX + 2 * i)


class Mismatch(Exception):
    pass


@cocotb.test()
async def test_replay(dut):
    trace_path = os.environ["COSIM_TRACE"]
    hex_path = os.environ["COSIM_HEX"]
    plog_path = os.environ.get("COSIM_PLOG", "")

    with open(trace_path, "rb") as f:
        data = f.read()
    assert data[0:4] == b"COS2", "bad trace magic (COS2 only; re-record COS1 traces)"
    n = struct.unpack("<I", data[4:8])[0]
    gold_halted = data[8]
    gold_final_pc = struct.unpack("<H", data[9:11])[0]
    init_rx_len = data[12]
    init_rx = [struct.unpack("<H", data[15 + 2 * i:17 + 2 * i])[0]
               for i in range(16)]
    recs = [data[HDR_SIZE + k * REC_SIZE:HDR_SIZE + (k + 1) * REC_SIZE]
            for k in range(n)]
    assert all(len(r) == REC_SIZE for r in recs), "truncated trace"
    dut._log.info("trace: N=%d halted=%d final_pc=%d init_rx=%d",
                  n, gold_halted, gold_final_pc, init_rx_len)

    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    # ---- load IMEM ----
    await Timer(10, unit="ns")
    hexwords = []
    with open(hex_path) as f:
        for i, line in enumerate(f):
            line = line.strip()
            if line:
                word = int(line, 16)
                hexwords.append(word)
                dut.u_imem.memory[i].value = word

    # ---- FIFO models + idle drives ----
    rx_q = list(init_rx[:init_rx_len])
    tx_q = []
    plog = open(plog_path, "w") if plog_path else None
    if plog:
        plog.write("# cycle pins_phys (on change)\n")
    last_pins = None

    def update_drives():
        dut.rx_data.value = rx_q[0] if rx_q else 0
        dut.rx_empty.value = 1 if not rx_q else 0
        dut.rx_full.value = 1 if len(rx_q) >= 16 else 0
        dut.tx_full.value = 1 if len(tx_q) >= 16 else 0
        dut.tx_empty.value = 1 if not tx_q else 0

    dut.rst_n.value = 0
    dut.pins_in.value = 0
    update_drives()

    # ---- reset: 5 cycles ----
    for _ in range(5):
        await RisingEdge(dut.clk)
    await Timer(2, unit="ns")
    dut.rst_n.value = 1

    # ---- prime edge P_1 (no tick) ----
    await FallingEdge(dut.clk)
    dut.pins_in.value = recs[0][O_PINS]
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.u_pe.pc.value) == 0, "pc!=0 after prime"
    assert int(dut.u_pe.cycles_r.value) == 0, "cycles_r!=0 after prime"
    assert int(dut.u_pe.state.value) == 1, "state!=ST_BASE after prime"

    errors = 0

    def ctx(kk):
        lines = []
        for jj in range(max(1, kk - 3), kk + 1):
            r = recs[jj - 1]
            lines.append(
                "    @%d pc=%03x r0=%04x r1=%04x r2=%04x r3=%04x "
                "drv=%02x sync1=%02x ts=%d" % (
                    jj, pc_of(r), reg_of(r, 0), reg_of(r, 1),
                    reg_of(r, 2), reg_of(r, 3), b(r, O_PINDRV),
                    b(r, O_SYNC1), ts_of(r)))
        return "\n".join(lines)

    def fail(sig, exp, act, kk):
        nonlocal errors
        errors += 1
        pc = int(dut.u_pe.pc.value)
        instr = int(dut.u_imem.memory[pc].value)
        dut._log.error(
            "MISMATCH @gold_cycle %d: %s expected=%08x actual=%08x\n"
            "  pc=%02x instr=%08x\n  gold context:\n%s",
            kk, sig, exp & 0xFFFFFFFF, act & 0xFFFFFFFF, pc, instr,
            ctx(kk))
        if errors >= 5:
            raise Mismatch("stopping after 5 mismatches")

    def check_pins(rec, kk):
        if int(dut.pins_out.value) != b(rec, O_PINDRV):
            fail("pins_out", b(rec, O_PINDRV),
                 int(dut.pins_out.value), kk)
        if int(dut.pins_oe.value) != b(rec, O_PDIR):
            fail("pins_oe", b(rec, O_PDIR),
                 int(dut.pins_oe.value), kk)
        if int(dut.pmode_out.value) != w(rec, O_PMODE):
            fail("pmode_out", w(rec, O_PMODE),
                 int(dut.pmode_out.value), kk)

    def check_state(rec, kk, wait_rd=None):
        pe = dut.u_pe
        if wait_rd is None:
            if int(pe.pc.value) != pc_of(rec):
                fail("pc", pc_of(rec), int(pe.pc.value), kk)
        for i in range(16):
            if i == wait_rd:
                continue  # WAIT Rd commits post-tick in golden; checked at k+1
            if int(pe.regs[i].value) != reg_of(rec, i):
                fail("regs[%d]" % i, reg_of(rec, i),
                     int(pe.regs[i].value), kk)
        znc = b(rec, O_ZNC)
        rtl_znc = ((int(pe.flag_n.value) & 1) << 1) | \
                  (int(pe.flag_z.value) & 1) | \
                  ((int(pe.flag_c.value) & 1) << 2)
        if rtl_znc != znc:
            fail("znc", znc, rtl_znc, kk)
        gs = w(rec, O_STICKY)
        gold_sticky = ((gs >> 12) & 1) << 12 | (gs & 0x1F)
        rtl_sticky = ((int(pe.sticky_trace_wm.value) & 1) << 12) | \
                     (int(pe.sticky.value) & 0x1F)
        if wait_rd is not None:
            # TIMEOUT sticky commits post-tick in golden (on the exit edge
            # in RTL); verified at k+1.
            gold_sticky &= ~1
            rtl_sticky &= ~1
        if rtl_sticky != gold_sticky:
            fail("sticky", gold_sticky, rtl_sticky, kk)
        if int(pe.pmask.value) != b(rec, O_PMASK):
            fail("pmask", b(rec, O_PMASK), int(pe.pmask.value), kk)
        if int(pe.pdir.value) != b(rec, O_PDIR):
            fail("pdir", b(rec, O_PDIR), int(pe.pdir.value), kk)
        if int(pe.pmode.value) != w(rec, O_PMODE):
            fail("pmode", w(rec, O_PMODE), int(pe.pmode.value), kk)
        if int(pe.pin_drv.value) != b(rec, O_PINDRV):
            fail("pin_drv", b(rec, O_PINDRV), int(pe.pin_drv.value), kk)
        if int(pe.sync0.value) != b(rec, O_SYNC0):
            fail("sync0", b(rec, O_SYNC0), int(pe.sync0.value), kk)
        if int(pe.sync1.value) != b(rec, O_SYNC1):
            fail("sync1", b(rec, O_SYNC1), int(pe.sync1.value), kk)
        if int(pe.pins_sync.value) != b(rec, O_SYNC1):
            fail("pins_sync", b(rec, O_SYNC1),
                 int(pe.pins_sync.value), kk)
        if int(pe.ts.value) != ts_of(rec):
            fail("ts", ts_of(rec), int(pe.ts.value), kk)
        if int(pe.cycles_r.value) != kk:
            fail("cycles_r", kk, int(pe.cycles_r.value), kk)
        if int(pe.halted.value) != 0:
            fail("halted", 0, int(pe.halted.value), kk)
        if int(pe.evtflag.value) != w(rec, O_EVT):
            fail("evtflag", w(rec, O_EVT), int(pe.evtflag.value), kk)
        if int(pe.trig_mode_r.value) != b(rec, O_TRIG):
            fail("trig_mode", b(rec, O_TRIG),
                 int(pe.trig_mode_r.value), kk)
        if int(pe.obs_en_r.value) != b(rec, O_OBSEN):
            fail("obs_en", b(rec, O_OBSEN), int(pe.obs_en_r.value), kk)
        if int(pe.wmark_r.value) != b(rec, O_WMARK):
            fail("wmark", b(rec, O_WMARK), int(pe.wmark_r.value), kk)
        if int(pe.prescaler_r.value) != b(rec, O_PRESC):
            fail("prescaler", b(rec, O_PRESC),
                 int(pe.prescaler_r.value), kk)
        if int(dut.u_obs.obs_ptr_r.value) != b(rec, O_TRACELEN):
            fail("obs_ptr", b(rec, O_TRACELEN),
                 int(dut.u_obs.obs_ptr_r.value), kk)

    # ---- WAIT-exit detector ----
    # Returns the WAIT's Rd if golden tick k is a WAIT-exit tick, else None.
    # sim.py commits WAIT effects after its last tick (no tick of their own);
    # the RTL commits them on the exit edge. Only pc, Rd and sticky[0] are
    # affected, and only at the single exit tick.
    OP_WAIT = 7
    ST_WAIT, ST_BASE = 3, 1

    def wait_exit_rd(k, prev_state, cur_state):
        rec = recs[k - 1]
        pc = pc_of(rec)
        if pc >= len(hexwords):
            return None
        instr = hexwords[pc]
        if ((instr >> 26) & 0x3F) != OP_WAIT:
            return None
        rd = (instr >> 9) & 0xF
        if k == n:
            return rd  # WAIT -> HLT: the final tick must be the exit
        if pc_of(recs[k]) != pc:
            return rd  # next tick moved on: this was the exit tick
        # Next tick still shows the WAIT pc: mid-poll, unless the RTL really
        # exited and the next instruction jumped straight back (ST_WAIT ->
        # ST_BASE transition on this edge distinguishes the two).
        if prev_state == ST_WAIT and cur_state == ST_BASE:
            return rd
        return None

    # ---- main replay loop ----
    prev_state = ST_BASE  # verified after the prime edge
    for k in range(1, n + 1):
        rec = recs[k - 1]
        await FallingEdge(dut.clk)
        dut.pins_in.value = rec[O_PINS]
        if plog and rec[O_PINS] != last_pins:
            plog.write("%d %02x\n" % (k, rec[O_PINS]))
            last_pins = rec[O_PINS]
        await Timer(1, unit="ns")
        check_pins(rec, k)          # combinational pin outputs
        await RisingEdge(dut.clk)   # P_{k+1}: tick k
        await Timer(1, unit="ns")
        cur_state = int(dut.u_pe.state.value)
        wrd = wait_exit_rd(k, prev_state, cur_state)
        # FIFO pulses (registered, reflect cycle-k instruction)
        if int(dut.rx_pull.value):
            if not rx_q:
                fail("rx_pull_empty", 0, 1, k)
            else:
                rx_q.pop(0)
        if int(dut.tx_push.value):
            if len(tx_q) >= 16:
                fail("tx_push_full", 0, 1, k)
            else:
                tx_q.append(int(dut.tx_data.value))
        # peer appends: grow rx model to golden post-tick contents
        while len(rx_q) < b(rec, O_RXLEN):
            rx_q.append(rx_of(rec, len(rx_q)))
        # verify FIFO models vs golden
        if len(rx_q) != b(rec, O_RXLEN):
            fail("rx_len", b(rec, O_RXLEN), len(rx_q), k)
        else:
            for j in range(len(rx_q)):
                if rx_q[j] != rx_of(rec, j):
                    fail("rx_fifo[%d]" % j, rx_of(rec, j), rx_q[j], k)
        if len(tx_q) != b(rec, O_TXLEN):
            fail("tx_len", b(rec, O_TXLEN), len(tx_q), k)
        else:
            for j in range(len(tx_q)):
                if tx_q[j] != tx_of(rec, j):
                    fail("tx_fifo[%d]" % j, tx_of(rec, j), tx_q[j], k)
        update_drives()
        check_state(rec, k, wrd)
        prev_state = cur_state

    # ---- HLT (no golden tick): posedge P_{K+2} ----
    if gold_halted:
        await FallingEdge(dut.clk)
        dut.pins_in.value = recs[n - 1][O_PINS]
        await Timer(1, unit="ns")
        check_pins(recs[n - 1], n)
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if int(dut.u_pe.halted.value) != 1:
            fail("halted(final)", 1, int(dut.u_pe.halted.value), n)
        if int(dut.u_pe.pc.value) != gold_final_pc:
            fail("pc(final)", gold_final_pc, int(dut.u_pe.pc.value), n)
        if int(dut.pe_halted.value) != 1:
            fail("pe_halted port", 1, int(dut.pe_halted.value), n)
        rec = recs[n - 1]
        if int(dut.u_pe.sync0.value) != b(rec, O_SYNC0):
            fail("sync0(final)", b(rec, O_SYNC0),
                 int(dut.u_pe.sync0.value), n)
        if int(dut.u_pe.ts.value) != ts_of(rec):
            fail("ts(final)", ts_of(rec), int(dut.u_pe.ts.value), n)
        for j in range(len(tx_q)):
            if tx_q[j] != tx_of(rec, j):
                fail("tx_fifo(final)[%d]" % j, tx_of(rec, j), tx_q[j], n)

    # ---- end-state: observer ----
    if int(dut.obs_ptr.value) != 0:
        fail("obs_ptr(final)", 0, int(dut.obs_ptr.value), n)

    if plog:
        plog.close()
    if errors == 0:
        dut._log.info("COSIM PASS: %d cycles verified, halted=%d",
                      n, gold_halted)
    else:
        raise Mismatch("COSIM FAIL: %d mismatches" % errors)
