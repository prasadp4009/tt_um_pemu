// Site navigation (defined in exactly one place) + theme system.
// Theme: localStorage "tempo-theme" wins; otherwise the OS preference
// (prefers-color-scheme). A tiny inline script in <head> applies the theme
// before first paint; this module owns the toggle button, persists changes,
// swaps light/dark diagram variants, and publishes the canvas palettes that
// the explorer, 3D view and simulator draw with. No external requests.
// The simulator page (docs/simulator.html) now exists, so it gets its
// link here; do NOT add a link to a page that does not exist yet.
(function () {
  var KEY = "tempo-theme";
  var PALETTES = {
    light: {
      canvasBg: "#ffffff", grid: "#e2e8f0", label: "#475569",
      die: "#0f172a", core: "#2563eb",
      macroFill: "rgba(254,243,199,0.55)", macroStroke: "#92400e", macroLabel: "#92400e",
      pin: "#dc2626",
      wave: ["#2563eb", "#047857"], trace: "#b45309", cursor: "#dc2626",
      padHigh: "#22c55e", padLow: "#334155",
      macro3d: { side1: "#b45309", side2: "#92400e", top: "#fde68a", topStroke: "#92400e", topLabel: "#451a03" }
    },
    dark: {
      canvasBg: "#0b1120", grid: "#1e293b", label: "#94a3b8",
      die: "#e2e8f0", core: "#2dd4bf",
      macroFill: "rgba(251,191,36,0.20)", macroStroke: "#f59e0b", macroLabel: "#fcd34d",
      pin: "#f87171",
      wave: ["#60a5fa", "#34d399"], trace: "#fbbf24", cursor: "#fb7185",
      padHigh: "#4ade80", padLow: "#64748b",
      macro3d: { side1: "#92400e", side2: "#78350f", top: "#f59e0b", topStroke: "#fbbf24", topLabel: "#1c1917" }
    }
  };
  var listeners = [];
  function current() {
    return document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light";
  }
  function preferred() {
    try {
      var stored = window.localStorage.getItem(KEY);
      if (stored === "dark" || stored === "light") return stored;
    } catch (e) { /* private mode: fall through to OS preference */ }
    try {
      if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) return "dark";
    } catch (e) { /* no matchMedia: fall through */ }
    return "light";
  }
  function swapDiagrams(theme) {
    var imgs = document.querySelectorAll("img.diagram[data-dark-src]");
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      if (!img.getAttribute("data-light-src"))
        img.setAttribute("data-light-src", img.getAttribute("src"));
      img.setAttribute("src", theme === "dark" ? img.getAttribute("data-dark-src")
        : img.getAttribute("data-light-src"));
    }
  }
  var toggleBtn = null;
  function syncToggle() {
    if (!toggleBtn) return;
    var dark = current() === "dark";
    toggleBtn.textContent = dark ? "☀ Light" : "☾ Dark";
    toggleBtn.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
    toggleBtn.setAttribute("aria-pressed", dark ? "true" : "false");
    toggleBtn.setAttribute("title", dark ? "Switch to light mode" : "Switch to dark mode");
  }
  function apply(theme, persist) {
    document.documentElement.setAttribute("data-theme", theme);
    if (persist) {
      try { window.localStorage.setItem(KEY, theme); } catch (e) { /* ignore */ }
    }
    swapDiagrams(theme);
    syncToggle();
    listeners.forEach(function (fn) { try { fn(theme); } catch (e) { /* one view failing must not break the others */ } });
  }
  window.TempoTheme = {
    get: current,
    preferred: preferred,
    set: function (t) { apply(t === "dark" ? "dark" : "light", true); },
    toggle: function () { apply(current() === "dark" ? "light" : "dark", true); },
    pal: function () { return PALETTES[current()]; },
    onChange: function (fn) { listeners.push(fn); }
  };

  var isSim = /simulator\.html$/.test(window.location.pathname);
  var base = isSim ? "index.html" : "";
  var PAGES = [
    { href: base + "#top", label: "TEMPO" },
    { href: base + "#architecture", label: "Architecture" },
    { href: base + "#spec", label: "Spec" },
    { href: base + "#functionality", label: "Functionality" },
    { href: base + "#waveforms", label: "Waveforms" },
    { href: base + "#code", label: "Example code" },
    { href: base + "#using", label: "How to use" },
    { href: base + "#testing", label: "FPGA testing" },
    { href: base + "#layout", label: "Labeled layout" },
    { href: base + "#explorer", label: "GDS explorer" },
    { href: base + "#view3d", label: "3D stack" },
    { href: base + "#limitations", label: "Limitations" },
    { href: "simulator.html", label: "Simulator" },
    { href: "viewer/", label: "GDS Viewer" }
  ];
  var nav = document.getElementById("site-nav");
  if (!nav) return;
  // Links live in their own .nav-links row so narrow screens can scroll
  // them horizontally while the theme toggle stays visible (see site.css).
  nav.innerHTML = '<span class="nav-links">' + PAGES.map(function (p) {
    return '<a href="' + p.href + '">' + p.label + "</a>";
  }).join("") + "</span>";
  toggleBtn = document.createElement("button");
  toggleBtn.id = "theme-toggle";
  toggleBtn.className = "theme-toggle";
  toggleBtn.type = "button";
  toggleBtn.addEventListener("click", function () { window.TempoTheme.toggle(); });
  nav.appendChild(toggleBtn);
  // Sync the toggle + diagrams with the theme the <head> script applied.
  // If that script never ran (no data-theme yet), fall back to the stored
  // value / OS preference. No persistence write here: first paint already
  // used the stored/OS value.
  apply(document.documentElement.getAttribute("data-theme") ? current() : preferred(), false);
})();
