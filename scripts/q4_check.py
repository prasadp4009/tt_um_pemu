#!/usr/bin/env python3
"""q4_check.py -- structural Q4 invariant checker (Worker D).

Q4 (absolute): NO data path between the PE and the trace SRAM.
Verifies structurally from src/tt_um_pemu.v that:
  1. The trace macro (u_tmem) data/address/enable inputs (A_DIN, A_ADDR,
     A_MEN, A_WEN, A_REN) are driven ONLY by the observer instance (u_obs).
  2. The PE instance (u_pe) has NO port connected to any trace-macro net.
  3. The host's trace readout goes through the observer's host_rd_* port,
     never directly to the macro.

This is a source-structural check (named port connections). It fails if
any trace-macro input net is driven by, or shared with, the PE.

Usage: python3 scripts/q4_check.py  (run from repo root)
Exit 0 = PASS, 1 = FAIL.
"""
import re
import sys

TOP = "src/tt_um_pemu.v"

# Trace-macro input ports that must be observer-driven only
TMEM_INPUTS = ["A_DIN", "A_ADDR", "A_MEN", "A_WEN", "A_REN", "A_BM", "A_DLY"]

def strip_comments(src):
    # remove // line comments (no block comments in these files)
    return re.sub(r"//[^\n]*", "", src)

def parse_instance(src, inst_name):
    """Return dict {port: net} for `.<port> (<net>)` in instance inst_name."""
    src = strip_comments(src)
    # find the instance: <module> <inst_name> (
    m = re.search(r"\b\w+\s+" + re.escape(inst_name) + r"\s*\((.*?)\);",
                  src, re.DOTALL)
    if not m:
        raise SystemExit(f"FAIL: instance {inst_name} not found")
    body = m.group(1)
    ports = {}
    for pm in re.finditer(r"\.(\w+)\s*\(\s*([^,()]+?)\s*\)", body):
        ports[pm.group(1)] = pm.group(2).strip()
    return ports

def main():
    src = open(TOP).read()
    fails = []

    u_tmem = parse_instance(src, "u_tmem")
    u_obs = parse_instance(src, "u_obs")
    u_pe = parse_instance(src, "u_pe")
    u_host = parse_instance(src, "u_host")

    # Nets driving the trace macro inputs
    tmem_nets = {}
    for p in TMEM_INPUTS:
        if p not in u_tmem:
            fails.append(f"u_tmem port .{p} not connected")
            continue
        tmem_nets[p] = u_tmem[p]

    # 1. Every trace-macro input net must be driven by an observer OUTPUT.
    #    Build map net -> observer output ports.
    obs_driven = {net for port, net in u_obs.items()}
    # Observer inputs (for the error message)
    obs_inputs = set()
    # We determine direction textually: observer port list from its module decl.
    obs_src = strip_comments(open("src/tt_um_pemu_observer.v").read())
    m = re.search(r"module\s+tt_um_pemu_observer\s*\((.*?)\);", obs_src, re.DOTALL)
    decl = m.group(1)
    obs_out_ports = set(re.findall(r"output\s+(?:wire\s+)?(?:\[[^\]]+\]\s*)?(\w+)", decl))
    obs_in_ports = set(re.findall(r"input\s+(?:wire\s+)?(?:\[[^\]]+\]\s*)?(\w+)", decl))

    for p, net in tmem_nets.items():
        # constant tie-off on A_DLY is mandated (not a data path)
        if re.fullmatch(r"1'b[01]", net) and p == "A_DLY":
            continue
        # find which observer port connects to this net
        drivers = [op for op, onet in u_obs.items()
                   if onet == net and op in obs_out_ports]
        if not drivers:
            fails.append(
                f"Q4 VIOLATION: u_tmem.{p} net '{net}' not driven by an "
                f"observer output port")

    # 2. PE must not touch any trace-macro net.
    pe_nets = set(u_pe.values())
    for p, net in tmem_nets.items():
        if re.fullmatch(r"1'b[01]", net):
            continue
        if net in pe_nets:
            bad = [op for op, onet in u_pe.items() if onet == net]
            fails.append(
                f"Q4 VIOLATION: PE port(s) {bad} share trace-macro net "
                f"'{net}' (u_tmem.{p})")

    # 3. Host trace readout must go via observer host_rd_*, not the macro.
    for hp, hnet in u_host.items():
        if hnet in tmem_nets.values() and not re.fullmatch(r"1'b[01]", hnet):
            fails.append(
                f"Q4 VIOLATION: host port .{hp} connects to trace-macro net "
                f"'{hnet}'")
    # host_rd_* must land on observer ports
    for hp in ("host_rd_en", "host_rd_addr", "host_rd_data", "host_rd_ack"):
        if hp not in u_host or hp not in u_obs:
            fails.append(f"host/observer {hp} port missing")
        elif u_host[hp] != u_obs[hp]:
            fails.append(f"host .{hp} net {u_host[hp]} != observer {u_obs[hp]}")

    # 4. PE must not see trace data: no PE input port fed by tmem_dout net.
    tmem_dout_net = u_tmem.get("A_DOUT", "")
    for op, onet in u_pe.items():
        if onet == tmem_dout_net and tmem_dout_net:
            fails.append(f"Q4 VIOLATION: PE port .{op} sees trace dout")

    if fails:
        print("Q4 CHECK: FAIL")
        for f in fails:
            print("  " + f)
        return 1
    print("Q4 CHECK: PASS -- no PE<->trace-data path; trace macro driven only")
    print("          by the observer (host reads via observer host_rd_*).")
    return 0

if __name__ == "__main__":
    sys.exit(main())
