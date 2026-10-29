// 2D GDS top-view explorer — canvas 2D, no dependencies.
// Data: assets/layers.json (IMEM-512 GDS, run 40699493628). Coordinates
// are um, GDS orientation (origin die lower-left, y up). Layer visibility
// state is shared with the 3D view via window.TempoLayers.
(function () {
  var cv = document.getElementById("explorer-canvas");
  if (!cv) return;
  var ctx = cv.getContext("2d");
  var readout = document.getElementById("explorer-readout");
  var info = document.getElementById("explorer-info");
  var listEl = document.getElementById("layer-list");
  var statusEl = document.getElementById("explorer-status");

  var data = null, paths = {};   // layer id -> Path2D
  var scale = 1, ox = 0, panY = 0, dieW = 1289.28, dieH = 710.64;
  var hoverPin = null;

  // Theme-aware canvas palette (nav.js TempoTheme). Falls back to the old
  // light colors if the theme module is absent, so the view never breaks.
  function pal() {
    return (window.TempoTheme ? window.TempoTheme.pal() : null) || {
      canvasBg: "#ffffff", die: "#0f172a", core: "#2563eb",
      macroFill: "rgba(254,243,199,0.55)", macroStroke: "#92400e",
      macroLabel: "#92400e", pin: "#dc2626" };
  }

  function meta(id) {
    for (var i = 0; i < window.TempoLayers.META.length; i++)
      if (window.TempoLayers.META[i].id === id) return window.TempoLayers.META[i];
    return null;
  }
  function fit() {
    var r = cv.getBoundingClientRect();
    scale = Math.min((r.width - 24) / dieW, (r.height - 24) / dieH);
    ox = (r.width - dieW * scale) / 2;
    panY = (r.height - dieH * scale) / 2;
  }
  function resize() {
    // Backing store in CSS pixels (not device pixels) so canvas
    // coordinates match getBoundingClientRect() throughout.
    var r = cv.getBoundingClientRect();
    cv.width = Math.round(r.width); cv.height = Math.round(r.height);
    fit(); draw();
  }
  function applyTransform() {
    // world (um, y up) -> screen: x' = ox + x*s, y' = panY + (dieH - y)*s
    ctx.setTransform(scale, 0, 0, -scale, ox, panY + dieH * scale);
  }
  function toWorld(mx, my) {
    var r = cv.getBoundingClientRect();
    return { x: (mx - ox) / scale, y: dieH - (my - panY) / scale };
  }
  function buildPaths() {
    data.layers.forEach(function (L) {
      var m = meta(L.id) || {};
      var p = new Path2D();
      (L.polygons || []).forEach(function (poly) {
        for (var i = 0; i + 1 < poly.length; i += 2) {
          if (i === 0) p.moveTo(poly[i], poly[i + 1]);
          else p.lineTo(poly[i], poly[i + 1]);
        }
        p.closePath();
      });
      paths[L.id] = { path: p, color: m.color || "#888" };
    });
  }
  function draw() {
    if (!data) return;
    var P = pal();
    var r = cv.getBoundingClientRect();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, r.width, r.height);
    ctx.fillStyle = P.canvasBg; ctx.fillRect(0, 0, r.width, r.height);
    applyTransform();
    // layers bottom->top as shipped
    data.layers.forEach(function (L) {
      if (!window.TempoLayers.state.visible[L.id]) return;
      ctx.fillStyle = paths[L.id].color;
      ctx.globalAlpha = 0.72;
      ctx.fill(paths[L.id].path);
    });
    ctx.globalAlpha = 1;
    // core outline
    var c = data.core;
    ctx.strokeStyle = P.core; ctx.lineWidth = 1.5 / scale;
    ctx.setLineDash([8 / scale, 5 / scale]);
    ctx.strokeRect(c[0], c[1], c[2], c[3]);
    ctx.setLineDash([]);
    // die outline
    ctx.strokeStyle = P.die; ctx.lineWidth = 2 / scale;
    ctx.strokeRect(0, 0, dieW, dieH);
    // macros
    if (window.TempoLayers.state.showMacros) {
      window.TempoLayers.MACROS.forEach(function (m) {
        ctx.fillStyle = P.macroFill;
        ctx.fillRect(m.x, m.y, m.w, m.h);
        ctx.strokeStyle = P.macroStroke; ctx.lineWidth = 2 / scale;
        ctx.strokeRect(m.x, m.y, m.w, m.h);
      });
    }
    // pins
    if (window.TempoLayers.state.showPins) {
      ctx.fillStyle = P.pin;
      (data.pins || []).forEach(function (p) {
        ctx.beginPath(); ctx.arc(p.x, p.y, 4 / scale, 0, 7); ctx.fill();
      });
    }
    // screen-space labels for macros (unscaled text)
    if (window.TempoLayers.state.showMacros) {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.font = "bold 13px sans-serif"; ctx.fillStyle = P.macroLabel;
      ctx.textAlign = "center";
      window.TempoLayers.MACROS.forEach(function (m) {
        var sx = ox + (m.x + m.w / 2) * scale;
        var sy = panY + (dieH - (m.y + m.h)) * scale + 18;
        ctx.fillText(m.name, sx, sy);
      });
    }
  }
  function showInfo(html) { info.innerHTML = html; }
  function layerInfo(L) {
    var m = meta(L.id) || {};
    showInfo("<h4>" + (m.name || L.name) + " — GDS " + (L.gds || m.gds) +
      "</h4><p>Role: " + (m.role || L.role || "") +
      "<br>Polygons shipped: " + (L.polygons || []).length +
      " (manifest count: " + (m.polys || "?") + ")" +
      "<br>Stack z (schematic): " + L.z + ", thickness class " + L.thick +
      "<br>Fidelity: " + (m.fidelity || L.repr || "") + "</p>");
  }
  function buildList() {
    listEl.innerHTML = "";
    data.layers.forEach(function (L) {
      var m = meta(L.id) || {};
      var wrap = document.createElement("span");
      var cb = document.createElement("input");
      cb.type = "checkbox"; cb.checked = !!window.TempoLayers.state.visible[L.id];
      cb.addEventListener("change", function () {
        window.TempoLayers.set(L.id, cb.checked);
      });
      var name = document.createElement("a");
      name.href = "#"; name.textContent = (m.name || L.name) + " (" + (L.gds || m.gds) + ")";
      name.addEventListener("click", function (e) { e.preventDefault(); layerInfo(L); });
      var solo = document.createElement("button");
      solo.className = "solo"; solo.textContent = "solo";
      solo.addEventListener("click", function () {
        window.TempoLayers.solo(L.id);
        syncList(); layerInfo(L);
      });
      wrap.appendChild(cb); wrap.appendChild(document.createTextNode(" "));
      wrap.appendChild(name); wrap.appendChild(solo);
      listEl.appendChild(wrap);
    });
  }
  function syncList() {
    var cbs = listEl.querySelectorAll("input[type=checkbox]");
    data.layers.forEach(function (L, i) {
      if (cbs[i]) cbs[i].checked = !!window.TempoLayers.state.visible[L.id];
    });
    draw();
    if (window.TempoDraw3D) window.TempoDraw3D();
  }
  window.TempoLayers.onChange(syncList);
  if (window.TempoTheme) window.TempoTheme.onChange(draw);

  document.getElementById("btn-all").addEventListener("click", function () {
    window.TempoLayers.preset("all"); syncList();
  });
  document.getElementById("btn-none").addEventListener("click", function () {
    window.TempoLayers.preset("none"); syncList();
  });
  document.getElementById("btn-metals").addEventListener("click", function () {
    window.TempoLayers.preset("metals"); syncList();
  });
  document.getElementById("btn-reset-view").addEventListener("click", function () {
    fit(); draw();
  });
  document.getElementById("chk-macros").addEventListener("change", function (e) {
    window.TempoLayers.state.showMacros = e.target.checked; draw();
  });
  document.getElementById("chk-pins").addEventListener("change", function (e) {
    window.TempoLayers.state.showPins = e.target.checked; draw();
  });

  // Pointer events (mouse + touch + pen): one pointer drags to pan, two
  // pointers pinch to zoom. This was mouse-only before, so on a phone a
  // touch drag did nothing at all — and touch-action: none also blocked
  // page scroll over the canvas. Mouse behaviour is unchanged: a mouse
  // drag pans, the wheel zooms, hover still probes. On touch, swipe
  // outside the canvas to scroll the page (the caption says so).
  var pointers = new Map(), lastPinch = 0;
  function probe(mx, my) {
    var w = toWorld(mx, my);
    var txt = "x = " + w.x.toFixed(1) + " um, y = " + w.y.toFixed(1) + " um (GDS, y up)";
    // nearest pin within 10 um
    var best = null, bd = 1e9;
    (data.pins || []).forEach(function (p) {
      var d = Math.hypot(p.x - w.x, p.y - w.y);
      if (d < bd) { bd = d; best = p; }
    });
    if (best && bd < 10) txt += "  |  pin: " + best.name;
    // macro hit
    window.TempoLayers.MACROS.forEach(function (m) {
      if (w.x >= m.x && w.x <= m.x + m.w && w.y >= m.y && w.y <= m.y + m.h)
        txt += "  |  macro: " + m.name + " (" + m.cell + ")";
    });
    readout.textContent = txt;
  }
  cv.addEventListener("pointerdown", function (e) {
    try { cv.setPointerCapture(e.pointerId); } catch (err) { /* no capture: drag still tracks while over the canvas */ }
    pointers.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
    if (pointers.size === 2) {
      var pts = Array.from(pointers.values());
      lastPinch = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
    }
  });
  ["pointerup", "pointercancel"].forEach(function (t) {
    cv.addEventListener(t, function (e) {
      pointers.delete(e.pointerId);
      if (pointers.size < 2) lastPinch = 0;
    });
  });
  cv.addEventListener("pointermove", function (e) {
    if (!pointers.has(e.pointerId)) { probe(e.offsetX, e.offsetY); return; }
    var prev = pointers.get(e.pointerId);
    pointers.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
    if (pointers.size === 2) {
      var pts = Array.from(pointers.values());
      var d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      if (lastPinch > 0) {
        var mid = { x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2 };
        var w = toWorld(mid.x, mid.y);
        scale *= d / lastPinch;
        ox = mid.x - w.x * scale;
        panY = mid.y - (dieH - w.y) * scale;
        draw();
      }
      lastPinch = d;
      return;
    }
    ox += e.offsetX - prev.x; panY += e.offsetY - prev.y; draw();
    probe(e.offsetX, e.offsetY);
  });
  cv.addEventListener("wheel", function (e) {
    e.preventDefault();
    var f = e.deltaY < 0 ? 1.15 : 1 / 1.15;
    var w = toWorld(e.offsetX, e.offsetY);
    scale *= f;
    ox = e.offsetX - w.x * scale;
    panY = e.offsetY - (dieH - w.y) * scale;
    draw();
  }, { passive: false });
  cv.addEventListener("click", function (e) {
    var w = toWorld(e.offsetX, e.offsetY);
    window.TempoLayers.MACROS.forEach(function (m) {
      if (w.x >= m.x && w.x <= m.x + m.w && w.y >= m.y && w.y <= m.y + m.h) {
        showInfo("<h4>" + m.name + " — " + m.cell + "</h4><p>Footprint: " +
          m.w + " x " + m.h + " um at (" + m.x + ", " + m.y + "), orientation " +
          m.orient + ".<br>" + m.note + "</p>");
      }
    });
  });
  window.addEventListener("resize", resize);

  fetch("assets/layers.json").then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (j) {
    data = j; dieW = j.die[0]; dieH = j.die[1];
    var total = 0;
    j.layers.forEach(function (L) { total += (L.polygons || []).length; });
    statusEl.textContent = "Loaded: " + j.layers.length + " layers, " +
      total.toLocaleString("en-US") + " shipped polygons, " +
      (j.pins || []).length + " pin label anchors. Die " +
      dieW + " x " + dieH + " um. Drag to pan, scroll or pinch to zoom.";
    buildPaths(); buildList(); resize();
    showInfo("<h4>GDS explorer</h4><p>Toggle layers, solo one layer, or use " +
      "All / None / Metals. Click a layer name for its GDS number, polygon " +
      "count, and fidelity class. Click a gold macro block for its facts. " +
      "The same toggles drive the 3D stack view below.</p>");
  }).catch(function (err) {
    statusEl.textContent = "Failed to load assets/layers.json: " + err.message;
  });
})();
