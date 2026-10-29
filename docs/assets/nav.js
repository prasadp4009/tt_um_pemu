// Site navigation — defined in exactly one place.
// The simulator page (docs/simulator.html) now exists, so it gets its
// link here; do NOT add a link to a page that does not exist yet.
(function () {
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
    { href: "simulator.html", label: "Simulator" }
  ];
  var nav = document.getElementById("site-nav");
  if (!nav) return;
  nav.innerHTML = PAGES.map(function (p) {
    return '<a href="' + p.href + '">' + p.label + "</a>";
  }).join("");
})();
