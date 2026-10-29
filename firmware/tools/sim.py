#!/usr/bin/env python3
"""Tarang-32 cycle-exact ISA simulator (golden model for the firmware phase).

Single-cycle, non-pipelined PE per isa_v0.2.yaml + ISA_v0.2.md timing
contract T1-T17. Decodes via the YAML (opcode -> field map), so the
simulator can never drift from the encoding contract.

Scope / deliberate model choices (documented, not spec):
  * WAIT samples the 2-FF synchronized pin vector (same as PGET/CAP).
  * WAIT elapsed > 0xFFFF truncates to Rd[15:0] with a logged warning.
    Overflow behavior is T17-OPEN -- firmware must not depend on it.
  * Observer commits same-cycle in sim (RTL bound is K<=6, F5).
  * CALL overflow / RET underflow: sim halts with an error (T10/T11 open).
  * Shift-by-0 leaves C unchanged.
  * Host WR_RXFIFO packs bytes MSB-first; odd trailing byte pads 0x00.
  * Undriven, no-pull pins resolve to 0.

Usage (library):
    from sim import Sim
    s = Sim(imem_words)
    s.host_push_rx_words([0x55])
    s.pins_peer = my_peer          # callable(sim) -> sets sim.peer_drv
    s.run(max_cycles=100000)
    s.vcd("out.vcd")
    s.host_pop_tx_words() ...
"""
import sys, os
import yaml

YAML_PATH = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "..", "..", "isa_v0.2.yaml"))

TSEL_TIMEOUT = {0: 256, 1: 4096, 2: 65536, 3: 1048576}
PRESCALER_DIV = {0: 1, 1: 16, 2: 256, 3: 4096}
FIFO_DEPTH = 16

# STATUS bit layout (from YAML status_bits)
ST_TIMEOUT, ST_TX_OVERRUN, ST_RX_UNDERRUN, ST_TRACE_FULL = 0, 1, 2, 3
ST_CONFIG_ERR = 4
ST_PE_RUNNING, ST_PE_HALTED = 8, 9
ST_TX_EMPTY, ST_RX_FULL = 10, 11
ST_TRACE_WM = 12
ST_CFG_DIRTY = 13

SREG_ADDR = {}   # name -> addr, filled from YAML


class SimHalt(Exception):
    pass


class Sim:
    def __init__(self, imem_words, yaml_path=YAML_PATH):
        with open(yaml_path) as f:
            self.isa = yaml.safe_load(f)
        self.idecode = {}
        for ins in self.isa["instructions"]:
            self.idecode[ins["number"]] = ins
        global SREG_ADDR
        for r in self.isa["special_registers"]["regs"]:
            if isinstance(r["addr"], int):
                SREG_ADDR[r["name"]] = r["addr"]

        self.imem = list(imem_words) + [0] * (512 - len(imem_words))
        self.reset()
        self.warnings = []
        self.log = []          # (cycle, text) event log
        self.vcd_signals = []  # per-cycle snapshots
        self.pins_peer = None  # callable(sim) run each cycle before resolution
        self.peer_drv = {}     # pin -> 0/1/None(Hi-Z)

    # ------------------------------------------------------------------
    def reset(self):
        self.pc = 0
        self.regs = [0] * 16
        self.z = self.n = self.c = 0
        self.sticky = 0        # TIMEOUT, TX_OVERRUN, RX_UNDERRUN, TRACE_FULL, CONFIG_ERR
        self.pmask = 0xFF
        self.pdir = 0x00       # all Hi-Z at reset (R-9)
        self.pmode = 0x0000
        self.pin_drv = 0x00
        self.sync0 = 0x00
        self.sync1 = 0x00
        self.pins_phys = 0x00
        self.ts = 0            # 32-bit timestamp (prescaled ticks)
        self.prescale_cnt = 0
        self.cycle = 0
        self.tx_fifo, self.rx_fifo = [], []
        self.evtflag = 0
        self.halted = False
        self.retstack = []
        # observer
        self.trig_mode = 0
        self.pin_sel = 0
        self.obs_mask = 0
        self.obs_value = 0
        self.edge_mask = 0
        self.edge_cfg0 = 0
        self.edge_cfg1 = 0
        self.wmark = 0
        self.prescaler = 0
        self.obs_en = False
        self.obs_arm = False
        self.trace = []        # list of (ts, pins)
        self.prev_sync = 0x00
        self.wait_prev = 0x00
        self._prev_sync0 = 0x00
        self._cts_hi = 0
        self._cts_pins = 0

    def warn(self, msg):
        self.warnings.append((self.cycle, msg))
        self.log.append((self.cycle, "WARN: " + msg))

    # ------------------------------------------------------------------
    # pin model
    # ------------------------------------------------------------------
    def resolve_pins(self):
        """Resolve physical pins from PE drivers, peer drivers, pull-ups."""
        phys = 0
        for i in range(8):
            pe_en = (self.pdir >> i) & 1
            od = (self.pmode >> (2 * i + 1)) & 1
            pu = (self.pmode >> (2 * i)) & 1
            pe_drive = None
            if pe_en:
                if od:
                    pe_drive = 0 if ((self.pin_drv >> i) & 1) == 0 else None
                else:
                    pe_drive = (self.pin_drv >> i) & 1
            peer = self.peer_drv.get(i, None)
            if pe_drive == 0 or peer == 0:
                v = 0
            elif pe_drive == 1 or peer == 1:
                v = 1
            elif pu:
                v = 1
            else:
                v = 0
            phys |= (v << i)
        self.pins_phys = phys

    # ------------------------------------------------------------------
    # end-of-cycle updates (run after each core cycle)
    # ------------------------------------------------------------------
    def end_of_cycle(self):
        if self.pins_peer is not None:
            try:
                self.pins_peer(self)
            except Exception as e:
                raise SimHalt(f"peer model raised: {e}")
        self.resolve_pins()
        self.sync0 = self.pins_phys
        # note: sync1 <= old sync0  (2-FF chain)
        new_sync1 = self._prev_sync0
        self._prev_sync0 = self.sync0
        self.sync1 = new_sync1
        # timestamp (prescaled)
        div = PRESCALER_DIV[self.prescaler & 3]
        self.prescale_cnt += 1
        if self.prescale_cnt >= div:
            self.prescale_cnt = 0
            self.ts = (self.ts + 1) & 0xFFFFFFFF
        self.observer_eval()
        self.cycle += 1
        self.prev_sync = self.sync1

    def snapshot(self):
        self.vcd_signals.append((self.cycle, self.pc, self.pins_phys,
                                 self.sync1, self.ts))

    # ------------------------------------------------------------------
    # observer
    # ------------------------------------------------------------------
    def observer_eval(self):
        if not self.obs_en or self.trig_mode == 0:
            return
        fire = False
        if self.trig_mode == 0b01:  # EDGE
            for i in range(8):
                if ((self.edge_mask >> i) & 1) == 0:
                    continue
                cfg = self.edge_cfg0 if i < 4 else self.edge_cfg1
                code = (cfg >> (2 * (i % 4))) & 3
                if code == 0:
                    continue
                now = (self.sync1 >> i) & 1
                was = (self.prev_sync >> i) & 1
                if code == 0b01 and now and not was:
                    fire = True
                elif code == 0b10 and not now and was:
                    fire = True
                elif code == 0b11 and now != was:
                    fire = True
        elif self.trig_mode == 0b10:  # PATTERN (level)
            if (self.sync1 & self.obs_mask) == (self.obs_value & self.obs_mask):
                fire = True
        elif self.trig_mode == 0b11:  # PULSE on pin_sel
            now = (self.sync1 >> self.pin_sel) & 1
            was = (self.prev_sync >> self.pin_sel) & 1
            if now and not was:
                fire = True  # commit + (re)arm
            elif not now and was:
                fire = True  # commit + disarm
        if fire:
            self.observer_commit()

    def observer_commit(self):
        if len(self.trace) >= 204:
            self.sticky |= (1 << ST_TRACE_FULL)
            return
        self.trace.append((self.ts, self.sync1))
        if self.wmark and len(self.trace) == self.wmark:
            self.sticky |= (1 << ST_TRACE_WM)

    # ------------------------------------------------------------------
    # special registers
    # ------------------------------------------------------------------
    def sreg_read(self, addr):
        if addr == 0x00:  # STATUS
            live = 0
            if not self.halted:
                live |= (1 << ST_PE_RUNNING)
            if self.halted:
                live |= (1 << ST_PE_HALTED)
            if not self.tx_fifo:
                live |= (1 << ST_TX_EMPTY)
            if len(self.rx_fifo) >= FIFO_DEPTH:
                live |= (1 << ST_RX_FULL)
            return (self.sticky & 0x1F) | live
        if addr == 0x01:
            return self.ts & 0xFFFF
        if addr == 0x02:
            return (self.ts >> 16) & 0xFFFF
        if addr == 0x03:
            return self._cts_hi
        if addr == 0x04:
            return self._cts_pins
        if addr == 0x05:
            return len(self.trace)
        if addr == 0x06:
            return self.pmask
        if addr == 0x07:
            return self.pdir
        if addr == 0x08:
            return self.pmode
        if addr == 0x09:
            return self.trig_mode
        if addr == 0x0A:
            return self.pin_sel
        if addr == 0x0B:
            return self.obs_mask
        if addr == 0x0C:
            return self.obs_value
        if addr == 0x0D:
            return self.edge_mask
        if addr == 0x0E:
            return self.edge_cfg0
        if addr == 0x0F:
            return self.edge_cfg1
        if addr == 0x10:
            return self.wmark
        if addr == 0x11:
            return self.prescaler
        if addr == 0x12:
            v = 0
            if self.obs_en:
                v |= 1
            if self.obs_arm:
                v |= 2
            return v  # bit2 strobe is self-clearing, reads 0
        if addr == 0x13:
            return self.evtflag
        return 0  # unallocated: read-as-zero (T5 default)

    def sreg_write(self, addr, val):
        val &= 0xFFFF
        if addr == 0x00:  # STATUS W1C
            self.sticky &= ~(val & 0x1F)
            return
        if addr == 0x09:  # TRIG_MODE: any write disarms
            self.trig_mode = val & 3
            self.obs_en = False
            return
        if addr == 0x0A:
            self.pin_sel = val & 7
            return
        if addr == 0x0B:
            self.obs_mask = val & 0xFF
            return
        if addr == 0x0C:
            self.obs_value = val & 0xFF
            return
        if addr == 0x0D:
            self.edge_mask = val & 0xFF
            return
        if addr == 0x0E:
            self.edge_cfg0 = val & 0xFF
            return
        if addr == 0x0F:
            self.edge_cfg1 = val & 0xFF
            return
        if addr == 0x10:
            self.wmark = val & 0xFF
            return
        if addr == 0x11:
            self.prescaler = val & 3
            return
        if addr == 0x12:
            if val & 4:  # OBS_CLR strobe
                self.trace = []
                self.sticky &= ~(1 << ST_TRACE_WM)
            if val & 1:
                self.obs_en = True
            if val & 2:
                self.obs_arm = True  # T4: semantics open; plain bit in sim
            return
        # RO / unallocated: writes ignored (T5 default)

    # ------------------------------------------------------------------
    # WAIT condition
    # ------------------------------------------------------------------
    def wait_cond(self, pin, pol, mode):
        v = (self.sync1 >> pin) & 1
        if mode == 0:  # level
            return v == pol
        pv = (self.wait_prev >> pin) & 1
        if mode == 1:  # rising
            return v and not pv
        if mode == 2:  # falling
            return (not v) and pv
        return v != pv  # either

    # ------------------------------------------------------------------
    # instruction execution: returns cycles consumed
    # ------------------------------------------------------------------
    def step(self):
        if self.halted:
            return 0
        if not (0 <= self.pc < 512):
            raise SimHalt(f"PC out of range: {self.pc}")
        word = self.imem[self.pc] & 0xFFFFFFFF
        op = (word >> 26) & 0x3F
        dly = (word >> 21) & 0x1F
        if op not in self.idecode:
            raise SimHalt(f"illegal opcode {op} at PC={self.pc} (T6 open; sim halts)")
        ins = self.idecode[op]
        name = ins["name"]
        F = {}
        for f in ins["fields"]:
            if f["name"] == "reserved":
                continue
            w = f["msb"] - f["lsb"] + 1
            F[f["name"]] = (word >> f["lsb"]) & ((1 << w) - 1)
        # WAIT/SLEEP/HLT must have zero delay (assembler enforces too)
        if ins["delay"] == "reserved_zero" and dly != 0:
            raise SimHalt(f"{name}: nonzero delay bits at PC={self.pc}")

        R = self.regs
        cycles = 1 + dly

        # ---- execute (effects commit at end of base cycle) ----
        if name == "PSET":
            self.pin_drv = (self.pin_drv & ~self.pmask) | (F["imm8"] & self.pmask)
        elif name == "PSETR":
            rs = R[F["rs"]]
            self.pin_drv = (self.pin_drv & ~self.pmask) | ((rs & 0xFF) & self.pmask)
        elif name == "PGET":
            R[F["rd"]] = self.sync1
        elif name == "PMASK":
            self.pmask = F["imm8"]
        elif name == "PDIR":
            self.pdir = F["imm8"]
        elif name == "PMODE":
            self.pmode = R[F["rs"]] & 0xFFFF
        elif name == "SLEEP":
            cycles = 1 + F["imm13"]
        elif name == "WAIT":
            cfg8 = F["cfg8"]
            pin = (cfg8 >> 5) & 7
            pol = (cfg8 >> 4) & 1
            mode = (cfg8 >> 2) & 3
            tsel = cfg8 & 3
            timeout = TSEL_TIMEOUT[tsel]
            rd = F["rd"]
            # T8: elapsed counts core cycles from END of base cycle. The base
            # cycle ticks first; the entry check then sees post-base-cycle
            # sync. Edge-at-entry compares against the pre-base sample, so a
            # just-arrived edge reads elapsed=0. In-loop: check FIRST, then
            # advance wait_prev -- otherwise pv==v and edges never fire.
            self.wait_prev = self.sync1  # pre-base-cycle sample
            self._tick_delay()           # end of base cycle
            if self.wait_cond(pin, pol, mode):
                R[rd] = 0
                cycles = 1
            else:
                self.wait_prev = self.sync1
                elapsed = None
                for e in range(1, timeout + 1):
                    self._tick_delay()
                    if self.wait_cond(pin, pol, mode):
                        elapsed = e
                        break
                    self.wait_prev = self.sync1
                if elapsed is None:  # timeout
                    self.sticky |= (1 << ST_TIMEOUT)
                    elapsed = timeout
                    self.log.append((self.cycle, f"WAIT timeout pin{pin} tsel{tsel}"))
                if elapsed > 0xFFFF:
                    self.warn(f"T17-OPEN: WAIT elapsed {elapsed} truncated to 16 bits "
                              f"(tsel={tsel}); firmware must not depend on this")
                R[rd] = elapsed & 0xFFFF
                cycles = 1 + elapsed
            self.pc = (self.pc + 1) & 0x1FF
            self.snapshot()
            return cycles
        elif name == "CAP":
            self._cts_hi = (self.ts >> 16) & 0xFFFF
            self._cts_pins = self.sync1
            R[F["rd"]] = self.ts & 0xFFFF
        elif name == "MOV":
            R[F["rd"]] = R[F["rs"]]
        elif name == "LDI":
            R[F["rd"]] = F["imm16"]
        elif name == "PUSH":
            if len(self.tx_fifo) < FIFO_DEPTH:
                self.tx_fifo.append(R[F["rs"]] & 0xFFFF)
            else:
                self.sticky |= (1 << ST_TX_OVERRUN)
        elif name == "PULL":
            if self.rx_fifo:
                R[F["rd"]] = self.rx_fifo.pop(0)
            else:
                R[F["rd"]] = 0
                self.sticky |= (1 << ST_RX_UNDERRUN)
        elif name == "MRS":
            R[F["rd"]] = self.sreg_read(F["sreg"])
        elif name == "MSR":
            self.sreg_write(F["sreg"], R[F["rs"]])
        elif name == "ADD/SUB":
            a, b = R[F["rs1"]], R[F["rs2"]]
            if F["fn"] == 0:
                r = a + b
                self.c = 1 if r > 0xFFFF else 0
            else:
                r = (a - b) & 0x1FFFF
                self.c = 1 if a >= b else 0
            r &= 0xFFFF
            R[F["rd"]] = r
            self.z, self.n = int(r == 0), (r >> 15) & 1
        elif name == "AND/OR/XOR":
            a, b = R[F["rs1"]], R[F["rs2"]]
            fn = F["fn"]
            if fn == 3:
                raise SimHalt(f"AND/OR/XOR fn=11 at PC={self.pc} (T7)")
            r = (a & b) if fn == 0 else ((a | b) if fn == 1 else (a ^ b))
            R[F["rd"]] = r & 0xFFFF
            self.z, self.n = int(r == 0), (r >> 15) & 1
        elif name == "SHL/SHR":
            a = R[F["rs1"]]
            n = R[F["rs2"]] & 0xF
            if n:
                if F["fn"] == 0:
                    self.c = (a >> (16 - n)) & 1
                    r = (a << n) & 0xFFFF
                else:
                    self.c = (a >> (n - 1)) & 1
                    r = (a >> n) & 0xFFFF
                R[F["rd"]] = r
                self.z, self.n = int(r == 0), (r >> 15) & 1
            else:
                R[F["rd"]] = a  # shift-by-0: C unchanged (documented)
                self.z, self.n = int(a == 0), (a >> 15) & 1
        elif name == "CMP":
            a, b = R[F["rs1"]], R[F["rs2"]]
            r = (a - b) & 0xFFFF
            self.z, self.n = int(r == 0), (r >> 15) & 1
            self.c = 1 if a >= b else 0
        elif name == "JMP":
            if self._cond(F["cond4"]):
                self.pc = F["target9"] & 0x1FF
            else:
                self.pc = (self.pc + 1) & 0x1FF
            for _ in range(cycles):
                self._tick_delay()
            self.snapshot()
            return cycles
        elif name == "DJNZ":
            rs = F["rs"]
            R[rs] = (R[rs] - 1) & 0xFFFF
            if R[rs] != 0:
                self.pc = F["target9"] & 0x1FF
            else:
                self.pc = (self.pc + 1) & 0x1FF
            for _ in range(cycles):
                self._tick_delay()
            self.snapshot()
            return cycles
        elif name == "CALL/RET":
            if F["is_ret"] == 0:
                if len(self.retstack) >= 4:
                    raise SimHalt(f"CALL stack overflow at PC={self.pc} (T11 open)")
                self.retstack.append((self.pc + 1) & 0x1FF)
                self.pc = F["target9"] & 0x1FF
            else:
                if not self.retstack:
                    raise SimHalt(f"RET on empty stack at PC={self.pc} (T10 open)")
                self.pc = self.retstack.pop()
            for _ in range(cycles):
                self._tick_delay()
            self.snapshot()
            return cycles
        elif name == "HLT":
            self.halted = True
            self.log.append((self.cycle, "HLT"))
            self.snapshot()
            return 1
        elif name == "EVT":
            self.evtflag |= (1 << F["imm4"])
        else:
            raise SimHalt(f"unimplemented: {name}")

        # default: advance PC, burn cycles
        self.pc = (self.pc + 1) & 0x1FF
        for _ in range(cycles):
            self._tick_delay()
        self.snapshot()
        return cycles

    def _tick_delay(self):
        # one core cycle with no new instruction effects: pins/sync/ts/observer advance
        self.end_of_cycle()

    def _cond(self, cond4):
        if cond4 == 0:
            return True
        if cond4 == 1:
            return self.z == 1
        if cond4 == 2:
            return self.z == 0
        if cond4 == 3:
            return self.c == 1
        if cond4 == 4:
            return self.c == 0
        if cond4 == 5:
            return bool(self.sticky & (1 << ST_TIMEOUT))
        if cond4 == 6:
            return len(self.rx_fifo) > 0
        if cond4 == 7:
            return len(self.tx_fifo) < FIFO_DEPTH
        raise SimHalt(f"reserved JMP cond {cond4}")

    # ------------------------------------------------------------------
    def run(self, max_cycles=10_000_000, snapshot_every=1):
        self._prev_sync0 = 0x00
        n = 0
        while not self.halted and n < max_cycles:
            c = self.step()
            n += c
            if n >= max_cycles:
                break
        return {"cycles": n, "halted": self.halted, "pc": self.pc,
                "warnings": list(self.warnings)}

    # ------------------------------------------------------------------
    # host-port model (test modules act as host)
    # ------------------------------------------------------------------
    def host_push_rx_bytes(self, data: bytes):
        words = []
        for i in range(0, len(data), 2):
            hi = data[i]
            lo = data[i + 1] if i + 1 < len(data) else 0x00
            words.append((hi << 8) | lo)
        if len(self.rx_fifo) + len(words) > FIFO_DEPTH:
            raise SimHalt("host WR_RXFIFO: insufficient space (all-or-nothing NACK)")
        self.rx_fifo.extend(words)

    def host_push_rx_words(self, words):
        if len(self.rx_fifo) + len(words) > FIFO_DEPTH:
            raise SimHalt("host WR_RXFIFO: insufficient space (all-or-nothing NACK)")
        self.rx_fifo.extend([w & 0xFFFF for w in words])

    def host_pop_tx_bytes(self, max_count):
        out = bytearray()
        words = self.tx_fifo[:]
        self.tx_fifo = []
        for w in words:
            out.append((w >> 8) & 0xFF)
            out.append(w & 0xFF)
        chunk = bytes(out[:max_count])
        return len(chunk), chunk

    def host_pop_tx_words(self):
        words = self.tx_fifo[:]
        self.tx_fifo = []
        return words

    def host_read_trace(self, start=0, count=204):
        n = len(self.trace)
        start = min(start, n)
        entries = self.trace[start:start + count]
        return entries, n

    def host_rd_status(self):
        # RD_STATUS byte: {PE_RUNNING,PE_HALTED,TIMEOUT,TX_EMPTY,RX_FULL,
        #                  TRACE_WM(live),TRACE_FULL,CONFIG_ERR} = bit7..bit0
        b = 0
        if not self.halted:
            b |= 0x80
        if self.halted:
            b |= 0x40
        if self.sticky & (1 << ST_TIMEOUT):
            b |= 0x20
        if not self.tx_fifo:
            b |= 0x10
        if len(self.rx_fifo) >= FIFO_DEPTH:
            b |= 0x08
        if self.wmark and len(self.trace) >= self.wmark:
            b |= 0x04  # live TRACE_WM
        if self.sticky & (1 << ST_TRACE_FULL):
            b |= 0x02
        if self.sticky & (1 << ST_CONFIG_ERR):
            b |= 0x01
        return b

    # ------------------------------------------------------------------
    # VCD output (GTKWave-readable)
    # ------------------------------------------------------------------
    def vcd(self, path, regs=(0, 1, 2, 3, 4, 5, 6, 7)):
        ids = {}
        with open(path, "w") as f:
            f.write("$timescale 1ns $end\n$scope module tarang $end\n")
            def var(name, width):
                vid = f"s{len(ids)}"
                ids[name] = vid
                f.write(f"$var wire {width} {vid} {name} $end\n")
                return vid
            var("cycle", 32); var("pc", 9); var("pins", 8); var("sync_pins", 8)
            var("ts", 32); var("obs_ptr", 8)
            for r in regs:
                var(f"r{r}", 16)
            f.write("$upscope $end\n$enddefinitions $end\n")
            # need per-cycle reg values: re-run is wasteful; store snapshots instead.
            # We stored (cycle,pc,pins,sync,ts); regs not stored -> dump current only.
            # Simpler: dump stored snapshots for pins/pc/ts; regs dumped once at end.
            for (cyc, pc, pins, sync, ts) in self.vcd_signals:
                f.write(f"#{cyc * 20}\n")
                f.write(f"b{cyc:032b} s0\n")
                f.write(f"b{pc:09b} s1\n")
                f.write(f"b{pins:08b} s2\n")
                f.write(f"b{sync:08b} s3\n")
                f.write(f"b{ts:032b} s4\n")
                f.write(f"b{len(self.trace):08b} s5\n")
            f.write(f"#{self.cycle * 20}\n")
            for i, r in enumerate(regs):
                f.write(f"b{self.regs[r]:016b} s{6 + i}\n")
        # note: obs_ptr/reg values in VCD are end-of-run (documented limitation);
        # per-cycle pin/pc/timestamp waveforms are exact.

    def status_str(self):
        return (f"cycle={self.cycle} pc={self.pc} halted={self.halted} "
                f"regs={[hex(r) for r in self.regs[:8]]} "
                f"ZNC={self.z}{self.n}{self.c} sticky={self.sticky:05b} "
                f"trace={len(self.trace)} tx={len(self.tx_fifo)} rx={len(self.rx_fifo)}")


def load_hex(path):
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                words.append(int(line, 16))
    return words


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: sim.py image.hex [--vcd out.vcd] [--max N]")
        sys.exit(1)
    img = load_hex(sys.argv[1])
    s = Sim(img)
    vcd = None
    maxc = 10_000_000
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--vcd":
            vcd = args[i + 1]; i += 2
        elif args[i] == "--max":
            maxc = int(args[i + 1]); i += 2
        else:
            i += 1
    r = s.run(max_cycles=maxc)
    print(s.status_str())
    print(f"halted={r['halted']} cycles={r['cycles']} warnings={len(r['warnings'])}")
    for c, w in r["warnings"][:10]:
        print(f"  @{c}: {w}")
    if vcd:
        s.vcd(vcd)
        print(f"vcd: {vcd}")
