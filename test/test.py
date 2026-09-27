# SPDX-FileCopyrightText: © 2026 Prasad Pandit
# SPDX-License-Identifier: Apache-2.0
#
# test.py -- Tiny Tapeout template test, wired to the real tt_um_pemu design.
#
# STANDALONE: this test exercises the chip end-to-end through its documented
# interfaces only (pin map from src/tt_um_pemu.v, host-port protocol from
# isa_v0.2.yaml `host_port` + the 2-wire physical framing documented in
# src/tt_um_pemu_host.v, SPI firmware behavior from firmware/spi/spi.asm).
# It shares no code with tb_pe/tb_host/tb_observer/tb_top, test/cosim, or
# test/formal: our benches prove design correctness, this test proves
# TT integration/packaging correctness (pin mapping, clock/reset, tb.v wiring).
#
# What it does:
#   1. reset, check hp_tx idles high
#   2. autobaud sync (0x00), RD_STATUS in PROG mode (expect tx_empty only)
#   3. LOAD_IMEM the SPI firmware image, VERIFY_IMEM readback vs the .hex
#   4. GO, RD_STATUS shows PE_RUNNING
#   5. WR_RXFIFO the single-word HALT firmware command (0x00FF); RD_STATUS
#      must show PE_HALTED (proves the firmware command path end to end)
#   6. WR_RXFIFO a TRANSFER command (2 bytes 0xA5, 0x3C) while halted, then
#      GO to wake the PE; capture the SPI transaction on uio pins
#      (SCLK=pin2, MOSI=pin3, CS#=pin5): expect one CS# pulse containing
#      exactly 16 SCLK rising edges with MOSI carrying 0xA5,0x3C MSB-first
#   7. RD_TXFIFO: the 3 result words (2 rx bytes + status) must be 0x0000
#      (MISO tied 0); every other TX word must be the firmware idle-loop
#      marker 0xFFFF
#
# Run: `make` (or `make -B`) in this directory.

from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

CLK_PERIOD_NS = 1000        # 1 MHz core clock; the host link is self-clocked
TBIT = 100                  # host bit period, in core clocks (spec clamp 16..4096)
TBIT_NS = TBIT * CLK_PERIOD_NS
ACK_OK = 0xA5
# Re-sync guard: the chip re-arms autobaud after 65535 high-idle core clocks.
RESYNC_IDLE_CLKS = 60000

PIN_SCLK, PIN_MOSI, PIN_CS = 2, 3, 5

# SPI firmware host command words (firmware/spi/spi.asm header)
CMD_TRANSFER = 0x0001
IDLE_TX_MARKER = 0xFFFF     # firmware idle loop PUSHes this for unknown commands


class HostPort:
    """Bit-bang driver for the 2-wire host port.

    Physical framing (per the host block's documented interface): UART-style
    10-bit frames, start(0) + 8 data bits LSB-first + stop(1). The first byte
    after reset -- and after >65535 core clocks of line idle -- must be 0x00;
    the chip measures its 9-bit-time low pulse to set its bit period.
    """

    def __init__(self, dut):
        self.dut = dut
        self.rxq = deque()
        self.last_tx_ns = 0

    async def _send_level(self, v, nclks):
        await FallingEdge(self.dut.clk)
        self.dut.ui_in.value = v
        await ClockCycles(self.dut.clk, nclks)

    async def send_byte(self, b):
        await self._send_level(0, TBIT)              # start bit
        for k in range(8):
            await self._send_level((b >> k) & 1, TBIT)
        await self._send_level(1, TBIT)              # stop bit
        self.last_tx_ns = get_sim_time("ns")

    async def sync(self):
        """Autobaud sync byte (0x00 NOP: no response expected)."""
        await self.send_byte(0x00)
        await ClockCycles(self.dut.clk, 20)

    async def _maybe_resync(self):
        idle_clks = (get_sim_time("ns") - self.last_tx_ns) / CLK_PERIOD_NS
        if idle_clks > RESYNC_IDLE_CLKS:
            self.dut._log.info(f"host idle {idle_clks:.0f} clocks: re-syncing autobaud")
            await self.sync()

    async def send_frame(self, cmd, payload):
        await self._maybe_resync()
        await self.send_byte(cmd)
        await self.send_byte(len(payload))
        for b in payload:
            await self.send_byte(b)

    async def rx_monitor(self):
        """Always-on receiver: catches every DUT byte, queued in order."""
        dut = self.dut
        while True:
            await FallingEdge(dut.hp_tx)              # scalar alias of uo_out[0] (see tb.v)
            await Timer(TBIT_NS * 1.5, unit="ns")    # bit0 center
            b = 0
            for k in range(8):
                b |= (int(dut.uo_out.value) & 1) << k
                await Timer(TBIT_NS, unit="ns")
            self.rxq.append(b)
            # no stop-bit wait: re-arm fast, like any UART receiver

    async def recv_byte(self, timeout_clks=30000):
        for _ in range(timeout_clks):
            if self.rxq:
                return self.rxq.popleft()
            await RisingEdge(self.dut.clk)
        raise TimeoutError("timed out waiting for a host-port response byte")

    async def expect_ack(self, what):
        b = await self.recv_byte()
        assert b == ACK_OK, f"{what}: expected ACK_OK (0xA5), got 0x{b:02X}"


async def pad_loopback(dut):
    """Model the TT pads: uio_in reflects driven outputs (uio_out & uio_oe).

    The SPI firmware's init does pset pin0=1 then pget r15 and requires
    r15 == 1 ("self-read pin", firmware header) -- without this loopback the
    firmware's R_ONE constant reads 0 and every empty-FIFO pull matches the
    TRANSFER compare, sending the PE into a pathological N=0-transfer loop.
    Undriven pins (incl. MISO=pin4) read 0.
    """
    while True:
        await RisingEdge(dut.clk)
        dut.uio_in.value = int(dut.uio_out.value) & int(dut.uio_oe.value)


class PinRecorder:
    """Record (uio_out, uio_oe) each clock until CS# completes one low pulse."""

    def __init__(self, dut):
        self.dut = dut
        self.samples = []
        self.saw_pulse = False
        self._done = False

    async def run(self):
        saw_low = False
        while not self._done:
            await RisingEdge(self.dut.clk)
            o = int(self.dut.uio_out.value)
            e = int(self.dut.uio_oe.value)
            self.samples.append((o, e))
            cs = (o >> PIN_CS) & 1 if (e >> PIN_CS) & 1 else 1
            if cs == 0:
                saw_low = True
            elif saw_low:
                self.saw_pulse = True
                self._done = True

    async def wait_done(self, timeout_clks=20000):
        for _ in range(timeout_clks):
            if self._done:
                return
            await RisingEdge(self.dut.clk)
        self._done = True
        raise TimeoutError("pin recorder timed out waiting for a CS# pulse")


def load_hex_words(path):
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                words.append(int(line, 16))
    return words


@cocotb.test()
async def test_project(dut):
    """TT template sim, wired to tt_um_pemu: host-load SPI firmware, verify
    the SPI transaction on the pins and the result words in the TX FIFO."""
    dut._log.info("TT template sim: testing tt_um_pemu through the host port")
    hp = HostPort(dut)
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    # ---- reset ----
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    assert (int(dut.uo_out.value) & 1) == 1, "hp_tx must idle high after reset"
    cocotb.start_soon(hp.rx_monitor())
    cocotb.start_soon(pad_loopback(dut))
    await ClockCycles(dut.clk, 5)    # let the loopback settle before autobaud

    # ---- autobaud sync, then RD_STATUS in PROG mode ----
    await hp.sync()
    await hp.send_frame(0x08, [])   # RD_STATUS, LEN=0
    await hp.expect_ack("RD_STATUS/prog")
    st = await hp.recv_byte()
    # status bits (isa_v0.2.yaml): {PE_RUNNING,PE_HALTED,TIMEOUT,TX_EMPTY,
    # RX_FULL,TRACE_WM,TRACE_FULL,CONFIG_ERR}; in PROG only TX_EMPTY is set.
    assert st == 0x10, f"RD_STATUS in PROG: expected 0x10, got 0x{st:02X}"
    dut._log.info("RD_STATUS in PROG = 0x10 (tx_empty) as specified")

    # ---- LOAD_IMEM the SPI firmware ----
    words = load_hex_words("hex/spi.hex")
    assert len(words) > 0, "spi.hex is empty"
    dut._log.info(f"loading SPI image: {len(words)} words")
    payload = [0x00, 0x00]          # addr[15:8], addr[7:0]
    for w in words:
        payload += [(w >> 24) & 0xFF, (w >> 16) & 0xFF,
                    (w >> 8) & 0xFF, w & 0xFF]
    await hp.send_frame(0x01, payload)   # LOAD_IMEM
    await hp.expect_ack("LOAD_IMEM")

    # ---- VERIFY_IMEM readback must match the image bit-exact ----
    await hp.send_frame(0x02, [0x00, 0x00, len(words)])
    await hp.expect_ack("VERIFY_IMEM")
    for i, want in enumerate(words):
        got = 0
        for _ in range(4):
            got = (got << 8) | await hp.recv_byte()
        assert got == want, \
            f"VERIFY_IMEM word {i}: expected 0x{want:08X}, got 0x{got:08X}"
    dut._log.info(f"VERIFY_IMEM: all {len(words)} words match the image")

    # ---- GO: PE starts; status must show PE_RUNNING ----
    await hp.send_frame(0x09, [])   # GO, LEN=0
    await hp.expect_ack("GO")
    await ClockCycles(dut.clk, 50)
    await hp.send_frame(0x08, [])
    await hp.expect_ack("RD_STATUS/run")
    st = await hp.recv_byte()
    assert st & 0x80, f"RD_STATUS after GO: PE_RUNNING not set (0x{st:02X})"
    assert not (st & 0x40), f"RD_STATUS after GO: PE_HALTED set (0x{st:02X})"
    dut._log.info(f"RD_STATUS after GO = 0x{st:02X} (PE running)")

    # ---- drain TX FIFO (firmware idle loop pushes 0xFFFF markers) ----
    await hp.send_frame(0x06, [32])  # RD_TXFIFO, max 32 bytes
    await hp.expect_ack("RD_TXFIFO/drain")
    n = await hp.recv_byte()
    for _ in range(n):
        await hp.recv_byte()
    dut._log.info(f"drained {n} TX bytes of idle-loop markers")

    # ---- HALT the PE via a real firmware command (single word: 0x00FF) ----
    # Single-word commands have no inter-word timing hazard; this also proves
    # the firmware command path works end to end through the host RX FIFO.
    await hp.send_frame(0x05, [0x00, 0xFF])
    await hp.expect_ack("WR_RXFIFO/halt")
    await ClockCycles(dut.clk, 200)  # let the PE pull the word and execute hlt
    await hp.send_frame(0x08, [])
    await hp.expect_ack("RD_STATUS/halted")
    st = await hp.recv_byte()
    assert st & 0x40, f"RD_STATUS after HALT cmd: PE_HALTED not set (0x{st:02X})"
    assert not (st & 0x80), \
        f"RD_STATUS after HALT cmd: PE_RUNNING still set (0x{st:02X})"
    dut._log.info(f"RD_STATUS after HALT cmd = 0x{st:02X} (PE halted by firmware)")

    # ---- drain TX FIFO so the transfer results are not dropped on full ----
    await hp.send_frame(0x06, [32])
    await hp.expect_ack("RD_TXFIFO/predrain")
    n = await hp.recv_byte()
    for _ in range(n):
        await hp.recv_byte()
    dut._log.info(f"pre-transfer drain: {n} TX bytes")

    # ---- pre-load the TRANSFER command while the PE is halted ----
    # INTEGRATION NOTE: the SPI firmware pulls multi-word command frames
    # back-to-back (~5 cycles apart), but the serial host delivers words
    # ~2000 core clocks apart. Sent while the PE runs, the N word has not
    # arrived when the firmware pulls it, so PULL returns 0 and the transfer
    # degenerates to N=0 (observed: 3-cycle CS# pulse, words consumed as
    # unknown -> 0xFFFF markers). Pre-loading while halted is the reliable
    # path; the race is reported separately.
    await hp.send_frame(0x05, [0x00, CMD_TRANSFER,
                               0x00, 0x02,
                               0x00, 0xA5, 0x00, 0x3C])
    await hp.expect_ack("WR_RXFIFO/xfer")

    # ---- start the pin recorder BEFORE waking the PE ----
    rec = PinRecorder(dut)
    cocotb.start_soon(rec.run())
    await hp.send_frame(0x09, [])   # GO: wake the PE, restart at PC=0
    await hp.expect_ack("GO/wake")
    await rec.wait_done(timeout_clks=20000)
    assert rec.saw_pulse, "CS# never asserted: no SPI transaction happened"
    samples = rec.samples

    # ---- analyze: one CS# pulse, 16 SCLK rising edges, MOSI = 0xA5,0x3C ----
    n_sclk_rise = 0
    mosi_bits = []
    prev_sclk, prev_cs = None, None
    for o, e in samples:
        if not (e >> PIN_CS) & 1:
            continue
        cs = (o >> PIN_CS) & 1
        if cs == 0:
            sclk = (o >> PIN_SCLK) & 1
            if prev_sclk == 0 and sclk == 1:
                n_sclk_rise += 1
                mosi_bits.append((o >> PIN_MOSI) & 1)
            prev_sclk = sclk
        prev_cs = cs
    assert n_sclk_rise == 16, \
        f"expected 16 SCLK rising edges in the CS# pulse, got {n_sclk_rise}"
    exp_bits = ([(0xA5 >> (7 - k)) & 1 for k in range(8)] +
                [(0x3C >> (7 - k)) & 1 for k in range(8)])
    assert mosi_bits == exp_bits, \
        f"MOSI bitstream mismatch: got {''.join(map(str, mosi_bits))}, " \
        f"expected {''.join(map(str, exp_bits))}"
    dut._log.info("SPI transaction on pins OK: 16 SCLK edges, MOSI=0xA5,0x3C MSB-first")

    # ---- RD_TXFIFO: 3 result words must be 0x0000; nothing else unexpected ----
    await hp.send_frame(0x06, [32])
    await hp.expect_ack("RD_TXFIFO/results")
    n = await hp.recv_byte()
    raw = [await hp.recv_byte() for _ in range(n)]
    txw = [(raw[i] << 8) | raw[i + 1] for i in range(0, n, 2)]
    for w in txw:
        assert w in (0x0000, IDLE_TX_MARKER), \
            f"unexpected TX FIFO word 0x{w:04X} (want 0x0000 results or 0xFFFF idle markers)"
    assert any(txw[i] == 0 and txw[i + 1] == 0 and txw[i + 2] == 0
               for i in range(len(txw) - 2)), \
        f"transaction result words (3x 0x0000) not found in TX FIFO: " \
        f"{[f'0x{w:04X}' for w in txw]}"
    dut._log.info("TX FIFO results OK: rx bytes + status = 0x0000, MISO=0 confirmed")

    dut._log.info("PASS: tt_um_pemu TT template simulation")
