"""UART TX + RX test for Tarang-32 firmware/uart/uart.asm.

TEST={"name": "uart", "proto": "uart"}.

Main run (single sim): TX demo (4 bytes) -> RX demo (N=3: 2 good bytes +
a long break) -> peer pushes 0x00FF -> HLT.
Sub-tests inside check(): TX host-underrun (separate Sim), RX sampling
offset calibration (separate Sim, CAP vs peer-driven edge at known cycle).

Peer model: drives pin1 with exact 434-cycle bits (idle high); samples
pin0 mid-bit and reconstructs TX bytes. Deterministic, no randomness.

NOTE on break length: the firmware's specified break rule (two chained
tsel=1 waits for high, both timing out = 8192 cycles of low) cannot fire
on a 6000-cycle low (the rising edge lands inside the second window), so
the peer drives the break low for BREAK_LEN = 14000 cycles. See D2 in
uart.asm header.
"""
import os

import tb
from sim import Sim

TEST = {"name": "uart", "proto": "uart"}

BIT = 434
TX_BYTES = [0x55, 0xAA, 0x00, 0xFF]
RX_BYTES = [0xA5, 0x3C]
BREAK_LEN = 14000
RX_DELAY = 2000      # idle cycles after TX-done before RX byte 1 starts
CAL_EDGE = 3000      # calibration: wire-low cycle for the CAP experiment

_HERE = os.path.dirname(os.path.abspath(__file__))
SRC_PATH = os.path.normpath(os.path.join(_HERE, "..", "uart", "uart.asm"))
OUTDIR = os.environ.get(
    "TB_WORKDIR", os.path.normpath(os.path.join(_HERE, "out")))

with open(SRC_PATH) as f:
    UART_SRC = f.read()

peer_state = {}


def _rx_level(c):
    """pin1 wire level during cycle c (RX-phase schedule)."""
    st = peer_state
    t = c - st["rx_t0"]
    if t < 0:
        return 1
    framelen = len(RX_BYTES) * 10 * BIT
    if t < framelen:
        bitpos = t // BIT
        bytenum, bitidx = divmod(bitpos, 10)
        byte = RX_BYTES[bytenum]
        if bitidx == 0:
            return 0
        if bitidx == 9:
            return 1
        return (byte >> (bitidx - 1)) & 1
    if t < framelen + BREAK_LEN:
        return 0
    return 1


def peer(sim):
    st = peer_state
    c = sim.cycle
    # ---- drive pin1 ----
    if st["phase"] == "tx":
        sim.peer_drv[1] = 1
        if sim.evtflag & 0x01:          # TX demo done (evt 0)
            st["phase"] = "rx"
            st["rx_t0"] = c + RX_DELAY
    else:
        # drive the wire level for cycle c+1 (resolve happens end of tick)
        sim.peer_drv[1] = _rx_level(c + 1)
        if (sim.evtflag & 0x02) and not st["hlt_pushed"]:
            # RX demo aborted (evt 1); ask firmware to HLT
            st["hlt_pushed"] = True
            sim.rx_fifo.append(0x00FF)
    # ---- sample pin0 (TX): mid-bit reconstruction ----
    # Note: pins_phys is 0x00 at reset before the first resolve, so the very
    # first tick must not be mistaken for a falling edge: seed last_pin0
    # from tick 0 instead of assuming idle-high.
    cur = sim.pins_phys & 1
    last = st.get("last_pin0", None)
    if last is None:
        st["last_pin0"] = cur
        return
    if last == 1 and cur == 0 and not st.get("tx_sampling"):
        st["tx_sampling"] = True
        st["tx_bits"] = []
        st["tx_edge"] = c
        st["tx_next"] = c + BIT // 2
    if st.get("tx_sampling") and c == st["tx_next"]:
        st["tx_bits"].append(cur)
        st["tx_next"] += BIT
        if len(st["tx_bits"]) == 10:
            bits = st["tx_bits"]
            byte = 0
            for i in range(8):
                byte |= (bits[1 + i] << i)
            st["tx_bytes"].append(byte)
            st["tx_edges"].append(st["tx_edge"])
            st["tx_frames"].append(bits[0] == 0 and bits[9] == 1)
            st["tx_sampling"] = False
    st["last_pin0"] = cur


def build(sim):
    img, nwords, top = tb.assemble_src("uart", UART_SRC, OUTDIR)
    peer_state["nwords"] = nwords
    sim.imem = img + [0] * (256 - len(img))
    sim.host_push_rx_words([0x0001, len(TX_BYTES)] + TX_BYTES +
                           [0x0002, 3])
    peer_state.update(tx_bytes=[], tx_edges=[], tx_frames=[], phase="tx",
                      rx_t0=None, hlt_pushed=False)
    sim.pins_peer = peer


def _run_image(extra_rx_words, peer_fn, max_cycles):
    """Assemble uart.asm fresh and run a sub-test Sim."""
    s = Sim([0])
    img, _, _ = tb.assemble_src("uart", UART_SRC, OUTDIR)
    s.imem = img + [0] * (256 - len(img))
    s.host_push_rx_words(extra_rx_words)
    s.pins_peer = peer_fn
    s.run(max_cycles=max_cycles)
    return s


def check(sim):
    rep = []
    ok = True

    def A(cond, msg):
        nonlocal ok
        rep.append(("ok:   " if cond else "FAIL: ") + msg)
        if not cond:
            ok = False

    st = peer_state
    txw = sim.host_pop_tx_words()

    # ---- main run: TX ----
    A(st["tx_bytes"] == TX_BYTES,
      "TX bytes peer-reconstructed == %s (got %s)" %
      ([hex(b) for b in TX_BYTES], [hex(b) for b in st["tx_bytes"]]))
    A(all(st["tx_frames"]),
      "TX framing ok on all bytes (start=0, stop=1)")
    edges = st["tx_edges"]
    A(len(edges) == len(TX_BYTES),
      "%d TX start edges seen (want %d)" % (len(edges), len(TX_BYTES)))
    pitches = [b - a for a, b in zip(edges, edges[1:])]
    A(all(4340 <= p <= 4400 for p in pitches),
      "TX cycles/byte in [4340,4400]: %s (theory 4349)" % pitches)

    # ---- main run: RX + break ----
    # (tx_fifo also holds the TX demo's 0x0000 status word)
    A(txw == [0x0000] + RX_BYTES + [0xFFFE, 0xFFFF],
      "RX words == TX-status + bytes + BREAK + timeout-abort (got %s)" %
      [hex(w) for w in txw])
    A(bool(sim.evtflag & 0x04), "EVT 2 raised (break declared)")
    A(bool(sim.evtflag & 0x02), "EVT 1 raised (RX abort after resync)")
    A(bool(sim.evtflag & 0x01), "EVT 0 raised (TX demo completed)")
    A(sim.evtflag == 0x07, "evtflag == 0x07 (got %#x)" % sim.evtflag)
    A(len(sim.rx_fifo) == 0, "RX FIFO drained at end")
    A(sim.halted, "sim halted via peer-pushed 0x00FF")
    A(len(sim.warnings) == 0,
      "zero sim warnings (got %d)" % len(sim.warnings))
    for c, w in sim.warnings[:5]:
        rep.append("  warn @%d: %s" % (c, w))

    # ---- sub-test: TX host underrun (starved data) ----
    ud = {"hlt": False}

    def peer_ud(s):
        s.peer_drv[1] = 1
        if (s.evtflag & 0x01) and not ud["hlt"]:
            ud["hlt"] = True
            s.rx_fifo.append(0x00FF)

    s2 = _run_image([0x0001, 2, 0xAA], peer_ud, 300000)  # N=2, one data word
    w2 = s2.host_pop_tx_words()
    A(w2 == [0xFFFD],
      "TX underrun -> PUSH 0xFFFD, no hang (got %s)" % [hex(w) for w in w2])
    A(s2.halted, "underrun run halted")
    A(len(s2.warnings) == 0, "underrun run: zero warnings")

    # ---- sub-test: RX sampling-offset calibration ----
    # WAIT(level,low) return cycle R vs a peer-driven falling edge at known
    # wire cycle k = CAL_EDGE-1. Firmware samples data-bit-1 at wire R+650;
    # ideal mid-bit is k+651.
    calsrc = ("pdir 0x01\npset 0x01\nwait 1, 0, level, 1, r0\n"
              "cap r1\npush r0\npush r1\nhlt\n")
    s3 = Sim([0])
    img3, _, _ = tb.assemble_src("uartcal", calsrc, OUTDIR)
    s3.imem = img3 + [0] * (256 - len(img3))

    def peer_cal(s):
        s.peer_drv[1] = 1 if s.cycle < CAL_EDGE - 1 else 0

    s3.pins_peer = peer_cal
    s3.run(max_cycles=20000)
    cw = s3.host_pop_tx_words()
    T0 = 2                       # pdir, pset precede the WAIT
    k = CAL_EDGE - 1             # wire falling edge at end of cycle k
    # T8 model: the WAIT base cycle ticks first, so the actual return cycle
    # is T0 + elapsed + 1 (elapsed counts from END of base cycle).
    R = T0 + cw[0] + 1           # WAIT returned at end of cycle R
    A(R == k + 2, "WAIT detection latency = 2 cycles (R=%d, k=%d)" % (R, k))
    A(cw[1] == R, "CAP ts == R (%d), independent confirmation" % R)
    offset = (R + 650) - (k + 651)
    A(offset == 1, "RX sampling offset vs ideal mid-bit = %+d cycle" % offset)
    rep.append("note: 2-byte back-to-back RX timing margin: firmware samples "
               "each bit at ideal mid-bit %+d cycle; bit cell = %d cycles, so "
               "margin is +/-%d cycles to the nearest bit edge. Both RX "
               "bytes decoded correctly with byte2's start edge immediately "
               "after byte1's stop bit (back-to-back)." %
               (offset, BIT, 217 - offset))
    rep.append("note: image = %d words (target <=150, hard 256)" %
               st["nwords"])
    rep.append("note: peer break = %d low cycles (brief D2: 6000-cycle break "
               "cannot satisfy the specified two-chained-4096 rule)" %
               BREAK_LEN)
    return ok, "\n".join(rep)
