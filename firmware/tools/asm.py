#!/usr/bin/env python3
"""Tarang-32 assembler — derived from isa_v0.2.yaml (never hand-encoded).

Two-pass assembler. All encodings (opcode numbers, field positions,
delay policy, reserved-bit rules) are read from the YAML at startup;
only the *mnemonic surface syntax* is defined here.

Usage:
    python3 asm.py in.asm -o out.hex [--listing out.lst] [--yaml PATH]

Assembly language:
    ; comment to end of line
    label:                      define label at current address
    .org 0x40                   set assembly address
    .word 0x12345678            emit raw 32-bit word
    r0..r15                     registers (case-insensitive)

    pset 0xA5            pset 0xA5, d=3
    psetr r2            psetr r2, d=3
    pget r1
    pmask 0x0F          pdir 0xFF          pmode r3
    sleep 1000
    wait 1, 0, falling, 1, r4      ; pin, pol, mode, tsel, rd
    cap r5
    mov r1, r2          ldi r3, 0x1234     ; imm16 must be even (bit0 reserved)
    push r6             pull r7
    mrs r1, STATUS      msr r2, TRIG_MODE  ; sreg by name or number
    add r1, r2, r3      sub r1, r2, r3
    and r1, r2, r3      or  r1, r2, r3     xor r1, r2, r3
    shl r1, r2, r3      shr r1, r2, r3
    cmp r1, r2
    jmp loop, al        jmp done, z        ; cond: al,z,nz,c,nc,tmo,rxne,txnf
    djnz r5, loop
    call sub            ret
    hlt
    evt 3

The `, d=N` delay suffix (N=0..31) is accepted only where the YAML says
`delay: applies`; SLEEP/WAIT/HLT forms reject it (reserved_zero).
"""
import sys, re, argparse
import yaml

# ----------------------------------------------------------------------------
# Load the ISA contract
# ----------------------------------------------------------------------------
def load_isa(path):
    with open(path) as f:
        return yaml.safe_load(f)

OP_SHIFT, DLY_SHIFT = 26, 21

# mnemonic -> (yaml instruction name, fixed field values, operand kinds)
# operand kinds: reg, imm8, imm13, imm16, sreg, target, cond, pin, pol,
#                wmode, tsel, imm4, delay
MNEMONICS = {
    "pset":  ("PSET",  {},            ["imm8"]),
    "psetr": ("PSETR", {},            ["reg"]),
    "pget":  ("PGET",  {},            ["reg"]),
    "pmask": ("PMASK", {},            ["imm8"]),
    "pdir":  ("PDIR",  {},            ["imm8"]),
    "pmode": ("PMODE", {},            ["reg"]),
    "sleep": ("SLEEP", {},            ["imm13"]),
    "wait":  ("WAIT",  {},            ["pin", "pol", "wmode", "tsel", "reg"]),
    "cap":   ("CAP",   {},            ["reg"]),
    "mov":   ("MOV",   {},            ["reg", "reg"]),
    "ldi":   ("LDI",   {},            ["reg", "imm16"]),
    "push":  ("PUSH",  {},            ["reg"]),
    "pull":  ("PULL",  {},            ["reg"]),
    "mrs":   ("MRS",   {},            ["reg", "sreg"]),
    "msr":   ("MSR",   {},            ["reg", "sreg"]),
    "add":   ("ADD/SUB",     {"fn": 0}, ["reg", "reg", "reg"]),
    "sub":   ("ADD/SUB",     {"fn": 1}, ["reg", "reg", "reg"]),
    "and":   ("AND/OR/XOR",  {"fn": 0}, ["reg", "reg", "reg"]),
    "or":    ("AND/OR/XOR",  {"fn": 1}, ["reg", "reg", "reg"]),
    "xor":   ("AND/OR/XOR",  {"fn": 2}, ["reg", "reg", "reg"]),
    "shl":   ("SHL/SHR",     {"fn": 0}, ["reg", "reg", "reg"]),
    "shr":   ("SHL/SHR",     {"fn": 1}, ["reg", "reg", "reg"]),
    "cmp":   ("CMP",   {},            ["reg", "reg"]),
    "jmp":   ("JMP",   {},            ["target", "cond"]),
    "djnz":  ("DJNZ",  {},            ["reg", "target"]),
    "call":  ("CALL/RET", {"is_ret": 0}, ["target"]),
    "ret":   ("CALL/RET", {"is_ret": 1, "target9": 0}, []),
    "hlt":   ("HLT",   {},            []),
    "evt":   ("EVT",   {},            ["imm4"]),
}

COND_CODES = {"al":0,"z":1,"nz":2,"c":3,"nc":4,"tmo":5,"rxne":6,"txnf":7}
WAIT_MODES = {"level":0,"rising":1,"falling":2,"either":3}

SREG_NAMES = {}   # filled from YAML

FIELD_BY_OP = {}  # yaml instruction name -> operand field order template

def field_width(msb, lsb):
    return msb - lsb + 1

class AsmError(Exception):
    pass

# ----------------------------------------------------------------------------
# Parsing helpers
# ----------------------------------------------------------------------------
def parse_num(tok, lo, hi, what):
    tok = tok.strip()
    try:
        v = int(tok, 0)
    except ValueError:
        raise AsmError(f"{what}: bad number '{tok}'")
    if not (lo <= v <= hi):
        raise AsmError(f"{what}: {v} out of range [{lo}..{hi}]")
    return v

def parse_reg(tok):
    m = re.fullmatch(r"[rR](\d+)", tok.strip())
    if not m:
        raise AsmError(f"bad register '{tok}'")
    return parse_num(m.group(1), 0, 15, "register")

def parse_sreg(tok):
    tok = tok.strip()
    if re.fullmatch(r"[rR](\d+)", tok):
        raise AsmError(f"sreg operand looks like a register: '{tok}'")
    up = tok.upper()
    if up in SREG_NAMES:
        return SREG_NAMES[up]
    return parse_num(tok, 0, 63, "sreg")

# ----------------------------------------------------------------------------
# Assembler
# ----------------------------------------------------------------------------
class Assembler:
    def __init__(self, isa):
        self.isa = isa
        self.instr_by_name = {}
        for ins in isa["instructions"]:
            # compound names like "ADD/SUB" map under each variant via MNEMONICS
            self.instr_by_name[ins["name"]] = ins
        global SREG_NAMES
        for r in isa["special_registers"]["regs"]:
            addr = r["addr"]
            if isinstance(addr, int):
                SREG_NAMES[r["name"].upper()] = addr

    def encode(self, yaml_name, delay, field_vals):
        ins = self.instr_by_name[yaml_name]
        if ins["delay"] == "reserved_zero" and delay != 0:
            raise AsmError(f"{yaml_name}: delay field is reserved_zero")
        if not (0 <= delay <= 31):
            raise AsmError(f"delay {delay} out of range 0..31")
        word = (ins["number"] << OP_SHIFT) | (delay << DLY_SHIFT)
        for f in ins["fields"]:
            name, msb, lsb = f["name"], f["msb"], f["lsb"]
            if name == "reserved":
                continue
            if name not in field_vals:
                raise AsmError(f"{yaml_name}: missing field '{name}'")
            v = field_vals[name]
            w = field_width(msb, lsb)
            if not (0 <= v < (1 << w)):
                raise AsmError(f"{yaml_name}.{name}: {v} does not fit in {w} bits")
            word |= (v << lsb)
        return word

    def asm_line(self, mnemonic, operands, delay, labels):
        if mnemonic not in MNEMONICS:
            raise AsmError(f"unknown mnemonic '{mnemonic}'")
        yaml_name, fixed, kinds = MNEMONICS[mnemonic]
        if mnemonic == "jmp" and len(operands) == 1:
            operands = operands + ["al"]
        if mnemonic == "wait":
            # compose cfg8 = pin[2:0] | pol | mode[1:0] | tsel[1:0] (D-E5)
            if len(operands) != 5:
                raise AsmError("wait: want 5 operands: pin, pol, mode, tsel, rd")
            pin = self._operand("pin", operands[0], labels, mnemonic)
            pol = self._operand("pol", operands[1], labels, mnemonic)
            mode = self._operand("wmode", operands[2], labels, mnemonic)
            tsel = self._operand("tsel", operands[3], labels, mnemonic)
            rd = self._operand("reg", operands[4], labels, mnemonic)
            cfg8 = (pin << 5) | (pol << 4) | (mode << 2) | tsel
            return self.encode(yaml_name, delay, {"cfg8": cfg8, "rd": rd})
        ins = self.instr_by_name[yaml_name]
        if ins["delay"] == "reserved_zero" and delay is None:
            delay = 0
        if delay is None:
            delay = 0
        if len(operands) != len(kinds):
            raise AsmError(f"{mnemonic}: want {len(kinds)} operands, got {len(operands)}")
        fv = dict(fixed)
        # map operands onto the YAML field lanes in order
        lanes = [f["name"] for f in ins["fields"] if f["name"] != "reserved"]
        # operand kinds map to lane names positionally, skipping fixed fields
        need = [l for l in lanes if l not in fixed]
        if len(need) != len(kinds):
            raise AsmError(f"internal: {mnemonic} lane/kind mismatch {need} vs {kinds}")
        for kind, lane, tok in zip(kinds, need, operands):
            fv[lane] = self._operand(kind, tok, labels, mnemonic)
        # special validations
        if yaml_name == "LDI" and (fv["imm16"] & 1):
            raise AsmError("ldi: imm16 bit0 is reserved, immediate must be even")
        if yaml_name in ("JMP", "DJNZ", "CALL/RET") and fv.get("target9", 0) > 511:
            raise AsmError(f"{mnemonic}: target {fv['target9']} out of range (9-bit target9, max 511; target9[8] activated by ISA v0.3 / M3-R-7 IMEM-512 extension)")
        return self.encode(yaml_name, delay, fv)

    def _operand(self, kind, tok, labels, mnemonic):
        tok = tok.strip()
        if kind == "reg":
            return parse_reg(tok)
        if kind == "imm8":
            return parse_num(tok, 0, 255, mnemonic)
        if kind == "imm13":
            return parse_num(tok, 0, 8191, mnemonic)
        if kind == "imm16":
            return parse_num(tok, 0, 65535, mnemonic)
        if kind == "imm4":
            return parse_num(tok, 0, 15, mnemonic)
        if kind == "sreg":
            return parse_sreg(tok)
        if kind == "cond":
            c = tok.lower()
            if c not in COND_CODES:
                raise AsmError(f"{mnemonic}: bad condition '{tok}'")
            return COND_CODES[c]
        if kind == "target":
            if tok in labels:
                return labels[tok]
            return parse_num(tok, 0, 511, f"{mnemonic} target")
        if kind == "pin":
            return parse_num(tok, 0, 7, "wait pin")
        if kind == "pol":
            return parse_num(tok, 0, 1, "wait pol")
        if kind == "wmode":
            m = tok.lower()
            if m not in WAIT_MODES:
                raise AsmError(f"wait: bad mode '{tok}' (level|rising|falling|either)")
            return WAIT_MODES[m]
        if kind == "tsel":
            return parse_num(tok, 0, 3, "wait tsel")
        raise AsmError(f"internal: unknown operand kind {kind}")

    def assemble(self, src):
        # pass 1: labels
        labels, addr = {}, 0
        stmts = []
        for ln, raw in enumerate(src.splitlines(), 1):
            line = raw.split(";")[0].strip()
            if not line:
                continue
            while True:
                m = re.match(r"([A-Za-z_]\w*):\s*(.*)$", line)
                if not m:
                    break
                name, line = m.group(1), m.group(2).strip()
                if name in labels:
                    raise AsmError(f"line {ln}: duplicate label '{name}'")
                labels[name] = addr
            if not line:
                continue
            m = re.match(r"\.org\s+(\S+)", line, re.I)
            if m:
                addr = parse_num(m.group(1), 0, 511, ".org")
                stmts.append((ln, "org", addr))
                continue
            m = re.match(r"\.word\s+(\S+)", line, re.I)
            if m:
                stmts.append((ln, "word", parse_num(m.group(1), 0, 0xFFFFFFFF, ".word")))
                addr += 1
                continue
            # instruction: mnemonic operands [, d=N]
            m = re.match(r"([A-Za-z]+)\s*(.*)$", line)
            if not m:
                raise AsmError(f"line {ln}: cannot parse '{raw.strip()}'")
            mnemonic = m.group(1).lower()
            rest = m.group(2).strip()
            delay = None
            dm = re.search(r",\s*d\s*=\s*(\d+)\s*$", rest)
            if dm:
                delay = int(dm.group(1))
                rest = rest[:dm.start()].strip()
            operands = [o.strip() for o in rest.split(",")] if rest else []
            stmts.append((ln, "insn", (mnemonic, operands, delay)))
            addr += 1
        if addr > 512:
            raise AsmError(f"image is {addr} words, exceeds 512-word IMEM")
        # pass 2: encode
        words, listing = [], []
        pc = 0
        for ln, kind, payload in stmts:
            if kind == "org":
                pc = payload
                listing.append((None, f".org {pc}"))
                continue
            if kind == "word":
                words.append((pc, payload))
                listing.append((pc, f".word 0x{payload:08x}"))
                pc += 1
                continue
            mnemonic, operands, delay = payload
            try:
                w = self.asm_line(mnemonic, operands, delay if delay is not None else 0, labels)
            except AsmError as e:
                raise AsmError(f"line {ln}: {e}")
            words.append((pc, w))
            listing.append((pc, f"{mnemonic} {', '.join(operands)}"
                               + (f", d={delay}" if delay else "")))
            pc += 1
        return words, listing, labels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--listing")
    ap.add_argument("--yaml", default=None)
    args = ap.parse_args()
    import os
    yaml_path = args.yaml or os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "..", "isa_v0.2.yaml")
    # tools/ is firmware/tools -> ../../isa_v0.2.yaml
    yaml_path = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "..", "..", "isa_v0.2.yaml"))
    if args.yaml:
        yaml_path = args.yaml
    isa = load_isa(yaml_path)
    asm = Assembler(isa)
    with open(args.src) as f:
        src = f.read()
    try:
        words, listing, labels = asm.assemble(src)
    except AsmError as e:
        print(f"asm error: {e}", file=sys.stderr)
        sys.exit(1)
    by_addr = {a: w for a, w in words}
    if not by_addr:
        print("asm error: empty image", file=sys.stderr)
        sys.exit(1)
    top = max(by_addr)
    with open(args.out, "w") as f:
        for a in range(top + 1):
            f.write(f"{by_addr.get(a, 0):08x}\n")
    if args.listing:
        with open(args.listing, "w") as f:
            for pc, text in listing:
                f.write(f"{pc if pc is not None else '':>4}  {text}\n")
    print(f"assembled {len(words)} words, top addr {top} "
          f"({512 - top - 1} words headroom)")

if __name__ == "__main__":
    main()
