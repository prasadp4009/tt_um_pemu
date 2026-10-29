#!/usr/bin/env python3
"""tbengy-style test-module runner for Tarang firmware verification.

A test module is a Python file defining:
    TEST = {"name": <str>, "proto": <str>}   # required
    def build(sim): ...       # assemble firmware, load imem, config pins/host
    def peer(sim): ...        # optional per-cycle peer model (drives pins)
    def check(sim):           # -> (passed: bool, report: str)
        ...

Conventions (tbengy discipline):
  * One test module per protocol behavior; deterministic (fixed seed).
  * build() must assemble via tools.asm (never hand-encoded words).
  * check() asserts on waveforms/logs, not just "it ran".
  * Every run writes: <name>.log (sim event log) and <name>.vcd (GTKWave).

Usage:
    python3 tb.py run tests/test_uart_tx.py [--vcd] [--max N]
    python3 tb.py selftest        # tools self-check (assembler+simulator)
"""
import sys, os, importlib.util, traceback

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from asm import Assembler, load_isa, AsmError
from sim import Sim, YAML_PATH


def assemble_src(name, src, workdir):
    isa = load_isa(YAML_PATH)
    asm = Assembler(isa)
    words, listing, labels = asm.assemble(src)
    by_addr = {}
    for a, w in words:
        by_addr[a] = w
    top = max(by_addr)
    img = [by_addr.get(a, 0) for a in range(top + 1)]
    hexp = os.path.join(workdir, name + ".hex")
    with open(hexp, "w") as f:
        for w in img:
            f.write(f"{w:08x}\n")
    lstp = os.path.join(workdir, name + ".lst")
    with open(lstp, "w") as f:
        for pc, text in listing:
            f.write(f"{pc if pc is not None else '':>4}  {text}\n")
    return img, len(words), top


def load_module(path):
    spec = importlib.util.spec_from_file_location("tmod", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run_test(path, workdir, want_vcd=True, max_cycles=5_000_000):
    mod = load_module(path)
    tname = mod.TEST["name"]
    os.makedirs(workdir, exist_ok=True)
    sim = Sim([0])
    try:
        mod.build(sim)
        if hasattr(mod, "peer") and mod.peer is not None:
            sim.pins_peer = mod.peer
        r = sim.run(max_cycles=max_cycles)
        passed, report = mod.check(sim)
    except Exception:
        passed, report = False, "EXCEPTION:\n" + traceback.format_exc()
        r = {"cycles": sim.cycle, "halted": sim.halted, "warnings": sim.warnings}
    logp = os.path.join(workdir, tname + ".log")
    with open(logp, "w") as f:
        f.write(f"test: {tname}\nresult: {'PASS' if passed else 'FAIL'}\n")
        f.write(sim.status_str() + "\n")
        for c, w in sim.warnings:
            f.write(f"WARN @{c}: {w}\n")
        for c, msg in sim.log:
            f.write(f"@{c}: {msg}\n")
        f.write("---- check report ----\n" + report + "\n")
    vcdp = None
    if want_vcd:
        vcdp = os.path.join(workdir, tname + ".vcd")
        sim.vcd(vcdp)
    print(f"[{'PASS' if passed else 'FAIL'}] {tname} "
          f"cycles={sim.cycle} halted={sim.halted} log={logp}"
          + (f" vcd={vcdp}" if vcdp else ""))
    print(report)
    return passed


SELFTEST_SRC = """
        ; tools self-check: pin round-trip, WAIT, FIFOs, CALL/RET
        pdir 0xFF
        pmask 0xFF
        pset 0xA5
        sleep 3
        pget r1                 ; expect 0xA5 (sync settled)
        ldi r2, 0x00BE
        push r2                 ; TX <- 0x00BE
        wait 1, 1, level, 0, r3 ; pin1 low (pset 0xA5 bit1=0) -> timeout 256
        cap r4
        call sub
        hlt
sub:    ldi r5, 0xCAFE
        ret
"""

def selftest(workdir):
    """Assembler+simulator self-check with assertions."""
    os.makedirs(workdir, exist_ok=True)
    img, nwords, top = assemble_src("selftest", SELFTEST_SRC, workdir)
    # G3 spot-check: decode 5 instructions against the YAML field map
    import random
    random.seed(20260926)
    isa = load_isa(YAML_PATH)
    by_num = {i["number"]: i for i in isa["instructions"]}
    sample = random.sample(img, min(5, len(img)))
    for w in sample:
        op = (w >> 26) & 0x3F
        assert op in by_num, f"word {w:08x}: unknown opcode {op}"
        ins = by_num[op]
        for f in ins["fields"]:
            if f["name"] == "reserved":
                m = ((1 << (f["msb"] - f["lsb"] + 1)) - 1) << f["lsb"]
                assert (w & m) == 0, f"word {w:08x}: reserved bits set in {ins['name']}"
    print(f"spot-check: {len(sample)} words decode clean, reserved bits zero")
    # WAIT edge-mode regression: falling edge on pin1 at cycle 100 must fire
    # (a wait_prev latch-order bug once made pv==v so edges never fired).
    esim = Sim(assemble_src("edgeprobe", "pdir 0x00\nwait 1, 0, falling, 1, r3\nhlt\n", workdir)[0])
    esim.pins_peer = lambda s: s.peer_drv.__setitem__(1, 1 if s.cycle < 100 else 0)
    esim.run(max_cycles=10000)
    assert esim.regs[3] == 100 and not (esim.sticky & 1), \
        f"WAIT falling edge: elapsed={esim.regs[3]} (want 100), TIMEOUT={bool(esim.sticky & 1)}"
    print("edge-wait: falling edge detected, elapsed=100, no TIMEOUT")

    s = Sim(img)
    s.host_push_rx_words([0x1234, 0x5678])
    r = s.run(max_cycles=10000)
    errs = []
    if s.regs[1] != 0xA5:
        errs.append(f"r1={s.regs[1]:04x}, want 0xA5 (pin round-trip)")
    if not (s.sticky & 0x01):
        errs.append("TIMEOUT sticky not set after WAIT timeout")
    if s.regs[3] != 256:
        errs.append(f"WAIT rd={s.regs[3]}, want 256 (timeout elapsed)")
    if s.regs[5] != 0xCAFE:
        errs.append(f"r5={s.regs[5]:04x}, want 0xCAFE (CALL/RET)")
    if s.tx_fifo != [0x00BE]:
        errs.append(f"tx_fifo={s.tx_fifo}, want [0x00BE]")
    # PULL check via fresh sim
    s2 = Sim(img)
    s2.host_push_rx_words([0x1234])
    # run only until first PULL would occur: simpler - direct PULL program
    img2, _, _ = assemble_src("pullchk", "pull r7\nhlt\n", workdir)
    s2 = Sim(img2)
    s2.host_push_rx_words([0x1234])
    s2.run(max_cycles=100)
    if s2.regs[7] != 0x1234:
        errs.append(f"PULL r7={s2.regs[7]:04x}, want 0x1234")
    if not s.halted:
        errs.append("sim did not halt")
    if errs:
        print("SELFTEST FAIL:")
        for e in errs:
            print("  -", e)
        return False
    print(f"SELFTEST PASS ({nwords} words, {s.cycle} cycles, "
          f"{len(s.warnings)} warnings)")
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    workdir = os.environ.get("TB_WORKDIR", os.path.join(TOOLS, "..", "tests", "out"))
    if cmd == "selftest":
        ok = selftest(workdir)
        sys.exit(0 if ok else 1)
    if cmd == "run":
        path = sys.argv[2]
        want_vcd = "--vcd" in sys.argv or True
        maxc = 5_000_000
        if "--max" in sys.argv:
            maxc = int(sys.argv[sys.argv.index("--max") + 1])
        ok = run_test(path, workdir, want_vcd=want_vcd, max_cycles=maxc)
        sys.exit(0 if ok else 1)
    print(__doc__)
    sys.exit(1)


if __name__ == "__main__":
    main()
