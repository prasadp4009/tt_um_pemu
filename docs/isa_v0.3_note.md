# Tarang-32 ISA — v0.3 Note (IMEM-512 extension)

| | |
|---|---|
| Version | v0.3 (note; no new encoding document) |
| Date | 2026-10-28 |
| Status | Effective on branch `dev/imem-512`. The 256-word baseline is the `v1.0-proven-256` tag. |
| Supersedes | Nothing in v0.2. This note activates a bit v0.2 explicitly reserved for this purpose. |

## What changes

- **Activation of the reserved `target9[8]` bit.** Per ISA v0.2 merge
  decision **M3** / resolution **R-7**, `target9[8]` in JMP/CALL/DJNZ was
  frozen must-be-zero in v0.2 *"held for a future IMEM-512 extension."*
  This note is that extension: the bit is now implemented and may be set.
  This is the pre-authorized activation path, not a new encoding.
- **IMEM depth 256 → 512 words.** The instruction memory is now 512
  words deep (PC is 9 bits, addresses 0–511).
- **JMP/CALL/DJNZ targets are now 9-bit.** The target field was already
  9 bits wide in the v0.2 encodings and is now fully usable:
  JMP and CALL carry `target9` at `instr[20:12]`; DJNZ carries it at
  `instr[16:8]`. Targets 0–511 are legal.
- **Host loader range.** LOAD_IMEM / VERIFY_IMEM now accept the full
  16-bit base address with a span ≤ 512 words (previously the base high
  byte had to be zero and the span ≤ 256). The host wire format is
  **unchanged** — the address was always sent as 2 bytes and the LEN
  byte already capped a frame at 63 words, so loading simply uses more
  frames.

## What does not change

- **No opcode changes. No instruction format changes.** Every field
  lane, opcode number, delay rule, and timing contract from v0.2 is
  exactly as frozen; only the previously reserved bit changes meaning
  (reserved-zero → address bit 8).
- **CAN DLC ≤ 2 cap is unaffected.** That cap is structural (register
  file allocation in the CAN firmware), not an IMEM-depth limit; 512
  words adds no registers, so the cap stays at DLC ≤ 2.

## Scope / provenance

- Effective on branch `dev/imem-512` only, until merged.
- The `v1.0-proven-256` tag remains the proven 256-word baseline.
- Analysis: `IMEM_EXPANSION_ANALYSIS_2026-10-27.md` (Option A — the
  512×32 SRAM macro swap at unchanged placement).
