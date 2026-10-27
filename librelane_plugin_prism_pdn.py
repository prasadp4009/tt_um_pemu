"""
LibreLane plugin for tt_um_pemu: bridge the tile's Metal4 power stripes
onto the IHP SRAM macros' own supply columns (Project.ExtendPowerStripes,
driven by odb_stripes.py) and cap the placement density at the macro
mouths (Project.MouthKeepouts, driven by odb_keepouts.py).

Ported from Ken Pettit's ihp-um-janestreet-prism project
(https://github.com/kdp1965/ihp-um-janestreet-prism), Copyright 2026
Ken Pettit, licensed under the Apache License, Version 2.0 (see the
LICENSE file at the repository root).  odb_stripes.py and odb_keepouts.py
are his files, copied verbatim; of his plugin's step classes, only the
two wired in src/config.json are carried over, plus his netgen LVS-JSON
repair at the bottom of this file (our SRAMs carry the same
VDD!/VSS!/VDDARRAY! pin names that trip it).  His remaining steps
(macro cell swaps, SRAM pin diodes, register anchoring, chip art) are
not used by this design and were not ported.

LibreLane imports every module on the Python path whose name starts with
``librelane_plugin_`` (librelane/plugins.py).  ``python -m librelane`` puts
the current directory on that path, and both the Tiny Tapeout GDS action
and ``make harden`` run it from the repository root, so this file is found
without installing anything.  src/config.json then inserts the steps
through ``meta.substituting_steps``:

    "+Odb.ManualMacroPlacement": "Project.MouthKeepouts"
    "+OpenROAD.GeneratePDN": "Project.ExtendPowerStripes"
"""
import os

from librelane.steps import Step
from librelane.steps.odb import OdbpyStep
from librelane.state import DesignFormat
from librelane.config import Variable
from typing import Optional
from librelane.common import Path
from decimal import Decimal

HERE = os.path.dirname(os.path.abspath(__file__))


@Step.factory.register()
class ExtendPowerStripes(OdbpyStep):
    id = "Project.ExtendPowerStripes"
    name = "Extend Power Stripes Over Macros"

    def get_script_path(self):
        return os.path.join(HERE, "odb_stripes.py")

    config_vars = [
        Variable("EXTEND_STRIPES_LAYER", str, "The tile's vertical single-layer PDN layer (Metal4 on the CMOS5L tile, TopMetal1 on the sg13g2 tile).", default="Metal4"),
        Variable("EXTEND_STRIPES_SRAM_LAYER", Optional[str], "Layer of the IHP SRAM power columns when it differs from the stripe layer; the column stripes then get via stacks down to it.", default=None),
        Variable("EXTEND_STRIPES_CLEARANCE", Decimal, "Spacing kept between a drawn stripe and the other net's macro rails or tile pins on the stripe layer.", units="µm", default=Decimal("0.24")),
        Variable("EXTEND_STRIPES_STACK_PITCH", Decimal, "Spacing of the via stacks along an SRAM power column.", units="µm", default=Decimal("10")),
        Variable("EXTEND_STRIPES_PIN_FACE_MARGIN", Decimal, "No rail via stack within this distance of a macro edge that carries pins (the stack would block the pins' escape); 0 leaves pdngen's stacks alone.", units="µm", default=Decimal("3")),
        Variable("EXTEND_STRIPES_SRAM_ALL_COLUMNS", bool, "Put a stripe on every legal supply column of an IHP SRAM rather than only the ones the tile grid and the per-region minimum need.", default=False),
        Variable("EXTEND_STRIPES_SRAM_ARRAY_EVERY_OTHER", bool, "In each bit-cell array of an IHP SRAM, add a VPWR/VGND stripe pair on every other available pair position (the grid's pairs stay; the macro's standard-cell band is left as the grid gives it).  Not with EXTEND_STRIPES_SRAM_ALL_COLUMNS.", default=False),
    ]

    def get_command(self):
        cmd = super().get_command() + [
            "--layer", self.config["EXTEND_STRIPES_LAYER"],
            "--clearance", str(self.config["EXTEND_STRIPES_CLEARANCE"]),
            "--stack-pitch", str(self.config["EXTEND_STRIPES_STACK_PITCH"]),
            "--pin-face-margin", str(self.config["EXTEND_STRIPES_PIN_FACE_MARGIN"]),
        ]
        if self.config.get("EXTEND_STRIPES_SRAM_LAYER"):
            cmd += ["--sram-layer", self.config["EXTEND_STRIPES_SRAM_LAYER"]]
        cmd += ["--sram-all-columns" if self.config["EXTEND_STRIPES_SRAM_ALL_COLUMNS"] else "--sram-grid-columns"]
        if self.config["EXTEND_STRIPES_SRAM_ARRAY_EVERY_OTHER"]:
            cmd += ["--sram-array-every-other"]
        return cmd


# --- placement keep-outs at the macro mouths (odb_keepouts.py): the rows just
# outside each macro's pin face, capped to a low cell density before global
# placement, so the nets crossing into the macro pin rows find free Metal2
# tracks there.  Inserted after the macro placement
# (meta.substituting_steps "+Odb.ManualMacroPlacement").  In this design the
# macro-prefix is "RM_" (config MOUTH_KEEPOUT_MACRO_PREFIX).
from typing import List  # noqa: E402


@Step.factory.register()
class MouthKeepouts(OdbpyStep):
    id = "Project.MouthKeepouts"
    name = "Placement Keep-outs at the Macro Mouths"

    config_vars = [
        Variable("MOUTH_KEEPOUT_WIDTH", Decimal, "Keep-out width outward from a CFGMEM column's tile-facing edge.", units="µm", default=60),
        Variable("MOUTH_KEEPOUT_MARGIN", Decimal, "How far the keep-out extends into each macro's height beyond the gap.", units="µm", default=20),
        Variable("MOUTH_KEEPOUT_MAX_DENSITY", Decimal, "Cell density cap of the soft blockage; 0 makes it a hard blockage.", default=Decimal("0.25")),
        Variable("MOUTH_KEEPOUT_MACRO_PREFIX", str, "Master-name prefix of the macros forming the columns.", default="CFGMEM"),
        Variable("MOUTH_KEEPOUT_INWARD", Decimal, "Extension of the keep-out inward from the column edge, over the gap between the two macros.", units="µm", default=0),
    ]

    def get_script_path(self):
        return os.path.join(HERE, "odb_keepouts.py")

    def get_command(self) -> List[str]:
        return super().get_command() + [
            "--macro-prefix", self.config["MOUTH_KEEPOUT_MACRO_PREFIX"],
            "--width", str(self.config["MOUTH_KEEPOUT_WIDTH"]),
            "--margin", str(self.config["MOUTH_KEEPOUT_MARGIN"]),
            "--max-density", str(self.config["MOUTH_KEEPOUT_MAX_DENSITY"]),
            "--inward", str(self.config["MOUTH_KEEPOUT_INWARD"]),
        ]


# --- netgen writes the IHP SRAM's power pin names (VDD!, VSS!, VDDARRAY!) into
# its LVS JSON with a stray backslash ("\VDD!"), which is not a valid JSON
# escape, and librelane.steps.netgen.LVS then dies in json.loads before the
# LVS checker runs.  Give that module a json namespace whose loads() doubles
# such backslashes first (the metrics only count entries; names do not matter).
import json as _json
import re as _re
import types as _types

import librelane.steps.netgen as _netgen

_BAD_ESCAPE = _re.compile(r'\\(\\|[^"\\/bfnrtu])')


def _repair_escapes(s):
    return _BAD_ESCAPE.sub(lambda m: '\\\\' if m.group(1) == '\\' else '\\\\' + m.group(1), s)


def _loads_repairing_escapes(s, *args, **kwargs):
    try:
        return _json.loads(s, *args, **kwargs)
    except _json.JSONDecodeError:
        return _json.loads(_repair_escapes(s), *args, **kwargs)


_netgen.json = _types.SimpleNamespace(
    loads=_loads_repairing_escapes, load=_json.load, dumps=_json.dumps, dump=_json.dump,
    JSONDecodeError=_json.JSONDecodeError,
)
