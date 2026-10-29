// Tarang-32 assembler (in-browser port of firmware/tools/asm.py).
// Two-pass, derived from the same encoding contract as asm.py:
// opcode numbers and field lanes are from isa_v0.2.yaml / ISA_v0.2.md.
// Syntax is exactly asm.py's: labels, .org, .word, `, d=N` delay suffix,
// mnemonics pset/psetr/pget/pmask/pdir/pmode/sleep/wait/cap/mov/ldi/
// push/pull/mrs/msr/add/sub/and/or/xor/shl/shr/cmp/jmp/djnz/call/ret/
// hlt/evt. SLEEP/WAIT/HLT reject a nonzero delay (reserved_zero).
// Targets are 9-bit (ISA v0.3 note: target9[8] active, IMEM 512 words).
// No dependencies. UMD: works in the browser (window.TempoAsm) and Node.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.TempoAsm = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var OP = { PSET: 0, PSETR: 1, PGET: 2, PMASK: 3, PDIR: 4, PMODE: 5,
    SLEEP: 6, WAIT: 7, CAP: 8, MOV: 9, LDI: 10, PUSH: 11, PULL: 12,
    MRS: 13, MSR: 14, "ADD/SUB": 15, "AND/OR/XOR": 16, "SHL/SHR": 17,
    CMP: 18, JMP: 19, DJNZ: 20, "CALL/RET": 21, HLT: 22, EVT: 23 };
  // yaml name -> [opcode, reserved_zero?, operand lanes in order]
  var SPEC = {
    PSET: [0, false, ["imm8"]], PSETR: [1, false, ["rs"]],
    PGET: [2, false, ["rd"]], PMASK: [3, false, ["imm8"]],
    PDIR: [4, false, ["imm8"]], PMODE: [5, false, ["rs"]],
    SLEEP: [6, true, ["imm13"]], WAIT: [7, true, ["cfg8", "rd"]],
    CAP: [8, false, ["rd"]], MOV: [9, false, ["rd", "rs"]],
    LDI: [10, false, ["rd", "imm16"]], PUSH: [11, false, ["rs"]],
    PULL: [12, false, ["rd"]], MRS: [13, false, ["rd", "sreg"]],
    MSR: [14, false, ["rs", "sreg"]],
    "ADD/SUB": [15, false, ["rd", "rs1", "rs2", "fn"]],
    "AND/OR/XOR": [16, false, ["rd", "rs1", "rs2", "fn"]],
    "SHL/SHR": [17, false, ["rd", "rs1", "rs2", "fn"]],
    CMP: [18, false, ["rs1", "rs2"]],
    JMP: [19, false, ["target9", "cond4"]],
    DJNZ: [20, false, ["rs", "target9"]],
    "CALL/RET": [21, false, ["target9", "is_ret"]],
    HLT: [22, true, []], EVT: [23, false, ["imm4"]]
  };
  // Field bit positions (msb,lsb) within [20:0], from isa_v0.2.yaml.
  var FIELD_POS = { imm8: [20, 13], rs: [20, 17], rd: [20, 17],
    imm13: [20, 8], cfg8: [20, 13], imm16: [16, 1], sreg: [16, 11],
    rs1: [16, 13], rs2: [12, 9], fn: [8, 7], target9: [20, 12],
    cond4: [11, 8], is_ret: [11, 11], imm4: [20, 17] };
  // DJNZ/CALL target lanes differ from JMP's; handled specially below.
  var MNEMONICS = {
    pset: ["PSET", {}, ["imm8"]], psetr: ["PSETR", {}, ["reg"]],
    pget: ["PGET", {}, ["reg"]], pmask: ["PMASK", {}, ["imm8"]],
    pdir: ["PDIR", {}, ["imm8"]], pmode: ["PMODE", {}, ["reg"]],
    sleep: ["SLEEP", {}, ["imm13"]],
    wait: ["WAIT", {}, ["pin", "pol", "wmode", "tsel", "reg"]],
    cap: ["CAP", {}, ["reg"]], mov: ["MOV", {}, ["reg", "reg"]],
    ldi: ["LDI", {}, ["reg", "imm16"]], push: ["PUSH", {}, ["reg"]],
    pull: ["PULL", {}, ["reg"]], mrs: ["MRS", {}, ["reg", "sreg"]],
    msr: ["MSR", {}, ["reg", "sreg"]],
    add: ["ADD/SUB", { fn: 0 }, ["reg", "reg", "reg"]],
    sub: ["ADD/SUB", { fn: 1 }, ["reg", "reg", "reg"]],
    and: ["AND/OR/XOR", { fn: 0 }, ["reg", "reg", "reg"]],
    or: ["AND/OR/XOR", { fn: 1 }, ["reg", "reg", "reg"]],
    xor: ["AND/OR/XOR", { fn: 2 }, ["reg", "reg", "reg"]],
    shl: ["SHL/SHR", { fn: 0 }, ["reg", "reg", "reg"]],
    shr: ["SHL/SHR", { fn: 1 }, ["reg", "reg", "reg"]],
    cmp: ["CMP", {}, ["reg", "reg"]],
    jmp: ["JMP", {}, ["target", "cond"]],
    djnz: ["DJNZ", {}, ["reg", "target"]],
    call: ["CALL/RET", { is_ret: 0 }, ["target"]],
    ret: ["CALL/RET", { is_ret: 1, target9: 0 }, []],
    hlt: ["HLT", {}, []], evt: ["EVT", {}, ["imm4"]]
  };
  var COND_CODES = { al: 0, z: 1, nz: 2, c: 3, nc: 4, tmo: 5, rxne: 6, txnf: 7 };
  var WAIT_MODES = { level: 0, rising: 1, falling: 2, either: 3 };
  var SREG_NAMES = { STATUS: 0, CYCLES_LO: 1, CYCLES_HI: 2, CTS_HI: 3,
    CTS_PINS: 4, OBS_PTR: 5, PMASKR: 6, PDIRR: 7, PMODER: 8, TRIG_MODE: 9,
    PIN_SEL: 10, MASK: 11, VALUE: 12, EDGE_MASK: 13, EDGE_CFG0: 14,
    EDGE_CFG1: 15, WMARK: 16, PRESCALER: 17, OBS_CTL: 18, EVTFLAG: 19 };

  function AsmError(msg) { this.message = msg; this.name = "AsmError"; }
  AsmError.prototype = new Error();

  function parseNum(tok, lo, hi, what) {
    var t = tok.trim(), v;
    if (/^0x[0-9a-fA-F]+$/.test(t)) v = parseInt(t, 16);
    else if (/^0b[01]+$/.test(t)) v = parseInt(t.slice(2), 2);
    else if (/^-?\d+$/.test(t)) v = parseInt(t, 10);
    else throw new AsmError(what + ": bad number '" + tok + "'");
    if (!(lo <= v && v <= hi))
      throw new AsmError(what + ": " + v + " out of range [" + lo + ".." + hi + "]");
    return v;
  }
  function parseReg(tok) {
    var m = /^r(\d+)$/i.exec(tok.trim());
    if (!m) throw new AsmError("bad register '" + tok + "'");
    return parseNum(m[1], 0, 15, "register");
  }
  function parseSreg(tok) {
    var t = tok.trim();
    if (/^r\d+$/i.test(t))
      throw new AsmError("sreg operand looks like a register: '" + t + "'");
    var up = t.toUpperCase();
    if (up in SREG_NAMES) return SREG_NAMES[up];
    return parseNum(t, 0, 63, "sreg");
  }

  function encode(yamlName, delay, fieldVals) {
    var spec = SPEC[yamlName];
    if (spec[1] && delay !== 0)
      throw new AsmError(yamlName + ": delay field is reserved_zero");
    if (!(0 <= delay && delay <= 31))
      throw new AsmError("delay " + delay + " out of range 0..31");
    var word = ((spec[0] << 26) >>> 0) | (delay << 21);
    var lanes = spec[2];
    for (var i = 0; i < lanes.length; i++) {
      var lane = lanes[i];
      if (!(lane in fieldVals))
        throw new AsmError(yamlName + ": missing field '" + lane + "'");
      var pos = FIELD_POS[lane];
      // Per-instruction lanes that differ from the generic FIELD_POS table:
      // MOV rs is [16:13] (not the [20:17] single-source lane); CMP rs1/rs2
      // are [20:17]/[16:13] (not the ALU [16:13]/[12:9] lanes).
      if (yamlName === "MOV" && lane === "rs") pos = [16, 13];
      if (yamlName === "WAIT" && lane === "rd") pos = [12, 9];
      if (yamlName === "CMP" && lane === "rs1") pos = [20, 17];
      if (yamlName === "CMP" && lane === "rs2") pos = [16, 13];
      // AND/OR/XOR fn is 2 bits at [8:7]; ADD/SUB/SHL fn is 1 bit at [8].
      var msb = pos[0], lsb = pos[1];
      if (yamlName === "AND/OR/XOR" && lane === "fn") { msb = 8; lsb = 7; }
      if ((yamlName === "ADD/SUB" || yamlName === "SHL/SHR") && lane === "fn") { msb = 8; lsb = 8; }
      var w = msb - lsb + 1, v = fieldVals[lane];
      if (!(0 <= v && v < (1 << w)))
        throw new AsmError(yamlName + "." + lane + ": " + v + " does not fit in " + w + " bits");
      word |= (v << lsb);
    }
    return word >>> 0;
  }

  function operand(kind, tok, labels, mnemonic) {
    tok = tok.trim();
    if (kind === "reg") return parseReg(tok);
    if (kind === "imm8") return parseNum(tok, 0, 255, mnemonic);
    if (kind === "imm13") return parseNum(tok, 0, 8191, mnemonic);
    if (kind === "imm16") return parseNum(tok, 0, 65535, mnemonic);
    if (kind === "imm4") return parseNum(tok, 0, 15, mnemonic);
    if (kind === "sreg") return parseSreg(tok);
    if (kind === "cond") {
      var c = tok.toLowerCase();
      if (!(c in COND_CODES)) throw new AsmError(mnemonic + ": bad condition '" + tok + "'");
      return COND_CODES[c];
    }
    if (kind === "target") {
      if (tok in labels) return labels[tok];
      return parseNum(tok, 0, 511, mnemonic + " target");
    }
    if (kind === "pin") return parseNum(tok, 0, 7, "wait pin");
    if (kind === "pol") return parseNum(tok, 0, 1, "wait pol");
    if (kind === "wmode") {
      var m = tok.toLowerCase();
      if (!(m in WAIT_MODES)) throw new AsmError("wait: bad mode '" + tok + "' (level|rising|falling|either)");
      return WAIT_MODES[m];
    }
    if (kind === "tsel") return parseNum(tok, 0, 3, "wait tsel");
    throw new AsmError("internal: unknown operand kind " + kind);
  }

  function asmLine(mnemonic, operands, delay, labels) {
    if (!(mnemonic in MNEMONICS))
      throw new AsmError("unknown mnemonic '" + mnemonic + "'");
    var entry = MNEMONICS[mnemonic];
    var yamlName = entry[0], fixed = entry[1], kinds = entry[2];
    if (mnemonic === "jmp" && operands.length === 1) operands = operands.concat(["al"]);
    if (delay === null || delay === undefined) delay = 0;
    if (mnemonic === "wait") {
      if (operands.length !== 5)
        throw new AsmError("wait: want 5 operands: pin, pol, mode, tsel, rd");
      var pin = operand("pin", operands[0], labels, mnemonic);
      var pol = operand("pol", operands[1], labels, mnemonic);
      var mode = operand("wmode", operands[2], labels, mnemonic);
      var tsel = operand("tsel", operands[3], labels, mnemonic);
      var rd = operand("reg", operands[4], labels, mnemonic);
      var cfg8 = (pin << 5) | (pol << 4) | (mode << 2) | tsel;
      return encode(yamlName, delay, { cfg8: cfg8, rd: rd });
    }
    if (operands.length !== kinds.length)
      throw new AsmError(mnemonic + ": want " + kinds.length + " operands, got " + operands.length);
    // Map operands onto YAML lanes positionally, skipping fixed fields.
    // Lane order per instruction (YAML field order, with DJNZ/CALL
    // target lanes at [16:8] / [20:12] respectively):
    var laneOrder = {
      PSET: ["imm8"], PSETR: ["rs"], PGET: ["rd"], PMASK: ["imm8"],
      PDIR: ["imm8"], PMODE: ["rs"], SLEEP: ["imm13"], CAP: ["rd"],
      MOV: ["rd", "rs"], LDI: ["rd", "imm16"], PUSH: ["rs"], PULL: ["rd"],
      MRS: ["rd", "sreg"], MSR: ["rs", "sreg"],
      "ADD/SUB": ["rd", "rs1", "rs2", "fn"],
      "AND/OR/XOR": ["rd", "rs1", "rs2", "fn"],
      "SHL/SHR": ["rd", "rs1", "rs2", "fn"],
      CMP: ["rs1", "rs2"], JMP: ["target9", "cond4"],
      DJNZ: ["rs", "target9"], "CALL/RET": ["target9", "is_ret"],
      HLT: [], EVT: ["imm4"]
    }[yamlName];
    var need = [];
    for (var i = 0; i < laneOrder.length; i++)
      if (!(laneOrder[i] in fixed)) need.push(laneOrder[i]);
    if (need.length !== kinds.length)
      throw new AsmError("internal: " + mnemonic + " lane/kind mismatch");
    var fv = {};
    for (var k in fixed) fv[k] = fixed[k];
    for (var j = 0; j < kinds.length; j++)
      fv[need[j]] = operand(kinds[j], operands[j], labels, mnemonic);
    if (yamlName === "LDI" && (fv.imm16 & 1))
      throw new AsmError("ldi: imm16 bit0 is reserved, immediate must be even");
    if ((yamlName === "JMP" || yamlName === "DJNZ" || yamlName === "CALL/RET") &&
        fv.target9 !== undefined && fv.target9 > 511)
      throw new AsmError(mnemonic + ": target " + fv.target9 + " out of range (9-bit target9, max 511)");
    // DJNZ target9 lives at [16:8], not [20:12]: re-encode with its lane.
    if (yamlName === "DJNZ") {
      var spec = SPEC.DJNZ;
      if (spec[1] && delay !== 0) throw new AsmError("DJNZ: delay field is reserved_zero");
      var w = ((spec[0] << 26) >>> 0) | (delay << 21);
      w |= (fv.rs << 17) | (fv.target9 << 8);
      return w >>> 0;
    }
    return encode(yamlName, delay, fv);
  }

  function assemble(src) {
    var labels = {}, addr = 0, stmts = [];
    var lines = src.split(/\r?\n/);
    for (var li = 0; li < lines.length; li++) {
      var ln = li + 1;
      var line = lines[li].split(";")[0].trim();
      if (!line) continue;
      var m;
      while ((m = /^([A-Za-z_]\w*):\s*(.*)$/.exec(line)) !== null) {
        var name = m[1]; line = m[2].trim();
        if (name in labels)
          throw new AsmError("line " + ln + ": duplicate label '" + name + "'");
        labels[name] = addr;
      }
      if (!line) continue;
      m = /^\.org\s+(\S+)/i.exec(line);
      if (m) {
        try { addr = parseNum(m[1], 0, 511, ".org"); }
        catch (e) { throw new AsmError("line " + ln + ": " + e.message); }
        stmts.push({ ln: ln, kind: "org", val: addr });
        continue;
      }
      m = /^\.word\s+(\S+)/i.exec(line);
      if (m) {
        var wv;
        try { wv = parseNum(m[1], 0, 0xFFFFFFFF, ".word"); }
        catch (e) { throw new AsmError("line " + ln + ": " + e.message); }
        stmts.push({ ln: ln, kind: "word", val: wv });
        addr += 1;
        continue;
      }
      m = /^([A-Za-z]+)\s*(.*)$/.exec(line);
      if (!m) throw new AsmError("line " + ln + ": cannot parse '" + line + "'");
      var mnemonic = m[1].toLowerCase(), rest = m[2].trim(), delay = null;
      var dm = /,\s*d\s*=\s*(\d+)\s*$/.exec(rest);
      if (dm) { delay = parseInt(dm[1], 10); rest = rest.slice(0, dm.index).trim(); }
      var operands = rest ? rest.split(",").map(function (o) { return o.trim(); }) : [];
      stmts.push({ ln: ln, kind: "insn", mnemonic: mnemonic, operands: operands, delay: delay });
      addr += 1;
    }
    if (addr > 512)
      throw new AsmError("image is " + addr + " words, exceeds 512-word IMEM");
    var byAddr = {}, listing = [], pc = 0;
    for (var s = 0; s < stmts.length; s++) {
      var st = stmts[s];
      if (st.kind === "org") { pc = st.val; listing.push({ pc: null, text: ".org " + pc }); continue; }
      if (st.kind === "word") {
        byAddr[pc] = st.val;
        listing.push({ pc: pc, text: ".word 0x" + (st.val >>> 0).toString(16).padStart(8, "0") });
        pc += 1; continue;
      }
      var word;
      try { word = asmLine(st.mnemonic, st.operands.slice(), st.delay, labels); }
      catch (e) { throw new AsmError("line " + st.ln + ": " + e.message); }
      byAddr[pc] = word;
      listing.push({ pc: pc, text: st.mnemonic + (st.operands.length ? " " + st.operands.join(", ") : "") +
        (st.delay ? ", d=" + st.delay : "") });
      pc += 1;
    }
    var top = -1;
    for (var a in byAddr) { var ai = +a; if (ai > top) top = ai; }
    var words = [];
    if (top >= 0) for (var i = 0; i <= top; i++) words.push(byAddr[i] !== undefined ? byAddr[i] : 0);
    return { words: words, listing: listing, labels: labels };
  }

  return { assemble: assemble, AsmError: AsmError, SREG_NAMES: SREG_NAMES,
    COND_CODES: COND_CODES, WAIT_MODES: WAIT_MODES, OP: OP };
});
