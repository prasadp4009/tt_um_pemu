// TEMPO web simulator UI — plain JS, no dependencies.
// Playground presentation: transport bar, example cards, live-state
// dashboard, keyboard shortcuts. Simulation behaviour lives in the
// tempo-* modules and is untouched by this file's presentation code.
// Wires tempo-asm.js (assembler), tempo-core.js (PE + Observer) and
// tempo-examples.js / tempo-peers.js (firmware + device models) into the
// docs/simulator.html page. Loaded only in the browser.
(function () {
  if (typeof document === "undefined") return;
  var Asm = window.TempoAsm, Core = window.TempoCore,
    Examples = window.TempoExamples, Peers = window.TempoPeers;
  if (!Asm || !Core || !Examples || !Peers) {
    document.body.innerHTML = "<p>Simulator scripts failed to load.</p>";
    return;
  }
  var $ = function (id) { return document.getElementById(id); };
  var editor = $("sim-editor"), asmErr = $("sim-asm-error"),
    listingEl = $("sim-listing"), exampleList = $("sim-examples"),
    exampleMeta = $("sim-example-meta");

  var current = null; // { example, words, sim, peer }
  var exampleButtons = []; // { ex, btn } for the example-card picker
  var prevRegs = null, prevCycle = -1;
  var loopTimer = null, loopMode = null; // "run" | "free"
  var viewStart = 0, viewWindow = 2000, follow = true;
  var replayTimer = null, replayIdx = 0, replayPlaying = false;

  // Die geometry (docs/assets/layers.json, IMEM-512 GDS run 40699493628):
  // die 1289.28 x 710.64 um, u_imem/u_tmem rects at true GDS positions.
  // Pad markers use the uio_in[i] Metal4.text label anchors (north edge,
  // y = 710.14 um) -- the documented PIN0..PIN7 anchors. uio_in/out/oe
  // are three views of the same 8 uio pins, so one marker per logical pin
  // is the honest representation; these are label anchors, not pad cells.
  var DIE_W = 1289.28, DIE_H = 710.64;
  var MACROS = [{ name: "u_imem", x: 205.68, y: 3.78, w: 416.64, h: 191.57 },
    { name: "u_tmem", x: 1127.36, y: 3.78, w: 146.88, h: 336.69 }];
  var PAD_X = [148.8, 144.96, 141.12, 137.28, 133.44, 129.6, 125.76, 121.92];
  var PAD_Y = 710.14;

  // Theme-aware canvas palette (nav.js TempoTheme) with light fallback.
  function pal() {
    return (window.TempoTheme ? window.TempoTheme.pal() : null) || {
      canvasBg: "#ffffff", grid: "#e2e8f0", label: "#475569",
      die: "#0f172a", core: "#2563eb",
      macroFill: "rgba(254,243,199,0.7)", macroStroke: "#92400e", macroLabel: "#92400e",
      wave: ["#2563eb", "#047857"], trace: "#b45309", cursor: "#dc2626",
      padHigh: "#22c55e", padLow: "#334155", pin: "#dc2626" };
  }

  function fmtNs(cycles) {
    var ns = cycles * 20;
    if (ns < 1000) return ns + " ns";
    var us = ns / 1000;
    return (Math.round(us * 100) / 100) + " µs";
  }
  function hex(v, n) { return "0x" + (v >>> 0).toString(16).toUpperCase().padStart(n, "0"); }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function makePeer(ex) {
    switch (ex.peer) {
      case "spi": return Peers.spiSlave(ex.peerArg || [0xA5, 0x3C]);
      case "uart": return Peers.uartPeer();
      case "usbFull": return Peers.usbFullPeer();
      case "i2c": return Peers.i2cSlave();
      case "onewire": return Peers.onewirePeer(true);
      case "jtag": return Peers.jtagTarget();
      case "swd": return Peers.swdTarget();
      case "ps2": return Peers.ps2Keyboard();
      case "can": return Peers.canBus();
      default: return null;
    }
  }

  function buildSim(ex, words) {
    var sim = new Core.Sim(words);
    var peer = makePeer(ex);
    if (peer) sim.peer = peer;
    if (ex.preload && ex.preload.length) sim.hostPushRxWords(ex.preload);
    return { example: ex, words: words, sim: sim, peer: peer };
  }

  function showAsmError(msg) {
    asmErr.textContent = msg;
    asmErr.style.display = msg ? "block" : "none";
  }

  function assembleCurrent() {
    var src = editor.value;
    try {
      var res = Asm.assemble(src);
      showAsmError("");
      listingEl.textContent = res.listing.map(function (l) {
        return (l.pc === null ? "      " : String(l.pc).padStart(4, " ") + ": ") + l.text;
      }).join("\n");
      return res.words;
    } catch (e) {
      showAsmError("Assemble error: " + e.message);
      return null;
    }
  }

  function loadExample(ex) {
    stopLoop(); stopReplay();
    exampleButtons.forEach(function (e) {
      var on = e.ex === ex;
      e.btn.classList.toggle("active", on);
      e.btn.setAttribute("aria-pressed", on ? "true" : "false");
    });
    editor.value = ex.source;
    var words = assembleCurrent();
    if (words === null) { current = null; renderAll("Assemble failed."); return; }
    current = buildSim(ex, words);
    prevRegs = null; prevCycle = -1; viewStart = 0; follow = true;
    $("sim-follow").checked = true;
    exampleMeta.innerHTML =
      "<strong>" + esc(ex.title) + "</strong> — " + esc(ex.desc) +
      "<br>Pins: <code>" + esc(ex.pins) + "</code>" +
      "<br>Host preload (RX FIFO): " + (ex.preload.length ? ex.preload.map(function (w) { return hex(w, 4); }).join(" ") : "(none)") +
      "<br>Peer model: " + esc(ex.peer === "none" ? "none (firmware drives the pins; no device attached)" : ex.peer) +
      "<br>Proven status: " + esc(ex.proven);
    var howto = $("sim-howto-loaded");
    if (howto) howto.textContent = ex.title + " is loaded.";
    renderAll("Loaded " + ex.title + " (" + words.length + " words). Press Run, Step, or Free-run.");
  }

  function renderState(note) {
    if (!current) {
      var b0 = $("sim-runstate");
      if (b0) { b0.textContent = "NO PROGRAM"; b0.className = "runstate is-ready"; }
      $("sim-state").innerHTML = "<p>No program loaded.</p>"; return;
    }
    var sim = current.sim, snap = sim.snapshot();
    var regsHtml = snap.regs.map(function (v, i) {
      var changed = prevRegs && prevRegs[i] !== v;
      return "<span class=\"reg" + (changed ? " changed" : "") + "\">r" + i + " " + hex(v, 4) + "</span>";
    }).join(" ");
    var bits = snap.statusBits;
    var bitHtml = ["TIMEOUT", "TX_OVERRUN", "RX_UNDERRUN", "TRACE_FULL", "CONFIG_ERR",
      "PE_RUNNING", "PE_HALTED", "TX_EMPTY", "RX_FULL", "TRACE_WM", "CFG_DIRTY"]
      .map(function (b) { return "<span class=\"bit" + (bits[b] ? " on" : "") + "\">" + b + "</span>"; }).join(" ");
    var inFlight = snap.inFlight ? "Executing: <code>" + esc(snap.inFlight) + "</code>" +
      (snap.inFlightRemaining !== null && snap.inFlightRemaining > 1 ? " (" + snap.inFlightRemaining + " cycles left)" : "") + "<br>" : "";
    // Transport-bar run badge: text + shape differ per state, never color alone.
    var runCls = snap.halted ? "is-halted" : (loopTimer ? "is-running" :
      (snap.cycle > 0 ? "is-paused" : "is-ready"));
    var runTxt = snap.halted ? "HALTED" : (loopTimer ? "RUNNING" :
      (snap.cycle > 0 ? "PAUSED" : "READY"));
    var badge = $("sim-runstate");
    if (badge) { badge.textContent = runTxt; badge.className = "runstate " + runCls; }
    // Dashboard layout: same data as before, grouped into labeled cells.
    $("sim-state").innerHTML =
      "<div class=\"regs\">" + regsHtml + "</div>" +
      "<div class=\"state-grid\">" +
      "<div class=\"state-cell\"><span class=\"state-label\">PC · next fetch</span>PC <strong>" + snap.pc + "</strong> — next: <code>" + esc(snap.nextInstr) + "</code><br>" + inFlight + "</div>" +
      "<div class=\"state-cell\"><span class=\"state-label\">Cycle · time</span>Cycle <strong>" + snap.cycle + "</strong> (" + fmtNs(snap.cycle) + ") · Timestamp <strong>" + snap.ts + "</strong> · " +
      (snap.halted ? "<strong class=\"ok\">HALTED</strong>" : "running") +
      " · Flags Z=" + snap.z + " N=" + snap.n + " C=" + snap.c +
      " · STATUS " + hex(snap.status, 4) + "</div>" +
      "<div class=\"state-cell\"><span class=\"state-label\">Pins</span>Pins (physical) <strong>" + hex(snap.pinsPhys, 2) + "</strong> · sync <strong>" + hex(snap.syncPins, 2) + "</strong> · " +
      "PDIR " + hex(snap.pdir, 2) + " · PMASK " + hex(snap.pmask, 2) + " · PMODE " + hex(snap.pmode, 4) +
      " · pin drive " + hex(snap.pinDrv, 2) + "</div>" +
      "<div class=\"state-cell\"><span class=\"state-label\">FIFOs · events</span>TX FIFO (" + snap.txFifo.length + "): " + (snap.txFifo.length ? snap.txFifo.map(function (w) { return hex(w, 4); }).join(" ") : "(empty)") +
      " · RX FIFO (" + snap.rxFifo.length + "): " + (snap.rxFifo.length ? snap.rxFifo.map(function (w) { return hex(w, 4); }).join(" ") : "(empty)") +
      " · EVTFLAG " + hex(snap.evtflag, 4) + "</div>" +
      "<div class=\"state-cell\"><span class=\"state-label\">Observer</span>Observer: " + esc(snap.traceState) + " · trace entries <strong>" + snap.traceLen + " / 204</strong> · CAP events " + snap.capEvents + "</div>" +
      "<div class=\"state-cell status-bits\"><span class=\"state-label\">STATUS bits</span>" + bitHtml + "</div>" +
      "</div>" +
      (note ? "<p class=\"note\">" + esc(note) + "</p>" : "");
    prevRegs = snap.regs.slice(); prevCycle = snap.cycle;
    renderCaps(); renderTrace(); renderActivity();
  }

  // ------------------------------------------------------------- waveform
  function drawWave() {
    var P = pal();
    var cv = $("sim-wave"), ctx = cv.getContext("2d");
    var w = cv.clientWidth || 800, h = 200;
    if (cv.width !== w) cv.width = w;
    cv.height = h;
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = P.canvasBg; ctx.fillRect(0, 0, w, h);
    if (!current) { ctx.fillStyle = P.label; ctx.fillText("No program loaded.", 10, 20); return; }
    var sim = current.sim, hist = sim.history;
    var win = viewWindow === 0 ? Math.max(hist.length, 1) : viewWindow;
    var start = Math.min(viewStart, Math.max(0, hist.length - 1));
    var rowH = h / 8;
    ctx.font = "11px monospace";
    for (var pin = 0; pin < 8; pin++) {
      var y0 = pin * rowH, mid = y0 + rowH / 2;
      ctx.strokeStyle = P.grid; ctx.beginPath(); ctx.moveTo(0, y0); ctx.lineTo(w, y0); ctx.stroke();
      ctx.fillStyle = P.label; ctx.fillText("PIN" + pin, 4, y0 + 12);
      ctx.strokeStyle = P.wave[pin % 2]; ctx.lineWidth = 1.5;
      ctx.beginPath();
      var prev = null;
      for (var px = 40; px < w; px++) {
        var cyc = start + Math.floor((px - 40) / (w - 40) * win) + 1;
        var v = cyc >= 1 && cyc <= hist.length ? (hist[cyc - 1] >> pin) & 1 : 0;
        var y = v ? y0 + 4 : y0 + rowH - 4;
        if (prev === null) ctx.moveTo(px, y);
        else { ctx.lineTo(px, prev); ctx.lineTo(px, y); }
        prev = y;
      }
      ctx.stroke();
    }
    // current-cycle cursor
    if (sim.cycle >= start && sim.cycle <= start + win) {
      var cx = 40 + (sim.cycle - start) / win * (w - 40);
      ctx.strokeStyle = P.cursor; ctx.beginPath(); ctx.moveTo(cx, 0); ctx.lineTo(cx, h); ctx.stroke();
    }
    // time axis labels
    ctx.fillStyle = P.label;
    for (var g = 0; g <= 4; g++) {
      var cycG = Math.round(start + win * g / 4);
      var gx = 40 + (w - 40) * g / 4;
      ctx.fillText("c" + cycG + " (" + fmtNs(cycG) + ")", gx + 2, h - 2);
    }
    $("sim-wave-info").textContent = "Window: cycles " + start + "–" + (start + win) +
      " (" + fmtNs(start) + "–" + fmtNs(start + win) + ") · current cycle " + sim.cycle +
      " · 20 ns/cycle" + (follow ? " · auto-follow ON" : " · auto-follow OFF (manual view)");
  }
  function autoFollow() {
    if (!follow || !current) return;
    var win = viewWindow === 0 ? Math.max(current.sim.history.length, 1) : viewWindow;
    viewStart = Math.max(0, current.sim.cycle - Math.floor(win * 0.85));
    $("sim-scroll").max = Math.max(0, current.sim.history.length - win);
    $("sim-scroll").value = viewStart;
  }
  function renderAll(note) {
    renderState(note);
    drawWave(); drawTracePlot(); drawDie();
  }

  // ------------------------------------------------------------- CAP table
  function renderCaps() {
    if (!current) return;
    var evs = current.sim.capEvents;
    if (!evs.length) { $("sim-caps").innerHTML = "<p>No CAP executed yet.</p>"; return; }
    var rows = evs.map(function (e, i) {
      return "<tr><td>" + i + "</td><td>" + e.cycle + "</td><td>" + e.ts + "</td><td>" +
        hex(e.pins, 2) + "</td><td>r" + e.rd + "</td></tr>";
    }).join("");
    $("sim-caps").innerHTML = "<div class=\"table-scroll\"><table><tr><th>#</th><th>cycle (instr. start)</th><th>timestamp</th><th>pins (sync)</th><th>Rd</th></tr>" + rows + "</table></div>";
  }

  // ------------------------------------------------------------- trace plot
  function drawTracePlot() {
    var P = pal();
    var cv = $("sim-trace-plot"), ctx = cv.getContext("2d");
    var w = cv.clientWidth || 800, h = 180;
    if (cv.width !== w) cv.width = w;
    cv.height = h;
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = P.canvasBg; ctx.fillRect(0, 0, w, h);
    if (!current) return;
    var tr = current.sim.trace;
    $("sim-trace-info").textContent = "Observer state: " + current.sim.traceState() +
      " · entries " + tr.length + " / 204" +
      (tr.length >= 204 ? " · FULL: capture stopped, no wrap, no overwrite (TRACE_FULL sticky set)" :
        tr.length ? "" : " · no entries yet (arm the Observer with MSR: TRIG_MODE, then OBS_CTL OBS_EN)") +
      " · PULSE mode watches PIN 0 only (top-level tie; see note below).";
    if (tr.length < 2) {
      ctx.fillStyle = P.label; ctx.fillText(tr.length ? "One entry captured; need 2+ to draw a stepped plot." : "No trace entries yet.", 10, 20);
      return;
    }
    var t0 = tr[0][0], t1 = tr[tr.length - 1][0], span = Math.max(t1 - t0, 1);
    var rowH = h / 8;
    ctx.font = "11px monospace";
    for (var pin = 0; pin < 8; pin++) {
      var y0 = pin * rowH;
      ctx.strokeStyle = P.grid; ctx.beginPath(); ctx.moveTo(0, y0); ctx.lineTo(w, y0); ctx.stroke();
      ctx.fillStyle = P.label; ctx.fillText("PIN" + pin, 4, y0 + 12);
      ctx.strokeStyle = P.trace; ctx.lineWidth = 1.5; ctx.beginPath();
      for (var i = 0; i < tr.length; i++) {
        var x = 40 + (tr[i][0] - t0) / span * (w - 40);
        var y = ((tr[i][1] >> pin) & 1) ? y0 + 4 : y0 + rowH - 4;
        if (i === 0) ctx.moveTo(x, y); else { ctx.lineTo(x, ctx._ly || y); ctx.lineTo(x, y); }
        ctx._ly = y;
      }
      ctx.stroke(); delete ctx._ly;
    }
    ctx.fillStyle = P.label;
    ctx.fillText("ts " + t0, 42, h - 2);
    ctx.fillText("ts " + t1 + " (" + fmtNs(t1 - t0) + " span)", w - 160, h - 2);
  }
  function renderTrace() {
    if (!current) return;
    var tr = current.sim.trace;
    var rows = tr.map(function (e, i) {
      return "<tr><td>" + i + "</td><td>" + e[0] + "</td><td>" + hex(e[1], 2) + "</td></tr>";
    }).join("");
    $("sim-trace-list").innerHTML = tr.length ?
      "<div class=\"table-scroll\"><table><tr><th>index</th><th>timestamp</th><th>pins</th></tr>" + rows + "</table></div>" :
      "<p>No trace entries yet.</p>";
    drawTracePlot();
  }

  // ------------------------------------------------------------- die activity
  function toggleCounts(hist) {
    var counts = [0, 0, 0, 0, 0, 0, 0, 0], prev = null;
    hist.forEach(function (v) {
      if (prev !== null) for (var p = 0; p < 8; p++)
        if (((v >> p) & 1) !== ((prev >> p) & 1)) counts[p] += 1;
      prev = v;
    });
    return counts;
  }
  function drawDie(histOverride) {
    var P = pal();
    var cv = $("sim-die"), ctx = cv.getContext("2d");
    // The 8 pad anchors span only 26.88 um (2% of the die width) at a
    // 3.84 um pitch, so 11 px circles at true positions overlap into one
    // illegible blob at any canvas width (9x overlap on desktop, 20x on
    // a phone). Instead: true-position ticks on the die's north edge
    // (matching the labeled top view's convention) plus a magnified pad
    // row below the die, in die order, explicitly not to scale.
    var w = cv.clientWidth || 800;
    var s = w / DIE_W;
    var TOPM = 16;   // top margin: room for outward pad ticks
    var STRIP_H = 80; // magnified pad row band below the die
    var h = Math.round(TOPM + DIE_H * s + STRIP_H);
    if (cv.width !== w) cv.width = w;
    cv.height = h;
    function X(x) { return x * s; }
    function Y(y) { return TOPM + (DIE_H - y) * s; } // GDS y-up -> screen y-down
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = P.canvasBg; ctx.fillRect(0, 0, w, h);
    ctx.strokeStyle = P.die; ctx.lineWidth = 2;
    ctx.strokeRect(0, TOPM, DIE_W * s, DIE_H * s);
    ctx.setLineDash([6, 4]); ctx.strokeStyle = P.core;
    ctx.strokeRect(2.88 * s, Y(3.78 + 703.08), 1283.52 * s, 703.08 * s);
    ctx.setLineDash([]);
    MACROS.forEach(function (m) {
      ctx.fillStyle = P.macroFill; ctx.fillRect(X(m.x), Y(m.y + m.h), m.w * s, m.h * s);
      ctx.strokeStyle = P.macroStroke; ctx.strokeRect(X(m.x), Y(m.y + m.h), m.w * s, m.h * s);
      ctx.fillStyle = P.macroLabel; ctx.font = "bold 12px sans-serif"; ctx.textAlign = "center";
      ctx.fillText(m.name, X(m.x + m.w / 2), Y(m.y + m.h) + 16);
    });
    var hist = histOverride !== undefined ? histOverride :
      (current ? current.sim.history : []);
    var cur = hist.length ? hist[hist.length - 1] : 0;
    // True-position ticks: one per pad anchor, outward into the top margin.
    var pinCol = P.pin || "#dc2626";
    ctx.strokeStyle = pinCol; ctx.lineWidth = 2;
    for (var p = 0; p < 8; p++) {
      var tx = X(PAD_X[p]), ty = Y(PAD_Y);
      ctx.beginPath(); ctx.moveTo(tx, ty); ctx.lineTo(tx, ty - 10); ctx.stroke();
    }
    // Magnified pad row: same levels, die order left to right (PIN7
    // leftmost ... PIN0 rightmost, as on the die edge), NOT to scale.
    var stripTop = TOPM + DIE_H * s + 10;
    var cellW = w / 8, rad = Math.max(10, Math.min(15, cellW * 0.32));
    var padY = stripTop + 19 + rad;
    ctx.textAlign = "center";
    ctx.fillStyle = P.label; ctx.font = "11px monospace";
    ctx.fillText("Magnified pad row — left to right PIN7 … PIN0 as on the die edge (not to scale)", w / 2, stripTop + 11);
    for (var i = 0; i < 8; i++) {
      var pin = 7 - i;
      var cx = (i + 0.5) * cellW;
      var lvl = (cur >> pin) & 1;
      ctx.beginPath(); ctx.arc(cx, padY, rad, 0, 7);
      ctx.fillStyle = lvl ? P.padHigh : P.padLow; ctx.fill();
      ctx.strokeStyle = "#fff"; ctx.lineWidth = 2; ctx.stroke();
      ctx.fillStyle = P.label; ctx.font = "11px monospace";
      ctx.fillText("PIN" + pin, cx, padY + rad + 13);
    }
  }
  function renderActivity() {
    if (!current) return;
    var sim = current.sim, hist = sim.history;
    var counts = toggleCounts(hist);
    var cur = hist.length ? hist[hist.length - 1] : 0;
    var rows = counts.map(function (c, p) {
      var rate = sim.cycle ? (c / sim.cycle) : 0;
      return "<tr><td>PIN" + p + "</td><td>uio_in[" + p + "] @ (" + PAD_X[p] + ", " + PAD_Y + ") µm</td><td>" +
        ((cur >> p) & 1) + "</td><td>" + c + "</td><td>" + rate.toFixed(4) + " /cycle</td></tr>";
    }).join("");
    $("sim-activity").innerHTML = "<div class=\"table-scroll\"><table><tr><th>logical pin</th><th>pad anchor (layers.json)</th><th>level</th><th>toggles</th><th>activity rate</th></tr>" + rows + "</table></div>" +
      "<p class=\"caption\">Ticks on the die's north edge are at the true uio_in[i] Metal4.text label anchors " +
      "(layers.json, 45 anchors; uio_in/out/oe are three views of the same 8 uio pins). The magnified pad row " +
      "below the die shows the same 8 pins in die order (PIN7…PIN0 left to right) and is not to scale — " +
      "at true scale the 8 anchors span 26.88 um and individual markers would overlap. " +
      "This is pin-level activity at true pad anchors only — NOT a per-net heatmap: net-level activity " +
      "would need DEF net data plus a VCD and is deliberately not synthesized. The die canvas shows the " +
      "die outline and the two SRAM macros at true GDS rects; full layer polygons live in the " +
      "GDS explorer on the index page.</p>";
    drawDie();
  }

  // ------------------------------------------------------------- run control
  function stopLoop() {
    if (loopTimer) { clearInterval(loopTimer); loopTimer = null; }
    loopMode = null;
    $("sim-pause").textContent = "Pause";
  }
  function loopTick() {
    if (!current) { stopLoop(); return; }
    try {
      var cps = parseInt($("sim-speed").value, 10) || 5000;
      var chunk = loopMode === "run" ? 50000 : Math.max(1, Math.round(cps * 0.05));
      var done = current.sim.runCycles(chunk);
      if (follow) autoFollow();
      renderAll(current.sim.halted ? "Halted." : null);
      if (current.sim.halted) { stopLoop(); renderAll("Halted after " + current.sim.cycle + " cycles."); }
      if (done === 0 && !current.sim.halted) stopLoop();
    } catch (e) {
      stopLoop();
      renderAll("Run stopped: " + e.message);
    }
  }
  function startLoop(mode) {
    if (!current) return;
    if (current.sim.halted) { renderAll("Program already halted — press Reset to run again."); return; }
    stopLoop(); loopMode = mode;
    loopTimer = setInterval(loopTick, 50);
    $("sim-pause").textContent = "Pause";
  }
  function stopReplay() {
    if (replayTimer) { clearInterval(replayTimer); replayTimer = null; }
    replayPlaying = false;
    var b = $("sim-replay"); if (b) b.textContent = "Replay activity";
  }

  // ------------------------------------------------------------- build example list
  // Cards, not a button strip: title + a short status chip derived from
  // the example's proven text (the full proven wording still shows in
  // #sim-example-meta on load — nothing is dropped or reworded).
  Examples.EXAMPLES.forEach(function (ex) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "ex-card";
    var chip = ex.proven.indexOf("Golden") === 0 ? ["Golden PASS", "chip-gold"]
      : ex.proven.indexOf("Teaching") === 0 ? ["Teaching", "chip-teach"]
      : ["Zybo proof", "chip-zybo"];
    b.innerHTML = "<span class=\"ex-title\">" + esc(ex.title) + "</span>" +
      "<span class=\"ex-chip " + chip[1] + "\">" + chip[0] + "</span>";
    b.setAttribute("aria-pressed", "false");
    b.addEventListener("click", function () { loadExample(ex); });
    exampleList.appendChild(b);
    exampleButtons.push({ ex: ex, btn: b });
  });

  // ------------------------------------------------------------- wire controls
  $("sim-load").addEventListener("click", function () {
    var words = assembleCurrent();
    if (words === null) return;
    var ex = current ? current.example : Examples.EXAMPLES[0];
    stopLoop(); stopReplay();
    current = buildSim(ex, words);
    prevRegs = null; viewStart = 0; follow = true; $("sim-follow").checked = true;
    renderAll("Assembled " + words.length + " words (peer + host preload follow the loaded example).");
  });
  $("sim-reset").addEventListener("click", function () {
    if (!current) return;
    stopLoop(); stopReplay();
    current = buildSim(current.example, current.words);
    prevRegs = null; viewStart = 0; follow = true; $("sim-follow").checked = true;
    renderAll("Reset to cycle 0 with a fresh peer model.");
  });
  $("sim-run").addEventListener("click", function () { startLoop("run"); });
  $("sim-free").addEventListener("click", function () { startLoop("free"); });
  $("sim-pause").addEventListener("click", function () {
    if (loopTimer) { stopLoop(); renderAll("Paused at cycle " + current.sim.cycle + "."); }
    else if (current && !current.sim.halted) startLoop(loopMode || "free");
  });
  $("sim-step-cycle").addEventListener("click", function () {
    if (!current) return;
    stopLoop();
    try {
      var ticked = current.sim.tick();
      if (follow) autoFollow();
      renderAll(ticked ? "Stepped exactly 1 cycle." :
        (current.sim.halted ? "HALTED: the HLT base cycle performs no tick (clocks gated) — cycle unchanged, as in the golden model." : "No tick."));
    } catch (e) { renderAll("Step failed: " + e.message); }
  });
  $("sim-step-instr").addEventListener("click", function () {
    if (!current) return;
    stopLoop();
    try {
      var n = current.sim.stepInstruction();
      if (follow) autoFollow();
      renderAll("Step Instruction completed in " + n + " cycle(s)" +
        (current.sim.halted ? " — HALTED." : "."));
    } catch (e) { renderAll("Step failed: " + e.message); }
  });
  $("sim-run-n").addEventListener("click", function () {
    if (!current) return;
    stopLoop();
    var n = parseInt($("sim-ncycles").value, 10);
    if (!(n >= 0)) { renderAll("Run-N needs a non-negative cycle count."); return; }
    try {
      var done = current.sim.runCycles(n);
      if (follow) autoFollow();
      renderAll("Run-N: executed " + done + " of " + n + " requested cycles" +
        (current.sim.halted ? " — HALTED before N (a halted PE cannot advance)." : " — paused at exactly cycle " + current.sim.cycle + "."));
    } catch (e) { renderAll("Run-N failed: " + e.message); }
  });
  $("sim-zoom").addEventListener("change", function () {
    viewWindow = parseInt($("sim-zoom").value, 10);
    follow = $("sim-follow").checked;
    if (follow && current) autoFollow();
    drawWave();
  });
  $("sim-follow").addEventListener("change", function () {
    follow = $("sim-follow").checked;
    if (follow && current) { autoFollow(); drawWave(); }
  });
  $("sim-scroll").addEventListener("input", function () {
    follow = false; $("sim-follow").checked = false;
    viewStart = parseInt($("sim-scroll").value, 10) || 0;
    drawWave();
  });
  $("sim-wave").addEventListener("wheel", function (e) {
    e.preventDefault();
    follow = false; $("sim-follow").checked = false;
    var win = viewWindow === 0 ? Math.max(current ? current.sim.history.length : 1, 1) : viewWindow;
    viewStart = Math.max(0, viewStart + (e.deltaY > 0 ? Math.floor(win / 4) : -Math.floor(win / 4)));
    drawWave();
  }, { passive: false });
  $("sim-scroll-start").addEventListener("click", function () {
    follow = false; $("sim-follow").checked = false; viewStart = 0; drawWave();
  });
  $("sim-scroll-end").addEventListener("click", function () {
    follow = true; $("sim-follow").checked = true;
    if (current) autoFollow(); drawWave();
  });
  $("sim-replay").addEventListener("click", function () {
    if (!current) return;
    if (replayPlaying) { stopReplay(); drawDie(); return; }
    var hist = current.sim.history;
    if (!hist.length) { renderAll("Nothing to replay — run a program first."); return; }
    replayPlaying = true; replayIdx = 0;
    $("sim-replay").textContent = "Stop replay";
    replayTimer = setInterval(function () {
      replayIdx += Math.max(1, Math.floor(hist.length / 200));
      if (replayIdx >= hist.length) { stopReplay(); drawDie(hist); $("sim-replay-info").textContent = "Replay finished at cycle " + hist.length + "."; return; }
      drawDie(hist.slice(0, replayIdx + 1));
      $("sim-replay-info").textContent = "Replaying cycle " + (replayIdx + 1) + " / " + hist.length + ".";
    }, 50);
  });
  $("sim-replay-scrub").addEventListener("input", function () {
    if (!current) return;
    stopReplay();
    var hist = current.sim.history;
    var idx = Math.floor(parseFloat($("sim-replay-scrub").value) / 100 * hist.length);
    drawDie(hist.slice(0, Math.max(1, idx)));
    $("sim-replay-info").textContent = "Scrubbed to cycle " + Math.max(1, idx) + " / " + hist.length + ".";
  });
  // ------------------------------------------------------------- keyboard shortcuts
  // Ignored while typing in the editor/inputs or while a button has focus
  // (so native button activation never double-fires with a shortcut).
  function shortcutTargetEditable(t) {
    if (!t) return false;
    if (t.matches) {
      try {
        if (t.matches("input, textarea, select, button, [contenteditable]")) return true;
      } catch (e) { /* fall through to the tag check */ }
    }
    var tag = (t.tagName || "").toLowerCase();
    return tag === "input" || tag === "textarea" || tag === "select" ||
      tag === "button" || !!t.isContentEditable;
  }
  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (shortcutTargetEditable(e.target)) return;
    if (e.key === " ") {
      e.preventDefault();
      if (loopTimer) { stopLoop(); if (current) renderAll("Paused at cycle " + current.sim.cycle + "."); }
      else if (current && !current.sim.halted) startLoop("free");
      return;
    }
    if (!current) return;
    if (e.key === "s" || e.key === "S") $("sim-step-cycle").click();
    else if (e.key === "i" || e.key === "I") $("sim-step-instr").click();
    else if (e.key === "n" || e.key === "N") $("sim-run-n").click();
    else if (e.key === "r" || e.key === "R") $("sim-reset").click();
  });
  window.addEventListener("resize", function () { drawWave(); drawTracePlot(); drawDie(); });
  if (window.TempoTheme) window.TempoTheme.onChange(function () { renderAll(); });

  // Boot: load SPI first (the golden-validated example).
  loadExample(Examples.EXAMPLES[0]);
})();
