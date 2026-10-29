// Peer / bus models for the web simulator examples.
// Direct ports of the golden-model test peers in firmware/tests/
// (test_spi.py, test_uart.py, test_usb_full.py, test_i2c.py,
// test_onewire.py, test_jtag.py, test_swd.py, test_ps2.py, test_can.py).
// Only the field names are adapted to the JS core (pdir, pinDrv,
// pinsPhys, rxFifo, peerDrv); every state transition, timing constant
// and drive value is the golden peer's. A peer is called at the start
// of each core tick, before pin resolution, exactly as in sim.py's
// end_of_cycle -- so it sees the previous tick's pinsPhys, as in gold.
// No dependencies. UMD: window.TempoPeers in the browser, module in Node.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TempoPeers = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // ---------------------------------------------------------------- SPI
  function spiSlave(txBytes) {
    var SCLK = 2, MOSI = 3, MISO = 4, CSN = 5;
    var resp = txBytes.map(function (b) { return (~b) & 0xFF; });
    var st = { cs: 1, sclk: 0, byteIdx: 0, bitIdx: 0, cur: 0,
      seen: [], sent: [], miso: null, pulses: 0 };
    function peer(sim) {
      var pdir = sim.pdir, drv = sim.pinDrv;
      var cs = ((pdir >> CSN) & 1) ? ((drv >> CSN) & 1) : 1;
      var sclk = ((pdir >> SCLK) & 1) ? ((drv >> SCLK) & 1) : 0;
      var mosi = ((pdir >> MOSI) & 1) ? ((drv >> MOSI) & 1) : 0;
      if (st.cs === 1 && cs === 0) {
        st.pulses += 1; st.bitIdx = 0; st.cur = 0;
        var rb = st.byteIdx < resp.length ? resp[st.byteIdx] : 0;
        st.miso = (rb >> 7) & 1;
      } else if (st.cs === 0 && cs === 1) st.miso = null;
      if (cs === 0) {
        if (st.sclk === 0 && sclk === 1) {
          st.cur = ((st.cur << 1) | mosi) & 0xFF; st.bitIdx += 1;
          if (st.bitIdx === 8) {
            st.seen.push(st.cur);
            var rb2 = st.byteIdx < resp.length ? resp[st.byteIdx] : 0;
            st.sent.push(rb2); st.byteIdx += 1; st.cur = 0; st.bitIdx = 0;
          }
        } else if (st.sclk === 1 && sclk === 0) {
          var rb3 = st.byteIdx < resp.length ? resp[st.byteIdx] : 0;
          st.miso = (rb3 >> (7 - st.bitIdx)) & 1;
        }
      }
      st.cs = cs; st.sclk = sclk;
      sim.peerDrv[MISO] = st.miso;
    }
    peer.state = st;
    return peer;
  }

  // ---------------------------------------------------------------- UART
  function uartPeer() {
    var BIT = 434, TX_BYTES = [0x55, 0xAA, 0x00, 0xFF],
      RX_BYTES = [0xA5, 0x3C], BREAK_LEN = 14000, RX_DELAY = 2000;
    var st = { phase: "tx", rxT0: null, hltPushed: false, txBytes: [],
      txEdges: [], txFrames: [], lastPin0: null, txSampling: false,
      txBits: [], txEdge: 0, txNext: 0 };
    function rxLevel(c) {
      var t = c - st.rxT0;
      if (t < 0) return 1;
      var framelen = RX_BYTES.length * 10 * BIT;
      if (t < framelen) {
        var bitpos = Math.floor(t / BIT);
        var bytenum = Math.floor(bitpos / 10), bitidx = bitpos % 10;
        var byte = RX_BYTES[bytenum];
        if (bitidx === 0) return 0;
        if (bitidx === 9) return 1;
        return (byte >> (bitidx - 1)) & 1;
      }
      if (t < framelen + BREAK_LEN) return 0;
      return 1;
    }
    function peer(sim) {
      var c = sim.cycle;
      if (st.phase === "tx") {
        sim.peerDrv[1] = 1;
        if (sim.evtflag & 0x01) { st.phase = "rx"; st.rxT0 = c + RX_DELAY; }
      } else {
        sim.peerDrv[1] = rxLevel(c + 1);
        if ((sim.evtflag & 0x02) && !st.hltPushed) {
          st.hltPushed = true; sim.rxFifo.push(0x00FF);
        }
      }
      var cur = sim.pinsPhys & 1;
      if (st.lastPin0 === null) { st.lastPin0 = cur; return; }
      if (st.lastPin0 === 1 && cur === 0 && !st.txSampling) {
        st.txSampling = true; st.txBits = []; st.txEdge = c; st.txNext = c + Math.floor(BIT / 2);
      }
      if (st.txSampling && c === st.txNext) {
        st.txBits.push(cur); st.txNext += BIT;
        if (st.txBits.length === 10) {
          var bits = st.txBits, byte = 0;
          for (var i = 0; i < 8; i++) byte |= (bits[1 + i] << i);
          st.txBytes.push(byte); st.txEdges.push(st.txEdge);
          st.txFrames.push(bits[0] === 0 && bits[9] === 1);
          st.txSampling = false;
        }
      }
      st.lastPin0 = cur;
    }
    peer.state = st;
    return peer;
  }

  // ---------------------------------------------------------------- USB
  function usbBitsOf(byts) {
    var bits = [];
    byts.forEach(function (b) { for (var i = 0; i < 8; i++) bits.push((b >> i) & 1); });
    return bits;
  }
  function usbCrc16TxBits(payload) {
    var crc = 0xFFFF;
    usbBitsOf(payload).forEach(function (bit) {
      var fb = ((crc >> 15) & 1) ^ bit;
      crc = (crc << 1) & 0xFFFF;
      if (fb) crc ^= 0x8005;
    });
    var comp = (~crc) & 0xFFFF, out = [];
    for (var i = 0; i < 16; i++) out.push((comp >> (15 - i)) & 1);
    return out;
  }
  function usbStuff(bits) {
    var out = [], ones = 0;
    bits.forEach(function (bit) {
      if (ones === 6) { out.push(0); ones = 0; }
      out.push(bit); ones = bit === 1 ? ones + 1 : 0;
    });
    return out;
  }
  function usbFullPeer() {
    var J = 0x02, K = 0x01, SE0 = 0x00, T_START = 4500;
    var rawBits = usbBitsOf([0x80, 0xC3, 0xFF, 0xFF]).concat(usbCrc16TxBits([0xFF, 0xFF]));
    var sched = [], state = J, t = T_START, cell = 0;
    usbStuff(rawBits).forEach(function (bit) {
      if (bit === 0) state = state === J ? K : J;
      var dur = cell % 3 === 2 ? 34 : 33;
      sched.push([t, state, dur]); t += dur; cell += 1;
    });
    sched.push([t, SE0, 66]); t += 66;
    sched.push([t, J, 33]);
    var tEnd = t + 33;
    function peer(sim) {
      if (sim.cycle < T_START || sim.cycle >= tEnd) {
        sim.peerDrv[0] = null; sim.peerDrv[1] = null; return;
      }
      var st = J;
      for (var i = 0; i < sched.length; i++) {
        if (sim.cycle >= sched[i][0]) st = sched[i][1]; else break;
      }
      sim.peerDrv[0] = st & 1; sim.peerDrv[1] = (st >> 1) & 1;
    }
    peer.tStart = T_START; peer.tEnd = tEnd;
    return peer;
  }

  // ---------------------------------------------------------------- I2C
  function i2cSlave(addr) {
    var SCL = 6, SDA = 7, STRETCH_HOLD = 2000;
    var s = { addr: addr === undefined ? 0x50 : addr, stored: [], readOut: [],
      masterAcks: [], stretches: [], rcnt: 0, prev: null };
    function resetLink() {
      s.state = "IDLE"; s.phase = "DATA"; s.bit = 0; s.cur = 0; s.clk = 0;
      s.rbyte = 0; s.sdaDrv = null; s.sclDrv = null; s.matched = false;
      s.dirRead = false; s.stretchArmed = false; s.stretchT0 = null; s.stretchRel = null;
    }
    function start() { resetLink(); s.state = "ADDR"; }
    function stop() { resetLink(); }
    function driveRbit(n) { s.sdaDrv = ((s.rbyte >> n) & 1) === 0 ? 0 : null; }
    function onRise(sda) {
      if ((s.state === "ADDR" || s.state === "WDATA") && s.phase === "DATA") {
        s.cur = ((s.cur << 1) | sda) & 0xFF; s.bit += 1;
        if (s.bit === 8 && s.state === "WDATA") s.stored.push(s.cur);
      } else if (s.state === "RDATA") {
        if (s.phase === "DATA") {
          s.clk += 1;
          if (s.clk === 8) s.readOut.push(s.rbyte);
        } else {
          s.masterAcks.push(sda);
          if (sda === 1) { s.sdaDrv = null; s.state = "IDLE"; s.phase = "DATA"; }
        }
      }
    }
    function onFall() {
      if (s.state === "ADDR" || s.state === "WDATA") {
        if (s.phase === "DATA") {
          if (s.bit === 8) {
            s.phase = "ACK";
            if (s.state === "ADDR") {
              s.matched = (s.cur >> 1) === s.addr;
              s.dirRead = !!(s.cur & 1);
              s.sdaDrv = s.matched ? 0 : null;
              s.stretchArmed = true;
            } else s.sdaDrv = 0;
          }
        } else {
          s.sdaDrv = null; s.phase = "DATA"; s.bit = 0; s.cur = 0;
          if (s.state === "ADDR") {
            if (!s.matched) s.state = "IDLE";
            else if (s.dirRead) { s.state = "RDATA"; s.rbyte = s.rcnt & 0xFF; s.rcnt += 1; s.clk = 0; driveRbit(7); }
            else s.state = "WDATA";
          }
        }
      } else if (s.state === "RDATA") {
        if (s.phase === "DATA") {
          if (s.clk < 8) driveRbit(7 - s.clk);
          else { s.sdaDrv = null; s.phase = "ACK"; }
        } else if (s.phase === "ACK") {
          s.rbyte = s.rcnt & 0xFF; s.rcnt += 1; s.clk = 0; s.phase = "DATA"; driveRbit(7);
        }
      }
    }
    resetLink();
    function peer(sim) {
      var peSclLow = (((sim.pdir >> SCL) & 1) && (((sim.pinDrv >> SCL) & 1) === 0));
      var phys = sim.pinsPhys;
      var scl = (phys >> SCL) & 1, sda = (phys >> SDA) & 1;
      if (s.prev === null) s.prev = [scl, sda];
      var pscl = s.prev[0], psda = s.prev[1];
      if (s.stretchArmed && s.stretchT0 === null && !peSclLow) {
        s.stretchT0 = sim.cycle; s.sclDrv = 0;
      }
      if (s.stretchT0 !== null && s.stretchRel === null) {
        if (sim.cycle - s.stretchT0 >= STRETCH_HOLD) { s.sclDrv = null; s.stretchRel = sim.cycle; }
      }
      if (s.stretchArmed && s.stretchRel !== null && scl === 1) {
        s.stretches.push({ detect: s.stretchT0, release: s.stretchRel, riseSeen: sim.cycle });
        s.stretchArmed = false; s.stretchT0 = null; s.stretchRel = null;
      }
      if (scl && pscl) {
        if (!sda && psda) start();
        else if (sda && !psda) stop();
      }
      if (scl && !pscl) onRise(sda);
      else if (!scl && pscl) onFall();
      s.prev = [scl, sda];
      sim.peerDrv[SCL] = s.sclDrv; sim.peerDrv[SDA] = s.sdaDrv;
    }
    peer.state = s;
    return peer;
  }

  // ---------------------------------------------------------------- 1-Wire
  function onewirePeer(present) {
    var SCRATCH = [0x91, 0x01, 0x4B, 0x46, 0x7F, 0xFF, 0xFF, 0x10, 0xA2];
    var s = { present: present !== false, scratch: SCRATCH.slice(), phase: "IDLE",
      prevWire: 1, lowRun: 0, driveUntil: -1, presenceAt: -1, presenceUntil: -1,
      sampleAt: -1, bits: [], writtenBytes: [], writeSlots: [], readSlots: [],
      readRises: [], readSent: [], events: [], transitions: [], rb: 0, rbit: 0 };
    function onFall(c) {
      if (s.phase === "CMD" || s.phase === "CMD2") {
        s.writeSlots.push({ fall: c, rise: null, bit: null });
        s.sampleAt = c + 1500;
      } else if (s.phase === "READ") {
        var bit = (s.scratch[s.rb] >> s.rbit) & 1;
        s.readSlots.push([c, bit]);
        if (bit === 0) s.driveUntil = c + 3000;
        s.rbit += 1;
        if (s.rbit === 8) {
          s.rbit = 0; s.readSent.push(s.scratch[s.rb]); s.rb = Math.min(s.rb + 1, 8);
        }
      }
    }
    function onRise(c) {
      if (s.phase === "CMD" || s.phase === "CMD2") {
        if (s.writeSlots.length && s.writeSlots[s.writeSlots.length - 1].rise === null)
          s.writeSlots[s.writeSlots.length - 1].rise = c;
      } else if (s.phase === "READ") {
        if (s.readRises.length < s.readSlots.length) s.readRises.push(c);
      }
    }
    function onReset(c) {
      s.driveUntil = -1; s.sampleAt = -1; s.presenceAt = -1; s.presenceUntil = -1;
      s.bits = []; s.rb = 0; s.rbit = 0;
      if (s.present) { s.presenceAt = c + 1500; s.phase = "RESET"; }
      else s.phase = "IDLE";
    }
    function peer(sim) {
      var c = sim.cycle;
      sim.peerDrv[7] = c < s.driveUntil ? 0 : null;
      var wire = (sim.pinsPhys >> 7) & 1;
      if (wire !== s.prevWire) s.transitions.push([c, wire]);
      var fell = s.prevWire === 1 && wire === 0;
      var rose = s.prevWire === 0 && wire === 1;
      if (wire === 0) s.lowRun += 1;
      else {
        if (s.lowRun > 12000) { s.events.push([c, "reset_rise"]); onReset(c); }
        s.lowRun = 0;
      }
      if (fell) onFall(c);
      if (rose) onRise(c);
      if (s.presenceAt >= 0 && s.presenceAt <= c) {
        s.events.push([c, "pres_fall"]); s.driveUntil = c + 6000;
        s.presenceUntil = c + 6000; s.presenceAt = -1; s.phase = "PRESENCE";
      }
      if (s.presenceUntil >= 0 && s.presenceUntil <= c) {
        s.events.push([c, "pres_rise"]); s.presenceUntil = -1; s.driveUntil = -1;
        s.phase = "CMD"; s.bits = [];
      }
      if (s.sampleAt >= 0 && s.sampleAt <= c) {
        var bit = wire === 0 ? 0 : 1;
        s.bits.push(bit);
        if (s.writeSlots.length) s.writeSlots[s.writeSlots.length - 1].bit = bit;
        s.sampleAt = -1;
        if (s.bits.length === 8) {
          var byte = 0;
          for (var i = 0; i < 8; i++) byte |= (s.bits[i] << i);
          s.writtenBytes.push(byte); s.events.push([c, "wbyte_" + byte.toString(16)]);
          if (byte === 0xCC) s.phase = "CMD2";
          else if (s.phase === "CMD2") {
            if (byte === 0xBE) { s.phase = "READ"; s.rb = 0; s.rbit = 0; }
            else s.phase = "CMD";
          }
          s.bits = [];
        }
      }
      s.prevWire = wire;
    }
    peer.state = s;
    return peer;
  }

  // ---------------------------------------------------------------- JTAG
  function jtagTarget() {
    var TCK = 0, TMS = 1, TDI = 2, TDO = 3, IDCODE = 0x1BA00477, IR_CAPTURE = 0xD;
    var NEXT = { TLR: { 0: "RTI", 1: "TLR" }, RTI: { 0: "RTI", 1: "SEL_DR" },
      SEL_DR: { 0: "CAP_DR", 1: "SEL_IR" }, CAP_DR: { 0: "SHIFT_DR", 1: "EXIT1_DR" },
      SHIFT_DR: { 0: "SHIFT_DR", 1: "EXIT1_DR" }, EXIT1_DR: { 0: "PAUSE_DR", 1: "UPDATE_DR" },
      PAUSE_DR: { 0: "PAUSE_DR", 1: "EXIT2_DR" }, EXIT2_DR: { 0: "SHIFT_DR", 1: "UPDATE_DR" },
      UPDATE_DR: { 0: "RTI", 1: "SEL_DR" }, SEL_IR: { 0: "CAP_IR", 1: "TLR" },
      CAP_IR: { 0: "SHIFT_IR", 1: "EXIT1_IR" }, SHIFT_IR: { 0: "SHIFT_IR", 1: "EXIT1_IR" },
      EXIT1_IR: { 0: "PAUSE_IR", 1: "UPDATE_IR" }, PAUSE_IR: { 0: "PAUSE_IR", 1: "EXIT2_IR" },
      EXIT2_IR: { 0: "SHIFT_IR", 1: "UPDATE_IR" }, UPDATE_IR: { 0: "RTI", 1: "SEL_IR" } };
    var s = { state: "TLR", irOp: 1, irShift: 0, drShift: 0, drLen: 32, tdo: null,
      prevTck: 0, irLatches: [], drEpisodes: [], irEpisodes: [], drCnt: 0, irCnt: 0 };
    function peer(sim) {
      var drv = sim.pinDrv, pdir = sim.pdir;
      var tck = ((pdir >> TCK) & 1) ? ((drv >> TCK) & 1) : 0;
      var tms = ((pdir >> TMS) & 1) ? ((drv >> TMS) & 1) : 0;
      var tdi = ((pdir >> TDI) & 1) ? ((drv >> TDI) & 1) : 0;
      if (s.prevTck === 0 && tck === 1) {
        var st = s.state;
        if (st === "CAP_DR") {
          if (s.irOp === 1) { s.drShift = IDCODE; s.drLen = 32; }
          else { s.drShift = 0; s.drLen = 1; }
        } else if (st === "SHIFT_DR") {
          s.drShift = ((s.drShift >> 1) | (tdi << (s.drLen - 1))) & ((1 << s.drLen) - 1);
          s.drCnt += 1;
        } else if (st === "CAP_IR") s.irShift = IR_CAPTURE;
        else if (st === "SHIFT_IR") {
          s.irShift = ((s.irShift >> 1) | (tdi << 3)) & 0xF; s.irCnt += 1;
        } else if (st === "UPDATE_IR") {
          s.irOp = s.irShift & 0xF; s.irLatches.push(s.irOp);
        }
        var nxt = NEXT[st][tms];
        if (st === "SHIFT_DR" && nxt !== "SHIFT_DR") { s.drEpisodes.push(s.drCnt); s.drCnt = 0; }
        if (st === "SHIFT_IR" && nxt !== "SHIFT_IR") { s.irEpisodes.push(s.irCnt); s.irCnt = 0; }
        s.state = nxt;
        if (nxt === "TLR") s.irOp = 1;
      } else if (s.prevTck === 1 && tck === 0) {
        if (s.state === "SHIFT_DR") s.tdo = s.drShift & 1;
        else if (s.state === "SHIFT_IR") s.tdo = s.irShift & 1;
        else s.tdo = null;
      }
      s.prevTck = tck;
      sim.peerDrv[TDO] = s.tdo;
    }
    peer.state = s;
    return peer;
  }

  // ---------------------------------------------------------------- SWD
  function swdTarget() {
    var SWCLK = 0, SWDIO = 1, IDCODE = 0x2BA01477;
    var REQ_BITS = [1, 0, 1, 0, 0, 1, 0, 1], ACK_BITS = [1, 0, 0];
    var DATA_BITS = []; for (var i = 0; i < 32; i++) DATA_BITS.push((IDCODE >> i) & 1);
    var PARITY_BIT = 0; for (var j = 0; j < 32; j++) PARITY_BIT ^= DATA_BITS[j];
    var s = { drive: null, prevClk: 0, state: "reset", onesRun: 0, initialOneRun: 0,
      reqBits: [], driveQueue: [], turnPe: null, turn2Pe: null, riseStates: [] };
    function lineSWDIO(sim) {
      if ((sim.pdir >> SWDIO) & 1) return (sim.pinDrv >> SWDIO) & 1;
      if (s.drive !== null) return s.drive;
      return 0;
    }
    function peer(sim) {
      var clk = (sim.pinDrv >> SWCLK) & 1;
      var rise = s.prevClk === 0 && clk === 1;
      var fall = s.prevClk === 1 && clk === 0;
      if (fall && s.state === "drive") {
        if (s.driveQueue.length) s.drive = s.driveQueue.shift();
        else { s.drive = null; s.state = "turn2"; }
      }
      if (rise) {
        var bit = lineSWDIO(sim);
        s.riseStates.push(s.state);
        if (s.state === "reset") {
          if (bit === 1) s.onesRun += 1;
          else {
            if (s.onesRun >= 50) { s.initialOneRun = s.onesRun; s.reqBits = [1, 0]; s.state = "request"; }
            s.onesRun = 0;
          }
        } else if (s.state === "request") {
          s.reqBits.push(bit);
          if (s.reqBits.length === 8) {
            if (JSON.stringify(s.reqBits) !== JSON.stringify(REQ_BITS))
              throw new Error("SWD model: malformed request bits " + JSON.stringify(s.reqBits));
            var byte = 0; for (var k = 0; k < 8; k++) byte |= (s.reqBits[k] << k);
            if (byte !== 0xA5) throw new Error("SWD model: request byte 0x" + byte.toString(16) + " != 0xA5");
            var par = s.reqBits[1] ^ s.reqBits[2] ^ s.reqBits[3] ^ s.reqBits[4];
            if (par !== s.reqBits[5]) throw new Error("SWD model: request parity bad");
            s.state = "turn1";
          }
        } else if (s.state === "turn1") {
          s.turnPe = [((sim.pdir >> SWDIO) & 1), s.drive];
          s.driveQueue = ACK_BITS.concat(DATA_BITS, [PARITY_BIT]);
          s.state = "drive";
        } else if (s.state === "turn2") {
          s.turn2Pe = [((sim.pdir >> SWDIO) & 1), s.drive];
          s.state = "done";
        }
      }
      s.prevClk = clk;
      sim.peerDrv[SWDIO] = s.drive;
    }
    peer.state = s;
    return peer;
  }

  // ---------------------------------------------------------------- PS/2
  function ps2Keyboard() {
    var CLK = 0, DATA = 1, RX_BYTE = 0x1C, HI_CYC = 2084, LO_CYC = 2083, CELL = HI_CYC + LO_CYC;
    function oddParity(byte) { var n = 0; for (var i = 0; i < 8; i++) n += (byte >> i) & 1; return n % 2 === 0 ? 1 : 0; }
    var s = { frames: [true, false], startDelay: 300, interDelay: 2500, txStartDelay: 800,
      state: "idle", highRun: 0, timer: 0, bits: [], bitIdx: 0, framesSent: 0,
      clkLowRun: 0, lowRunStart: null, rtsCycle: null, inhibitStart: null,
      txBits: [], ackDriven: false, txClock: 0, prevClk: 1, prevData: 1 };
    function frameBits(good) {
      var p = oddParity(RX_BYTE); if (!good) p ^= 1;
      var bits = [0]; for (var i = 0; i < 8; i++) bits.push((RX_BYTE >> i) & 1);
      bits.push(p, 1); return bits;
    }
    function setData(sim, bit) { sim.peerDrv[DATA] = bit === 0 ? 0 : null; }
    function startFrame(sim) {
      var good = s.frames[s.framesSent];
      s.bits = frameBits(good); s.bitIdx = 0;
      setData(sim, s.bits[0]); s.timer = HI_CYC; s.state = "rx_high";
    }
    function peer(sim) {
      var phys = sim.pinsPhys;
      var clk = (phys >> CLK) & 1, data = (phys >> DATA) & 1;
      sim.peerDrv[CLK] = null; sim.peerDrv[DATA] = null;
      if (clk === 0) {
        if (s.prevClk === 1) s.lowRunStart = sim.cycle;
        s.clkLowRun += 1;
      } else {
        if (s.prevClk === 0 && s.state === "tx_armed") { s.timer = s.txStartDelay; s.state = "tx_wait"; }
        s.clkLowRun = 0; s.lowRunStart = null;
      }
      if (s.prevData === 1 && data === 0 && clk === 0 && s.clkLowRun >= 100 && s.state === "idle_done") {
        s.rtsCycle = sim.cycle; s.inhibitStart = s.lowRunStart; s.state = "tx_armed";
      }
      if (s.state === "idle") {
        if (clk === 1 && data === 1) {
          s.highRun += 1;
          if (s.highRun >= s.startDelay && s.frames.length) startFrame(sim);
        } else s.highRun = 0;
      } else if (s.state === "rx_high") {
        setData(sim, s.bits[s.bitIdx]); s.timer -= 1;
        if (s.timer <= 0) { sim.peerDrv[CLK] = 0; s.timer = LO_CYC; s.state = "rx_low"; }
      } else if (s.state === "rx_low") {
        setData(sim, s.bits[s.bitIdx]); sim.peerDrv[CLK] = 0; s.timer -= 1;
        if (s.timer <= 0) {
          s.bitIdx += 1;
          if (s.bitIdx >= s.bits.length) {
            s.framesSent += 1;
            if (s.framesSent < s.frames.length) { s.timer = s.interDelay; s.state = "inter"; }
            else s.state = "idle_done";
          } else { setData(sim, s.bits[s.bitIdx]); s.timer = HI_CYC; s.state = "rx_high"; }
        }
      } else if (s.state === "inter") {
        s.timer -= 1;
        if (s.timer <= 0) startFrame(sim);
      } else if (s.state === "tx_wait") {
        s.timer -= 1;
        if (s.timer <= 0) { s.txClock = 0; s.timer = HI_CYC; s.state = "tx_high"; }
      } else if (s.state === "tx_high") {
        s.timer -= 1;
        if (s.timer <= 0) {
          if (s.txClock < 11) s.txBits.push(data);
          sim.peerDrv[CLK] = 0;
          if (s.txClock === 11) { sim.peerDrv[DATA] = 0; s.ackDriven = true; }
          s.timer = LO_CYC; s.state = "tx_low";
        }
      } else if (s.state === "tx_low") {
        sim.peerDrv[CLK] = 0;
        if (s.txClock === 11) sim.peerDrv[DATA] = 0;
        s.timer -= 1;
        if (s.timer <= 0) {
          s.txClock += 1;
          if (s.txClock >= 12) s.state = "done";
          else { s.timer = HI_CYC; s.state = "tx_high"; }
        }
      }
      s.prevClk = clk; s.prevData = data;
    }
    peer.state = s;
    return peer;
  }

  // ---------------------------------------------------------------- CAN
  function canBus() {
    var TXD = 0, RXD = 1, BIT = 50, ARB_FRAME_IDX = 2, ARB_CELL = 3;
    var s = { prevBus: 1, state: "IDLE", t0: null, frameIdx: -1, nextSample: null,
      rawIdx: 0, destuffed: 0, run: 0, last: null, dlc: null, dlcBits: 0,
      ackWindow: null, arbWindow: null, frameEnd: null };
    function startFrame(cyc) {
      s.state = "FRAME"; s.t0 = cyc; s.frameIdx += 1; s.nextSample = cyc + 25;
      s.rawIdx = 0; s.destuffed = 0; s.run = 0; s.last = null; s.dlc = null;
      s.dlcBits = 0; s.ackWindow = null; s.frameEnd = cyc + 50 * 140;
      if (s.frameIdx === ARB_FRAME_IDX) s.arbWindow = [cyc + ARB_CELL * BIT, cyc + (ARB_CELL + 1) * BIT];
      else s.arbWindow = null;
    }
    function sample(bus) {
      if (s.run === 5) { s.run = 1; s.last = bus; s.rawIdx += 1; return; }
      if (bus === s.last) s.run += 1; else { s.run = 1; s.last = bus; }
      s.destuffed += 1; s.rawIdx += 1;
      if (s.destuffed === 19) s.dlc = s.dlcBits;
      if (s.dlc !== null) {
        var ackDestuffed = 19 + 8 * s.dlc + 15 + 1;
        if (s.destuffed === ackDestuffed) {
          var nxt = s.rawIdx;
          s.ackWindow = [s.t0 + BIT * nxt, s.t0 + BIT * (nxt + 1)];
          s.frameEnd = s.t0 + BIT * (nxt + 13);
        }
      }
    }
    function sampleWithDlc(bus) {
      var isStuff = s.run === 5;
      if (!isStuff) {
        var idx = s.destuffed;
        if (idx >= 15 && idx <= 18) s.dlcBits = (s.dlcBits << 1) | bus;
      }
      sample(bus);
    }
    function peer(sim) {
      var txd = ((sim.pdir >> TXD) & 1) ? ((sim.pinDrv >> TXD) & 1) : 1;
      var cyc = sim.cycle, peerDom = false;
      if (s.ackWindow && s.ackWindow[0] <= cyc && cyc < s.ackWindow[1]) peerDom = true;
      if (s.arbWindow && s.arbWindow[0] <= cyc && cyc < s.arbWindow[1]) peerDom = true;
      var bus = (txd === 0 || peerDom) ? 0 : 1;
      if (s.state === "IDLE") {
        if (cyc >= 60 && s.prevBus === 1 && bus === 0) startFrame(cyc);
      } else if (s.state === "FRAME") {
        if (cyc === s.nextSample) { sampleWithDlc(bus); s.nextSample += BIT; }
        if (cyc >= s.frameEnd) { s.state = "IDLE"; s.ackWindow = null; s.arbWindow = null; }
      }
      s.prevBus = bus;
      sim.peerDrv[RXD] = bus;
    }
    peer.state = s;
    return peer;
  }

  return { spiSlave: spiSlave, uartPeer: uartPeer, usbFullPeer: usbFullPeer,
    i2cSlave: i2cSlave, onewirePeer: onewirePeer, jtagTarget: jtagTarget,
    swdTarget: swdTarget, ps2Keyboard: ps2Keyboard, canBus: canBus };
});
