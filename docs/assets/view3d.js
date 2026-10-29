// Interactive 3D exploded-stack view — canvas 2D isometric projection.
// No WebGL, no external libraries. Each GDS layer is rasterized once from
// its true polygons (assets/layers.json) and drawn as an affine-mapped
// slab; the two SRAM macros are drawn as vector extrusions at their true
// footprints. Layer visibility is shared with the 2D explorer via
// window.TempoLayers. Z heights are SCHEMATIC (layers.json z/thick are
// relative units, not physical um) -- the explode slider separates slabs
// for inspection; it is not a scale model of the process stack.
(function () {
  var cv = document.getElementById("view3d-canvas");
  if (!cv) return;
  var ctx = cv.getContext("2d");
  var readout = document.getElementById("view3d-readout");
  var info = document.getElementById("view3d-info");
  var explodeEl = document.getElementById("explode-slider");
  var explodeVal = document.getElementById("explode-value");

  var data = null, rasters = {};   // layer id -> offscreen canvas
  var dieW = 1289.28, dieH = 710.64;

  // Theme-aware canvas palette (nav.js TempoTheme) with light fallback.
  function pal() {
    return (window.TempoTheme ? window.TempoTheme.pal() : null) || {
      canvasBg: "#ffffff",
      macro3d: { side1: "#b45309", side2: "#92400e", top: "#fde68a", topStroke: "#92400e", topLabel: "#451a03" } };
  }
  var DEFAULT_EXPLODE = 10;  // gaps alone at 30 px/layer (540 px) exceed
  // most canvases, so the default must be one the fit can actually fit:
  // 10 fits both the 1100x560 desktop canvas and the 360x380 phone canvas
  // exactly at the 32 px margin (larger defaults clip on the phone).
  var az = -0.6, el = 35 * Math.PI / 180, zoom = 1, explode = DEFAULT_EXPLODE;
  var cx = 0, cy = 0;              // pan offset (screen px)
  var pointers = new Map(), lastPinch = 0;
  var fitted = false;              // true once the stack has been fitted to the canvas

  function meta(id) {
    for (var i = 0; i < window.TempoLayers.META.length; i++)
      if (window.TempoLayers.META[i].id === id) return window.TempoLayers.META[i];
    return null;
  }
  // Project a die point (um, y up) at slab height z (screen px) to screen.
  // zm overrides the global zoom (used by fitStack to measure at zoom 1).
  function proj(x, y, z, zm) {
    var r = cv.getBoundingClientRect();
    var ox = r.width / 2 + cx, oy = r.height * 0.52 + cy;
    var dx = x - dieW / 2, dy = y - dieH / 2;
    var rx = Math.cos(az) * dx - Math.sin(az) * dy;
    var ry = Math.sin(az) * dx + Math.cos(az) * dy;
    var s = 0.42 * (zm === undefined ? zoom : zm);
    return {
      x: ox + (rx - ry) * Math.cos(Math.PI / 6) * s,
      y: oy + (rx + ry) * Math.sin(el) * s - z
    };
  }
  function layerZ(i) { return i * (4 + explode); }
  // Projected bounds of the whole stack (die corners at the bottom slab
  // and at the top slab + macro block height), at the given zoom.
  function stackBounds(zm) {
    var zMax = layerZ(data.layers.length - 1) + 30;
    var pts = [];
    [[0, 0], [dieW, 0], [dieW, dieH], [0, dieH]].forEach(function (c) {
      pts.push(proj(c[0], c[1], 0, zm)); pts.push(proj(c[0], c[1], zMax, zm));
    });
    var xs = pts.map(function (p) { return p.x; });
    var ys = pts.map(function (p) { return p.y; });
    return { minX: Math.min.apply(null, xs), maxX: Math.max.apply(null, xs),
             minY: Math.min.apply(null, ys), maxY: Math.max.apply(null, ys) };
  }
  // Fit the whole stack into the canvas. proj() subtracts z in raw screen
  // px, NOT scaled by zoom, so the explode gaps are zoom-invariant: the
  // stack height at zoom z is slabH*z + zMax, not (slabH + zMax)*z. A fit
  // that scales the whole bounds by zoom therefore never fits at large
  // explode (at explode 30 the gaps alone are 540 px on a 560 px canvas,
  // so no zoom can fit the stack). The height fit below divides only the
  // slab part by zoom: fitZoomH = (H - 32 - zMax) / slabH1. When the gaps
  // alone exceed the canvas (explode too large), zoom clamps at 0.3 and
  // the stack is centered, so clipping is symmetric; Reset restores the
  // default explode and refits to a full view. setZoom=true (load, Reset)
  // fits zoom exactly; setZoom=false (explode change) only ever shrinks
  // zoom and recenters, so it never yanks a user's deliberate zoom-out.
  function fitStack(setZoom) {
    if (!data) return false;
    var r = cv.getBoundingClientRect();
    if (r.width < 10 || r.height < 10) return false;
    var zMax = layerZ(data.layers.length - 1) + 30;
    var b1 = stackBounds(1);
    var slabW1 = b1.maxX - b1.minX;
    var slabH1 = (b1.maxY - b1.minY) - zMax;
    var fitZoom = Math.min((r.width - 32) / slabW1,
                           (r.height - 32 - zMax) / slabH1);
    fitZoom = Math.max(0.3, Math.min(6, fitZoom));
    if (setZoom) zoom = fitZoom; else zoom = Math.min(zoom, fitZoom);
    var b = stackBounds(zoom);
    cx += r.width / 2 - (b.minX + b.maxX) / 2;
    cy += r.height / 2 - (b.minY + b.maxY) / 2;
    return true;
  }
  function stackVisible() {
    if (!data) return true;
    var r = cv.getBoundingClientRect();
    var b = stackBounds(zoom);
    return !(b.maxY < 0 || b.minY > r.height || b.maxX < 0 || b.minX > r.width);
  }
  function rasterize() {
    var RW = 1024, RH = Math.round(1024 * dieH / dieW);
    data.layers.forEach(function (L) {
      var m = meta(L.id) || {};
      var oc = document.createElement("canvas");
      oc.width = RW; oc.height = RH;
      var octx = oc.getContext("2d");
      octx.fillStyle = m.color || "#888";
      (L.polygons || []).forEach(function (poly) {
        octx.beginPath();
        for (var i = 0; i + 1 < poly.length; i += 2) {
          var px = poly[i] / dieW * RW, py = (dieH - poly[i + 1]) / dieH * RH;
          if (i === 0) octx.moveTo(px, py); else octx.lineTo(px, py);
        }
        octx.closePath(); octx.fill();
      });
      rasters[L.id] = oc;
    });
  }
  function drawSlab(L, i) {
    var z = layerZ(i);
    var RW = rasters[L.id].width, RH = rasters[L.id].height;
    // Affine map from raster pixels to screen via three projected corners.
    var o = proj(0, 0, z), ex = proj(1, 0, z), ey = proj(0, 1, z);
    ex = { x: ex.x - o.x, y: ex.y - o.y };
    ey = { x: ey.x - o.x, y: ey.y - o.y };
    // raster pixel (u,v) <-> die (u/RW*dieW, dieH - v/RH*dieH)
    var a = dieW / RW * ex.x, b = dieW / RW * ex.y;
    var c = -dieH / RH * ey.x, d = -dieH / RH * ey.y;
    var e = o.x + dieH * ey.x, f = o.y + dieH * ey.y;
    ctx.save();
    ctx.globalAlpha = 0.85;
    ctx.setTransform(a, b, c, d, e, f);
    ctx.drawImage(rasters[L.id], 0, 0);
    ctx.restore();
  }
  function poly(pts, fill, stroke) {
    ctx.beginPath();
    pts.forEach(function (p, i) {
      if (i === 0) ctx.moveTo(p.x, p.y); else ctx.lineTo(p.x, p.y);
    });
    ctx.closePath();
    if (fill) { ctx.fillStyle = fill; ctx.fill(); }
    if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = 1; ctx.stroke(); }
  }
  function pointInPoly(pt, vs) {
    var inside = false;
    for (var i = 0, j = vs.length - 1; i < vs.length; j = i++) {
      var xi = vs[i].x, yi = vs[i].y, xj = vs[j].x, yj = vs[j].y;
      if (((yi > pt.y) !== (yj > pt.y)) &&
          (pt.x < (xj - xi) * (pt.y - yi) / (yj - yi) + xi)) inside = !inside;
    }
    return inside;
  }
  function macroTop(m, z) {
    return [proj(m.x, m.y, z), proj(m.x + m.w, m.y, z),
            proj(m.x + m.w, m.y + m.h, z), proj(m.x, m.y + m.h, z)];
  }
  function drawMacro(m, zBase) {
    var M = pal().macro3d;
    var H = 30, z = zBase + H;
    var top = macroTop(m, z);
    var bot = macroTop(m, zBase);
    // sides first, then top
    poly([bot[0], bot[1], top[1], top[0]], M.side1);
    poly([bot[1], bot[2], top[2], top[1]], M.side2);
    poly(top, M.top, M.topStroke);
    ctx.font = "bold 12px sans-serif"; ctx.fillStyle = M.topLabel;
    ctx.textAlign = "center";
    var c = { x: (top[0].x + top[2].x) / 2, y: (top[0].y + top[2].y) / 2 };
    ctx.fillText(m.name, c.x, c.y - 4);
  }
  function draw() {
    if (!data) return;
    var r = cv.getBoundingClientRect();
    // Self-heal: resync the backing store if the CSS size drifted without
    // a resize event (or the store was dropped); this repaints everything.
    if (cv.width !== Math.round(r.width) || cv.height !== Math.round(r.height)) {
      cv.width = Math.round(r.width); cv.height = Math.round(r.height);
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, r.width, r.height);
    ctx.fillStyle = pal().canvasBg; ctx.fillRect(0, 0, r.width, r.height);
    var sramIdx = 0;
    data.layers.forEach(function (L, i) { if (L.id === "sram") sramIdx = i; });
    data.layers.forEach(function (L, i) {
      if (!window.TempoLayers.state.visible[L.id]) return;
      drawSlab(L, i);
    });
    if (window.TempoLayers.state.showMacros) {
      var zBase = layerZ(sramIdx);
      window.TempoLayers.MACROS.forEach(function (m) { drawMacro(m, zBase); });
    }
  }
  window.TempoDraw3D = draw;
  window.TempoLayers.onChange(draw);
  if (window.TempoTheme) window.TempoTheme.onChange(draw);

  function layerInfo(L) {
    var m = meta(L.id) || {};
    info.innerHTML = "<h4>" + (m.name || L.name) + " — GDS " + (L.gds || m.gds) +
      "</h4><p>Role: " + (m.role || L.role || "") +
      "<br>Polygons shipped: " + (L.polygons || []).length +
      "<br>Fidelity: " + (m.fidelity || L.repr || "") +
      "<br>Stack z (schematic): " + L.z + ", thickness class " + L.thick + "</p>";
  }
  function pick(mx, my) {
    // macros first (exact footprints)
    var sramIdx = 0;
    data.layers.forEach(function (L, i) { if (L.id === "sram") sramIdx = i; });
    if (window.TempoLayers.state.showMacros) {
      var zBase = layerZ(sramIdx) + 30;
      for (var k = 0; k < window.TempoLayers.MACROS.length; k++) {
        var m = window.TempoLayers.MACROS[k];
        if (pointInPoly({ x: mx, y: my }, macroTop(m, zBase))) return { macro: m };
      }
    }
    // topmost visible layer whose projected die quad contains the point
    for (var i = data.layers.length - 1; i >= 0; i--) {
      var L = data.layers[i];
      if (!window.TempoLayers.state.visible[L.id]) continue;
      var quad = [proj(0, 0, layerZ(i)), proj(dieW, 0, layerZ(i)),
                  proj(dieW, dieH, layerZ(i)), proj(0, dieH, layerZ(i))];
      if (pointInPoly({ x: mx, y: my }, quad)) return { layer: L };
    }
    return null;
  }
  cv.addEventListener("pointerdown", function (e) {
    try { cv.setPointerCapture(e.pointerId); } catch (err) { /* no capture: drag still tracks while over the canvas */ }
    pointers.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
    if (pointers.size === 2) {
      var pts = Array.from(pointers.values());
      lastPinch = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
    }
  });
  cv.addEventListener("pointermove", function (e) {
    if (!pointers.has(e.pointerId)) {
      var hit = data ? pick(e.offsetX, e.offsetY) : null;
      if (hit && hit.macro) readout.textContent = hit.macro.name + " — " + hit.macro.cell;
      else if (hit && hit.layer) readout.textContent = "Layer: " + (meta(hit.layer.id) || {}).name;
      else readout.textContent = "Drag to orbit · scroll / pinch to zoom · explode slider separates layers";
      return;
    }
    var prev = pointers.get(e.pointerId);
    pointers.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
    if (pointers.size === 1) {
      az += (e.offsetX - prev.x) * 0.01;
      el = Math.max(12 * Math.PI / 180, Math.min(72 * Math.PI / 180,
        el + (e.offsetY - prev.y) * 0.005));
      draw();
    } else if (pointers.size === 2) {
      var pts = Array.from(pointers.values());
      var d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      if (lastPinch > 0) zoom = Math.max(0.3, Math.min(6, zoom * d / lastPinch));
      lastPinch = d; draw();
    }
  });
  ["pointerup", "pointercancel"].forEach(function (t) {
    cv.addEventListener(t, function (e) { pointers.delete(e.pointerId); });
  });
  cv.addEventListener("wheel", function (e) {
    e.preventDefault();
    zoom = Math.max(0.3, Math.min(6, zoom * (e.deltaY < 0 ? 1.15 : 1 / 1.15)));
    draw();
  }, { passive: false });
  cv.addEventListener("click", function (e) {
    var hit = data ? pick(e.offsetX, e.offsetY) : null;
    if (hit && hit.macro) {
      var m = hit.macro;
      info.innerHTML = "<h4>" + m.name + " — " + m.cell + "</h4><p>Footprint: " +
        m.w + " x " + m.h + " um at (" + m.x + ", " + m.y + "), orientation " +
        m.orient + ".<br>" + m.note +
        "<br>Rendered as an extruded block at its true footprint on the SRAM stratum; block height is schematic.</p>";
    } else if (hit && hit.layer) layerInfo(hit.layer);
  });
  explodeEl.addEventListener("input", function () {
    explode = parseInt(explodeEl.value, 10);
    explodeVal.textContent = explode + " px/layer";
    fitStack(false);
    draw();
  });
  document.getElementById("btn-3d-reset").addEventListener("click", function () {
    az = -0.6; el = 35 * Math.PI / 180; zoom = 1; cx = 0; cy = 0;
    explode = DEFAULT_EXPLODE;
    if (explodeEl) explodeEl.value = String(DEFAULT_EXPLODE);
    if (explodeVal) explodeVal.textContent = DEFAULT_EXPLODE + " px/layer";
    fitStack(true); fitted = true; draw();
  });
  var lastW = 0, lastH = 0;
  function resize() {
    // Backing store in CSS pixels (not device pixels) so canvas
    // coordinates match getBoundingClientRect() throughout. Preserves
    // the user's zoom on small size changes (phone URL-bar show/hide
    // fires resize while scrolling and must not yank the view); refits
    // on a large size change (orientation change, window resize) or if
    // the stack somehow ends up entirely off-canvas.
    var r = cv.getBoundingClientRect();
    cv.width = Math.round(r.width); cv.height = Math.round(r.height);
    var bigChange = lastW > 0 && (Math.abs(r.width - lastW) / lastW > 0.25 ||
                                  Math.abs(r.height - lastH) / lastH > 0.25);
    if (bigChange || !stackVisible()) { fitStack(true); fitted = true; }
    lastW = r.width; lastH = r.height;
    draw();
  }
  window.addEventListener("resize", resize);
  // Self-heal for blank-after-navigation: scrolling the section back
  // into view repaints, and fits the stack if it was never fitted (e.g.
  // the canvas had no size at load). Same for pageshow / tab visibility.
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        if (e.isIntersecting) {
          if (!fitted) fitted = fitStack(true);
          draw();
        }
      });
    }).observe(cv);
  }
  window.addEventListener("pageshow", function () { draw(); });
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) draw();
  });

  fetch("assets/layers.json").then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (j) {
    data = j; dieW = j.die[0]; dieH = j.die[1];
    rasterize(); fitted = fitStack(true); resize();
    info.innerHTML = "<h4>3D exploded stack</h4><p>Drag to orbit, scroll or " +
      "pinch to zoom, use the explode slider to separate layers. Layer " +
      "toggles are shared with the 2D explorer above. Click a layer slab " +
      "or a gold macro block for its name, role, GDS number, polygon " +
      "count, and fidelity class.</p>";
  }).catch(function () {
    info.innerHTML = "<p>Failed to load assets/layers.json.</p>";
  });
})();
