// Tarang-32 cycle-exact PE + Observer simulator (web port).
//
// Semantics source: firmware/tools/sim.py (the golden model), ISA v0.2 +
// v0.3 note, and src/tt_um_pemu_pe.v / src/tt_um_pemu_observer.v for the
// AS-BUILT divergences from the golden model. Where sim.py and the RTL
// disagree, THIS FILE FOLLOWS THE RTL (the chip as built):
//   * WAIT tsel: 0 -> 256, 1 -> 4096, 2 -> 256 + CONFIG_ERR,
//     3 -> 4096 + CONFIG_ERR. (sim.py implements 65536 / 1048576 and
//     truncates elapsed; the RTL ignores tsel[1] for the timeout and
//     flags CONFIG_ERR. Saturation at 0xFFFF is NOT implemented.)
//   * Illegal opcodes 24-63: NOP (1+d) + CONFIG_ERR (sim.py halts).
//   * CALL on a full (4-deep) return stack: call dropped + CONFIG_ERR
//     (sim.py halts). RET on an empty stack: NOP + CONFIG_ERR (sim.py halts).
//   * AND/OR/XOR fn=11: executed as AND + CONFIG_ERR (sim.py halts).
//   * JMP cond4 8-15: never taken + CONFIG_ERR (RTL).
//   * Observer PULSE mode watches PIN 0 only: the top level ties the
//     Observer pin_sel input to 0 (audit item 7c), regardless of the
//     PIN_SEL special register. EDGE and PATTERN modes are unaffected.
//   * STATUS[12] TRACE_WM is included in the MRS STATUS read (RTL/ISA);
//     sim.py's sreg_read masks it out (sticky & 0x1F) -- a sim quirk,
//     not hardware behaviour. It is cleared only by OBS_CLR, never by
//     a STATUS W1C write (bits [4:0] only), in both.
//   * Trace SRAM: 204 entries, saturating pointer, never wraps; on full
//     triggers are ignored and TRACE_FULL sticky is set.
//   * HLT: the HLT base cycle performs no tick (golden model + RTL
//     comment: clocks gated). Step Cycle on HLT therefore advances the
//     cycle counter by 0 and reports halted.
// Cycle model (matches sim.py tick-for-tick): an instruction's effects
// commit at the start of its base cycle; the base cycle and its d delay
// cycles then tick (peer -> pin resolve -> 2-FF sync -> prescaled
// timestamp -> Observer -> cycle++). PGET/CAP sample the synchronised
// pins (2 cycles old) at instruction start. WAIT: the entry check runs
// after the base tick (elapsed 0 if true); each later tick checks first
// (check-then-latch for edge modes), elapsed = loop ticks, timeout
// elapsed = timeout with TIMEOUT sticky; a condition true exactly at
// the deadline counts as satisfied.
// No dependencies. UMD: window.TempoCore in the browser, module in Node.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TempoCore = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var TSEL_TIMEOUT = [256, 4096, 256, 4096]; // as-built; tsel 2/3 + CONFIG_ERR
  var PRESCALER_DIV = [1, 16, 256, 4096];
  var FIFO_DEPTH = 16, TRACE_MAX = 204;
  var ST = { TIMEOUT: 0, TX_OVERRUN: 1, RX_UNDERRUN: 2, TRACE_FULL: 3, CONFIG_ERR: 4 };
  var SREG = { STATUS: 0, CYCLES_LO: 1, CYCLES_HI: 2, CTS_HI: 3, CTS_PINS: 4,
    OBS_PTR: 5, PMASKR: 6, PDIRR: 7, PMODER: 8, TRIG_MODE: 9, PIN_SEL: 10,
    MASK: 11, VALUE: 12, EDGE_MASK: 13, EDGE_CFG0: 14, EDGE_CFG1: 15,
    WMARK: 16, PRESCALER: 17, OBS_CTL: 18, EVTFLAG: 19 };
  var SREG_NAMES = ["STATUS", "CYCLES_LO", "CYCLES_HI", "CTS_HI", "CTS_PINS",
    "OBS_PTR", "PMASKR", "PDIRR", "PMODER", "TRIG_MODE", "PIN_SEL", "MASK",
    "VALUE", "EDGE_MASK", "EDGE_CFG0", "EDGE_CFG1", "WMARK", "PRESCALER",
    "OBS_CTL", "EVTFLAG"];
  var COND_NAMES = ["al", "z", "nz", "c", "nc", "tmo", "rxne", "txnf"];
  var WAIT_MODE_NAMES = ["level", "rising", "falling", "either"];
  var OP_NAMES = ["PSET", "PSETR", "PGET", "PMASK", "PDIR", "PMODE", "SLEEP",
    "WAIT", "CAP", "MOV", "LDI", "PUSH", "PULL", "MRS", "MSR", "ADD/SUB",
    "AND/OR/XOR", "SHL/SHR", "CMP", "JMP", "DJNZ", "CALL/RET", "HLT", "EVT"];

  function fld(word, msb, lsb) {
    return (word >>> lsb) & ((1 << (msb - lsb + 1)) - 1);
  }
  function hex(v, n) {
    return "0x" + (v >>> 0).toString(16).toUpperCase().padStart(n, "0");
  }

  function disassemble(word) {
    word = word >>> 0;
    var op = fld(word, 31, 26), d = fld(word, 25, 21);
    var dsuf = d ? ", d=" + d : "";
    if (op >= 24) return "illegal(" + op + ") ; NOP + CONFIG_ERR" + dsuf;
    var name = OP_NAMES[op], r = function (b) { return "r" + b; };
    var h = function (v, n) { return "0x" + v.toString(16).toUpperCase().padStart(n, "0"); };
    switch (op) {
      case 0: return "pset " + h(fld(word, 20, 13), 2) + dsuf;
      case 1: return "psetr " + r(fld(word, 20, 17)) + dsuf;
      case 2: return "pget " + r(fld(word, 20, 17)) + dsuf;
      case 3: return "pmask " + h(fld(word, 20, 13), 2) + dsuf;
      case 4: return "pdir " + h(fld(word, 20, 13), 2) + dsuf;
      case 5: return "pmode " + r(fld(word, 20, 17)) + dsuf;
      case 6: return "sleep " + fld(word, 20, 8);
      case 7: {
        var cfg = fld(word, 20, 13), pin = (cfg >> 5) & 7, pol = (cfg >> 4) & 1,
          mode = (cfg >> 2) & 3, tsel = cfg & 3;
        return "wait " + pin + ", " + pol + ", " + WAIT_MODE_NAMES[mode] + ", " +
          tsel + ", " + r(fld(word, 12, 9)) +
          " ; timeout " + TSEL_TIMEOUT[tsel] + (tsel >= 2 ? " + CONFIG_ERR (as-built)" : "");
      }
      case 8: return "cap " + r(fld(word, 20, 17)) + dsuf;
      case 9: return "mov " + r(fld(word, 20, 17)) + ", " + r(fld(word, 16, 13)) + dsuf;
      case 10: return "ldi " + r(fld(word, 20, 17)) + ", " + h(fld(word, 16, 1), 4) + dsuf;
      case 11: return "push " + r(fld(word, 20, 17)) + dsuf;
      case 12: return "pull " + r(fld(word, 20, 17)) + dsuf;
      case 13: return "mrs " + r(fld(word, 20, 17)) + ", " + (SREG_NAMES[fld(word, 16, 11)] || fld(word, 16, 11)) + dsuf;
      case 14: return "msr " + r(fld(word, 20, 17)) + ", " + (SREG_NAMES[fld(word, 16, 11)] || fld(word, 16, 11)) + dsuf;
      case 15: return (fld(word, 8, 8) ? "sub " : "add ") + r(fld(word, 20, 17)) + ", " +
        r(fld(word, 16, 13)) + ", " + r(fld(word, 12, 9)) + dsuf;
      case 16: {
        var fn = fld(word, 8, 7);
        return (fn === 0 ? "and " : fn === 1 ? "or " : fn === 2 ? "xor " : "and ; fn=11 -> AND + CONFIG_ERR ") +
          r(fld(word, 20, 17)) + ", " + r(fld(word, 16, 13)) + ", " + r(fld(word, 12, 9)) + dsuf;
      }
      case 17: return (fld(word, 8, 8) ? "shr " : "shl ") + r(fld(word, 20, 17)) + ", " +
        r(fld(word, 16, 13)) + ", " + r(fld(word, 12, 9)) + dsuf;
      case 18: return "cmp " + r(fld(word, 20, 17)) + ", " + r(fld(word, 16, 13)) + dsuf;
      case 19: return "jmp " + fld(word, 20, 12) + ", " + (COND_NAMES[fld(word, 11, 8)] || ("cond" + fld(word, 11, 8))) + dsuf;
      case 20: return "djnz " + r(fld(word, 20, 17)) + ", " + fld(word, 16, 8) + dsuf;
      case 21: return fld(word, 11, 11) ? "ret" + dsuf : "call " + fld(word, 20, 12) + dsuf;
      case 22: return "hlt";
      case 23: return "evt " + fld(word, 20, 17) + dsuf;
    }
    return "???";
  }

  function Sim(imemWords) {
    this.imem = new Array(512).fill(0);
    if (imemWords) for (var i = 0; i < imemWords.length && i < 512; i++) this.imem[i] = imemWords[i] >>> 0;
    this.peer = null;      // function(sim) called at the start of each tick
    this.peerDrv = {};     // pin -> 0 | 1 | null (Hi-Z); persists between ticks
    this.reset();
  }

  Sim.prototype.reset = function () {
    this.pc = 0; this.regs = new Array(16).fill(0);
    this.z = 0; this.n = 0; this.c = 0;
    this.sticky = 0; this.stickyTraceWm = false; this.cfgDirty = false;
    this.pmask = 0xFF; this.pdir = 0x00; this.pmode = 0x0000; this.pinDrv = 0x00;
    this.sync0 = 0x00; this.sync1 = 0x00; this.prevSync0 = 0x00; this.pinsPhys = 0x00;
    this.ts = 0; this.prescaleCnt = 0; this.cycle = 0;
    this.txFifo = []; this.rxFifo = []; this.evtflag = 0; this.halted = false;
    this.retstack = [];
    this.trigMode = 0; this.pinSel = 0; this.obsMask = 0; this.obsValue = 0;
    this.edgeMask = 0; this.edgeCfg0 = 0; this.edgeCfg1 = 0; this.wmark = 0;
    this.prescaler = 0; this.obsEn = false; this.obsArm = false;
    this.trace = []; this.prevSync = 0x00; this.waitPrev = 0x00;
    this.ctsHi = 0; this.ctsPins = 0;
    this.history = []; this.capEvents = [];
    this.inProgress = null; this.curWord = 0; this.curText = "";
    this.peerDrv = {};
  };

  Sim.prototype.resolvePins = function () {
    var phys = 0;
    for (var i = 0; i < 8; i++) {
      var peEn = (this.pdir >> i) & 1;
      var od = (this.pmode >> (2 * i + 1)) & 1;
      var pu = (this.pmode >> (2 * i)) & 1;
      var peDrive = null;
      if (peEn) {
        if (od) peDrive = ((this.pinDrv >> i) & 1) === 0 ? 0 : null;
        else peDrive = (this.pinDrv >> i) & 1;
      }
      var peer = this.peerDrv[i] === undefined ? null : this.peerDrv[i];
      var v;
      if (peDrive === 0 || peer === 0) v = 0;
      else if (peDrive === 1 || peer === 1) v = 1;
      else if (pu) v = 1;
      else v = 0;
      phys |= (v << i);
    }
    this.pinsPhys = phys;
  };

  Sim.prototype.doTick = function () {
    if (this.peer) this.peer(this);
    this.resolvePins();
    this.sync0 = this.pinsPhys;
    var newSync1 = this.prevSync0;
    this.prevSync0 = this.sync0;
    this.sync1 = newSync1;
    var div = PRESCALER_DIV[this.prescaler & 3];
    this.prescaleCnt += 1;
    if (this.prescaleCnt >= div) { this.prescaleCnt = 0; this.ts = (this.ts + 1) >>> 0; }
    this.observerEval();
    this.cycle += 1;
    this.history.push(this.pinsPhys);
    this.prevSync = this.sync1;
  };

  Sim.prototype.observerEval = function () {
    if (!this.obsEn || this.trigMode === 0) return;
    var fire = false, i;
    if (this.trigMode === 1) { // EDGE
      for (i = 0; i < 8; i++) {
        if (!((this.edgeMask >> i) & 1)) continue;
        var cfg = i < 4 ? this.edgeCfg0 : this.edgeCfg1;
        var code = (cfg >> (2 * (i % 4))) & 3;
        if (code === 0) continue;
        var now = (this.sync1 >> i) & 1, was = (this.prevSync >> i) & 1;
        if (code === 1 && now && !was) fire = true;
        else if (code === 2 && !now && was) fire = true;
        else if (code === 3 && now !== was) fire = true;
      }
    } else if (this.trigMode === 2) { // PATTERN (level)
      if ((this.sync1 & this.obsMask) === (this.obsValue & this.obsMask)) fire = true;
    } else if (this.trigMode === 3) { // PULSE: as-built, pin 0 only (top-level tie)
      var n0 = this.sync1 & 1, w0 = this.prevSync & 1;
      if (n0 !== w0) fire = true;
    }
    if (fire) this.observerCommit();
  };

  Sim.prototype.observerCommit = function () {
    if (this.trace.length >= TRACE_MAX) {
      this.sticky |= (1 << ST.TRACE_FULL);
      return;
    }
    this.trace.push([this.ts, this.sync1]);
    if (this.wmark && this.trace.length === this.wmark) this.stickyTraceWm = true;
  };

  Sim.prototype.statusWord = function () {
    var v = this.sticky & 0x1F;
    if (this.stickyTraceWm) v |= (1 << 12);
    if (this.cfgDirty) v |= (1 << 13);
    if (!this.halted) v |= (1 << 8);
    if (this.halted) v |= (1 << 9);
    if (this.txFifo.length === 0) v |= (1 << 10);
    if (this.rxFifo.length >= FIFO_DEPTH) v |= (1 << 11);
    return v;
  };

  Sim.prototype.sregRead = function (addr) {
    switch (addr) {
      case 0: return this.statusWord();
      case 1: return this.ts & 0xFFFF;
      case 2: return (this.ts >>> 16) & 0xFFFF;
      case 3: return this.ctsHi;
      case 4: return this.ctsPins;
      case 5: return this.trace.length;
      case 6: return this.pmask;
      case 7: return this.pdir;
      case 8: return this.pmode;
      case 9: return this.trigMode;
      case 10: return this.pinSel;
      case 11: return this.obsMask;
      case 12: return this.obsValue;
      case 13: return this.edgeMask;
      case 14: return this.edgeCfg0;
      case 15: return this.edgeCfg1;
      case 16: return this.wmark;
      case 17: return this.prescaler;
      case 18: return (this.obsEn ? 1 : 0) | (this.obsArm ? 2 : 0);
      case 19: return this.evtflag;
      default: return 0; // unallocated: read-as-zero, no CONFIG_ERR (RTL/T5)
    }
  };

  Sim.prototype.sregWrite = function (addr, val) {
    val &= 0xFFFF;
    if (addr === 0) { this.sticky &= ~(val & 0x1F); return; } // W1C bits [4:0] only
    if (addr === 9) { this.trigMode = val & 3; this.obsEn = false; return; } // any write disarms
    if (addr === 10) { this.pinSel = val & 7; return; }
    if (addr === 11) { this.obsMask = val & 0xFF; return; }
    if (addr === 12) { this.obsValue = val & 0xFF; return; }
    if (addr === 13) { this.edgeMask = val & 0xFF; return; }
    if (addr === 14) { this.edgeCfg0 = val & 0xFF; return; }
    if (addr === 15) { this.edgeCfg1 = val & 0xFF; return; }
    if (addr === 16) { this.wmark = val & 0xFF; return; }
    if (addr === 17) { this.prescaler = val & 3; return; }
    if (addr === 18) {
      if (val & 4) { this.trace = []; this.stickyTraceWm = false; } // OBS_CLR
      if (val & 1) this.obsEn = true;
      if (val & 2) this.obsArm = true;
      return;
    }
    // RO / unallocated: writes ignored.
  };

  Sim.prototype.waitCond = function (pin, pol, mode) {
    var v = (this.sync1 >> pin) & 1;
    if (mode === 0) return v === pol;
    var pv = (this.waitPrev >> pin) & 1;
    if (mode === 1) return v && !pv;
    if (mode === 2) return (!v) && pv;
    return v !== pv;
  };

  Sim.prototype.condTrue = function (cond4) {
    if (cond4 === 0) return true;
    if (cond4 === 1) return this.z === 1;
    if (cond4 === 2) return this.z === 0;
    if (cond4 === 3) return this.c === 1;
    if (cond4 === 4) return this.c === 0;
    if (cond4 === 5) return !!(this.sticky & (1 << ST.TIMEOUT));
    if (cond4 === 6) return this.rxFifo.length > 0;
    if (cond4 === 7) return this.txFifo.length < FIFO_DEPTH;
    return false; // reserved cond: never taken (RTL) + CONFIG_ERR, set by caller
  };

  // Commit one instruction's effects at the start of its base cycle and
  // set inProgress (or halt). Does not tick.
  Sim.prototype.startInstruction = function () {
    var word = this.imem[this.pc] >>> 0;
    var op = fld(word, 31, 26), d = fld(word, 25, 21);
    this.curWord = word; this.curText = disassemble(word);
    var R = this.regs, nextPc = (this.pc + 1) & 0x1FF;
    var remaining = 1 + d;
    if (op >= 24) { // illegal: NOP + CONFIG_ERR
      this.sticky |= (1 << ST.CONFIG_ERR);
      this.pc = nextPc; this.inProgress = { kind: "normal", remaining: remaining };
      return;
    }
    switch (op) {
      case 0: this.pinDrv = (this.pinDrv & ~this.pmask) | (fld(word, 20, 13) & this.pmask); break;
      case 1: { var rs = R[fld(word, 20, 17)]; this.pinDrv = (this.pinDrv & ~this.pmask) | ((rs & 0xFF) & this.pmask); break; }
      case 2: R[fld(word, 20, 17)] = this.sync1; break;
      case 3: this.pmask = fld(word, 20, 13); break;
      case 4: this.pdir = fld(word, 20, 13); break;
      case 5: this.pmode = R[fld(word, 20, 17)] & 0xFFFF; break;
      case 6: remaining = 1 + fld(word, 20, 8); break; // SLEEP
      case 7: { // WAIT (base tick happens in tick(); entry check after it)
        var cfg = fld(word, 20, 13);
        var tsel = cfg & 3;
        if (tsel >= 2) this.sticky |= (1 << ST.CONFIG_ERR);
        this.waitPrev = this.sync1;
        this.pc = nextPc;
        this.inProgress = { kind: "wait", phase: "base",
          pin: (cfg >> 5) & 7, pol: (cfg >> 4) & 1, mode: (cfg >> 2) & 3,
          tsel: tsel, timeout: TSEL_TIMEOUT[tsel], rd: fld(word, 12, 9), elapsed: 0 };
        return;
      }
      case 8: // CAP: latch at instruction start (pre-tick timestamp/pins)
        this.ctsHi = (this.ts >>> 16) & 0xFFFF; this.ctsPins = this.sync1;
        R[fld(word, 20, 17)] = this.ts & 0xFFFF;
        this.capEvents.push({ cycle: this.cycle, ts: this.ts, pins: this.sync1, rd: fld(word, 20, 17) });
        break;
      case 9: R[fld(word, 20, 17)] = R[fld(word, 16, 13)]; break;
      case 10: R[fld(word, 20, 17)] = fld(word, 16, 1); break;
      case 11: // PUSH
        if (this.txFifo.length < FIFO_DEPTH) this.txFifo.push(R[fld(word, 20, 17)] & 0xFFFF);
        else this.sticky |= (1 << ST.TX_OVERRUN);
        break;
      case 12: // PULL
        if (this.rxFifo.length) R[fld(word, 20, 17)] = this.rxFifo.shift();
        else { R[fld(word, 20, 17)] = 0; this.sticky |= (1 << ST.RX_UNDERRUN); }
        break;
      case 13: R[fld(word, 20, 17)] = this.sregRead(fld(word, 16, 11)); break;
      case 14: this.sregWrite(fld(word, 16, 11), R[fld(word, 20, 17)]); break;
      case 15: { // ADD/SUB
        var a = R[fld(word, 16, 13)], b = R[fld(word, 12, 9)], r, fn15 = fld(word, 8, 8);
        if (fn15 === 0) { r = a + b; this.c = r > 0xFFFF ? 1 : 0; }
        else { r = (a - b) & 0x1FFFF; this.c = a >= b ? 1 : 0; }
        r &= 0xFFFF; R[fld(word, 20, 17)] = r;
        this.z = r === 0 ? 1 : 0; this.n = (r >> 15) & 1; break;
      }
      case 16: { // AND/OR/XOR; fn=11 -> AND + CONFIG_ERR
        var a16 = R[fld(word, 16, 13)], b16 = R[fld(word, 12, 9)], fn16 = fld(word, 8, 7), r16;
        if (fn16 === 3) { this.sticky |= (1 << ST.CONFIG_ERR); r16 = a16 & b16; }
        else if (fn16 === 0) r16 = a16 & b16;
        else if (fn16 === 1) r16 = a16 | b16;
        else r16 = a16 ^ b16;
        r16 &= 0xFFFF; R[fld(word, 20, 17)] = r16;
        this.z = r16 === 0 ? 1 : 0; this.n = (r16 >> 15) & 1; break;
      }
      case 17: { // SHL/SHR, amount Rs2[3:0]; shift-by-0 leaves C unchanged
        var a17 = R[fld(word, 16, 13)], n17 = R[fld(word, 12, 9)] & 0xF, r17;
        if (n17) {
          if (fld(word, 8, 8) === 0) { this.c = (a17 >> (16 - n17)) & 1; r17 = (a17 << n17) & 0xFFFF; }
          else { this.c = (a17 >> (n17 - 1)) & 1; r17 = (a17 >> n17) & 0xFFFF; }
        } else r17 = a17;
        R[fld(word, 20, 17)] = r17;
        this.z = r17 === 0 ? 1 : 0; this.n = (r17 >> 15) & 1; break;
      }
      case 18: { // CMP
        var a18 = R[fld(word, 20, 17)], b18 = R[fld(word, 16, 13)], r18 = (a18 - b18) & 0xFFFF;
        this.z = r18 === 0 ? 1 : 0; this.n = (r18 >> 15) & 1; this.c = a18 >= b18 ? 1 : 0; break;
      }
      case 19: { // JMP
        var cond = fld(word, 11, 8);
        if (cond >= 8) this.sticky |= (1 << ST.CONFIG_ERR);
        else if (this.condTrue(cond)) this.pc = fld(word, 20, 12) & 0x1FF;
        else this.pc = nextPc;
        if (cond >= 8) this.pc = nextPc;
        this.inProgress = { kind: "normal", remaining: remaining };
        return;
      }
      case 20: { // DJNZ: test the NEW (post-decrement) value
        var rs20 = fld(word, 20, 17);
        R[rs20] = (R[rs20] - 1) & 0xFFFF;
        this.pc = R[rs20] !== 0 ? (fld(word, 16, 8) & 0x1FF) : nextPc;
        this.inProgress = { kind: "normal", remaining: remaining };
        return;
      }
      case 21: { // CALL/RET
        if (fld(word, 11, 11) === 0) { // CALL
          if (this.retstack.length >= 4) { this.sticky |= (1 << ST.CONFIG_ERR); this.pc = nextPc; }
          else { this.retstack.push(nextPc); this.pc = fld(word, 20, 12) & 0x1FF; }
        } else { // RET
          if (!this.retstack.length) { this.sticky |= (1 << ST.CONFIG_ERR); this.pc = nextPc; }
          else this.pc = this.retstack.pop();
        }
        this.inProgress = { kind: "normal", remaining: remaining };
        return;
      }
      case 22: // HLT: clocks gated -- no tick for the base cycle
        this.halted = true; this.inProgress = null; return;
      case 23: this.evtflag |= (1 << fld(word, 20, 17)); break;
    }
    this.pc = nextPc;
    this.inProgress = { kind: "normal", remaining: remaining };
  };

  // Advance exactly one clock cycle. Returns true if a tick happened.
  Sim.prototype.tick = function () {
    if (this.halted) return false;
    if (!this.inProgress) this.startInstruction();
    if (this.halted) return false; // HLT: no tick
    this.doTick();
    var ip = this.inProgress;
    if (ip.kind === "wait") {
      if (ip.phase === "base") {
        if (this.waitCond(ip.pin, ip.pol, ip.mode)) {
          this.regs[ip.rd] = 0; this.inProgress = null;
        } else {
          ip.phase = "loop"; ip.elapsed = 0; this.waitPrev = this.sync1;
        }
      } else {
        ip.elapsed += 1;
        if (this.waitCond(ip.pin, ip.pol, ip.mode)) {
          this.regs[ip.rd] = ip.elapsed; this.inProgress = null;
        } else if (ip.elapsed >= ip.timeout) {
          this.sticky |= (1 << ST.TIMEOUT);
          this.regs[ip.rd] = ip.timeout; this.inProgress = null;
        } else this.waitPrev = this.sync1;
      }
    } else {
      ip.remaining -= 1;
      if (ip.remaining <= 0) this.inProgress = null;
    }
    return true;
  };

  // Advance until the in-flight instruction (if any) completes, or one
  // whole instruction if at a fetch boundary. Returns ticks done.
  Sim.prototype.stepInstruction = function () {
    if (this.halted) return 0;
    var n = 0;
    do { if (!this.tick()) break; n++; } while (this.inProgress && !this.halted && n < 2000000);
    return n;
  };

  // Run exactly N ticks (or until HALT). Returns ticks actually done.
  Sim.prototype.runCycles = function (n) {
    var done = 0;
    while (done < n && !this.halted) { if (!this.tick()) break; done++; }
    return done;
  };

  // Run until HALT or maxTicks. Returns { halted, ticks }.
  Sim.prototype.runUntilHalt = function (maxTicks) {
    var done = 0;
    while (!this.halted && done < (maxTicks || 5000000)) { if (!this.tick()) break; done++; }
    return { halted: this.halted, ticks: done };
  };

  Sim.prototype.hostPushRxWords = function (words) {
    if (this.rxFifo.length + words.length > FIFO_DEPTH)
      throw new Error("host WR_RXFIFO: insufficient space (all-or-nothing NACK)");
    for (var i = 0; i < words.length; i++) this.rxFifo.push(words[i] & 0xFFFF);
  };
  Sim.prototype.hostPopTxWords = function () {
    var w = this.txFifo.slice(); this.txFifo = []; return w;
  };

  Sim.prototype.traceState = function () {
    if (!this.obsEn) return "disabled";
    if (this.trace.length >= TRACE_MAX) return "full (stopped, saturating)";
    return "armed, capturing";
  };

  Sim.prototype.snapshot = function () {
    var st = this.statusWord();
    return { pc: this.pc, regs: this.regs.slice(), z: this.z, n: this.n, c: this.c,
      status: st, halted: this.halted, cycle: this.cycle, ts: this.ts,
      pinsPhys: this.pinsPhys, syncPins: this.sync1, pdir: this.pdir,
      pmask: this.pmask, pmode: this.pmode, pinDrv: this.pinDrv,
      txFifo: this.txFifo.slice(), rxFifo: this.rxFifo.slice(),
      evtflag: this.evtflag, traceLen: this.trace.length,
      traceState: this.traceState(), capEvents: this.capEvents.length,
      inFlight: this.inProgress ? this.curText : null,
      inFlightRemaining: this.inProgress ? (this.inProgress.remaining || null) : null,
      nextInstr: disassemble(this.imem[this.pc]),
      statusBits: { TIMEOUT: !!(st & 1), TX_OVERRUN: !!(st & 2), RX_UNDERRUN: !!(st & 4),
        TRACE_FULL: !!(st & 8), CONFIG_ERR: !!(st & 16), PE_RUNNING: !!(st & 256),
        PE_HALTED: !!(st & 512), TX_EMPTY: !!(st & 1024), RX_FULL: !!(st & 2048),
        TRACE_WM: !!(st & 4096), CFG_DIRTY: !!(st & 8192) } };
  };

  return { Sim: Sim, disassemble: disassemble, hex: hex,
    TSEL_TIMEOUT: TSEL_TIMEOUT, TRACE_MAX: TRACE_MAX, SREG: SREG, ST: ST };
});
