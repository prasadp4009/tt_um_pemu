// Site navigation — defined in exactly one place.
// ADD FUTURE PAGES HERE when the page actually exists. Do NOT add a link
// to a page that does not exist yet (no dead links; the simulator page
// gets its link only when the simulator page ships).
(function () {
  var PAGES = [
    { href: "#top", label: "TEMPO" },
    { href: "#architecture", label: "Architecture" },
    { href: "#spec", label: "Spec" },
    { href: "#functionality", label: "Functionality" },
    { href: "#waveforms", label: "Waveforms" },
    { href: "#code", label: "Example code" },
    { href: "#using", label: "How to use" },
    { href: "#testing", label: "FPGA testing" },
    { href: "#layout", label: "Labeled layout" },
    { href: "#explorer", label: "GDS explorer" },
    { href: "#view3d", label: "3D stack" },
    { href: "#limitations", label: "Limitations" }
  ];
  var nav = document.getElementById("site-nav");
  if (!nav) return;
  nav.innerHTML = PAGES.map(function (p) {
    return '<a href="' + p.href + '">' + p.label + "</a>";
  }).join("");
})();
