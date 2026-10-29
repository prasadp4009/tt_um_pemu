// Shared layer state for the 2D explorer and the 3D stack view.
// Layer metadata is from the dashboard manifest (run 40699493628, IMEM-512):
// GDS layer/datatype, shipped polygon count, and fidelity class. `z`/`thick`
// in layers.json are SCHEMATIC relative units, not physical um -- the PDK
// tech file carries no z/thickness data.
(function () {
  var LAYERS = [
    { id: "digibnd", name: "DigiBnd", gds: "16/0", polys: 6,
      role: "Digital boundary markers (per-cell core boundary outlines)",
      fidelity: "true merged geometry (native)",
      color: "#94a3b8" },
    { id: "nwell", name: "NWell", gds: "31/0", polys: 384,
      role: "N-well implant", fidelity: "true merged geometry (snapped 0.4 um)",
      color: "#86efac" },
    { id: "activ", name: "Activ", gds: "1/0", polys: 275,
      role: "Active (diffusion) area",
      fidelity: "mass silhouette (outline: open 0.5 um, snap 0.5 um) — individual transistors NOT resolvable",
      color: "#60a5fa" },
    { id: "psd", name: "pSD", gds: "14/0", polys: 451,
      role: "P+ source/drain implant",
      fidelity: "mass silhouette (opened 0.8 um)",
      color: "#c084fc" },
    { id: "gatpoly", name: "GatPoly", gds: "5/0", polys: 175,
      role: "Gate polysilicon",
      fidelity: "mass silhouette (outline: open 0.5 um, snap 0.7 um) — individual gates NOT resolvable",
      color: "#f87171" },
    { id: "sram", name: "SRAM", gds: "25/0", polys: 4,
      role: "SRAM macro outlines (u_imem + u_tmem blocks)",
      fidelity: "true merged geometry (native)",
      color: "#fbbf24" },
    { id: "cont", name: "Cont", gds: "6/0", polys: 858,
      role: "Contacts (FEOL)",
      fidelity: "coverage raster — 3 um tiles, >=2% covered; a tile is NOT a via",
      color: "#64748b" },
    { id: "metal1", name: "Metal1", gds: "8/0", polys: 7,
      role: "Metal 1 routing",
      fidelity: "mass silhouette (grow 0.3 um + merge, snap 2.0 um) — individual wires NOT resolvable",
      color: "#38bdf8" },
    { id: "recog", name: "Recog.diode", gds: "99/31", polys: 72,
      role: "Antenna-diode recognition markers",
      fidelity: "true merged geometry (native)",
      color: "#fb923c" },
    { id: "via1", name: "Via1", gds: "19/0", polys: 5383,
      role: "Via 1 (Metal1-Metal2)",
      fidelity: "coverage raster — 3 um tiles, >=2% covered; a tile is NOT a via",
      color: "#2dd4bf" },
    { id: "metal2", name: "Metal2", gds: "10/0", polys: 11347,
      role: "Metal 2 routing",
      fidelity: "mass silhouette (grow 0.25 um + merge, snap 0.9 um) — net clusters, not wires",
      color: "#34d399" },
    { id: "via2", name: "Via2", gds: "29/0", polys: 5051,
      role: "Via 2 (Metal2-Metal3)",
      fidelity: "coverage raster — 3 um tiles, >=2% covered; a tile is NOT a via",
      color: "#2dd4bf" },
    { id: "metal3", name: "Metal3", gds: "30/0", polys: 12514,
      role: "Metal 3 routing",
      fidelity: "true merged geometry (snap 0.6 um)",
      color: "#f472b6" },
    { id: "via3", name: "Via3", gds: "49/0", polys: 7248,
      role: "Via 3 (Metal3-Metal4)",
      fidelity: "coverage raster — 3 um tiles, >=2% covered; a tile is NOT a via",
      color: "#2dd4bf" },
    { id: "metal4", name: "Metal4", gds: "50/0", polys: 1710,
      role: "Metal 4 routing + PDN",
      fidelity: "true merged geometry (native)",
      color: "#a78bfa" },
    { id: "metal4pin", name: "Metal4.pin", gds: "50/2", polys: 192,
      role: "Metal 4 pins (PDN stripes + macro pins)",
      fidelity: "true merged geometry (native)",
      color: "#8b5cf6" }
  ];
  // layers.json ships layers bottom->top in physical stack order; this
  // table is in the same order, so index i is the stack position.
  var MACROS = [
    { name: "u_imem", cell: "RM_IHPSG13_1P_512x32_c2_bm_bist",
      x: 205.68, y: 3.78, w: 416.64, h: 191.57, orient: "FS",
      note: "512 x 32-bit instruction SRAM. GDS-measured bbox; LEF size is 191.34 um tall (0.23 um overhang)." },
    { name: "u_tmem", cell: "RM_IHPSG13_1P_1024x8_c2_bm_bist",
      x: 1127.36, y: 3.78, w: 146.88, h: 336.69, orient: "FS",
      note: "1024 x 8-bit trace SRAM = 204 entries x {timestamp[31:0], pins[7:0]}. GDS-measured bbox; LEF size is 336.46 um tall." }
  ];
  var state = { visible: {}, showMacros: true, showPins: true };
  LAYERS.forEach(function (l) { state.visible[l.id] = true; });
  // NOTE (2026-10-29): MACROS used to be assigned here as
  // `window.TempoLayers.MACROS = MACROS` BEFORE window.TempoLayers existed,
  // which threw on load and broke the explorer + 3D view outright. It now
  // lives in the object literal below, assigned exactly once.
  window.TempoLayers = { META: LAYERS, MACROS: MACROS, state: state, listeners: [],
    onChange: function (fn) { this.listeners.push(fn); },
    set: function (id, v) {
      this.state.visible[id] = v;
      this.listeners.forEach(function (fn) { fn(); });
    },
    solo: function (id) {
      var self = this;
      LAYERS.forEach(function (l) { self.state.visible[l.id] = (l.id === id); });
      this.listeners.forEach(function (fn) { fn(); });
    },
    preset: function (kind) {
      var self = this;
      LAYERS.forEach(function (l) {
        if (kind === "all") self.state.visible[l.id] = true;
        else if (kind === "none") self.state.visible[l.id] = false;
        else if (kind === "metals") self.state.visible[l.id] =
          (l.id === "metal1" || l.id === "metal2" || l.id === "metal3" ||
           l.id === "metal4" || l.id === "metal4pin");
      });
      this.listeners.forEach(function (fn) { fn(); });
    }
  };
})();
