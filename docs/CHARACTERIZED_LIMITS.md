# tt_um_pemu — Characterized limits (2026-10-29)

Plain-language bounds for the submitted IMEM-512 design (`main@abafd1c`,
ISA v0.3 note). Each limit states exactly what the hardware/firmware does,
so a user or judge is never surprised. Full evidence and decision items:
`docs/OPEN_ITEMS_AUDIT.md`.

## Clock: 50 MHz nominal, ≤ 43.8 MHz guaranteed across all corners

- Typical corner: setup slack +5.713 ns. Fast corner: +8.578 ns. Hold is
  clean at all corners.
- Slow corner (1.08 V, 125 °C): setup WNS −2.824 ns, 112 violators, all on
  the IMEM fetch path (`u_imem/A_DOUT[17]`, plus 2 reg-out from A_DOUT[18]).
  Implied slow-corner fmax ≈ 43.8 MHz.
- **Guidance: run at ≤ 43.8 MHz if setup must be guaranteed at the slow
  corner; 50 MHz is met with margin at typical and fast corners only.**
  The competition sets no clock target, so this is a characterized
  operating condition, not a flow failure (GDS, LVS, DRC, antenna, and
  IR-drop all pass).

## WAIT timeouts: only 256 and 4096 cycles are implemented

- `tsel` 0 → 256 cycles, `tsel` 1 → 4096 cycles. Elapsed cycles are written
  to Rd; TIMEOUT sticky is set iff the timeout expired. A condition true
  exactly at the deadline counts as satisfied (elapsed = timeout, no
  TIMEOUT).
- `tsel` 2 and 3 (the 65536- and 1048576-cycle presets in the ISA table)
  are **not implemented**: they fall back to the 256/4096 timeout
  respectively **and set CONFIG_ERR**. Firmware must not use them expecting
  a long timeout. The long-timeout behavior (saturate elapsed at 0xFFFF)
  is a pending ISA-lead decision, not shipped behavior; chaining 4096-cycle
  waits (as the UART break rule does) is the supported way to wait longer.

## CAN: maximum DLC is 2

- CAN 2.0A at 1 Mb/s (TX, ACK sampling, arbitration loss) is proven, but
  frames carry at most 2 data bytes. The design has no data RAM and all 16
  general-purpose registers are allocated during a frame, so there is
  nowhere to hold a longer destuffed data stream mid-frame. A DLC > 2
  request has its argument words consumed and discarded and returns
  0xFFFF. A longer-frame redesign (data RAM or an extra stream register)
  is out of scope. The larger instruction memory does not lift this cap:
  it is a register limit, not a word-count limit.

## UART TX: a starved host blocks; it does not abort with 0xFFFD

- In the UART TX demo, if the host declares N data bytes but stops
  supplying them, the firmware waits in its receive-ready loop for the next
  word. It does not time out and does not push 0xFFFD on this path (the
  0xFFFD abort code exists as a safety net for pulls that bypass the wait,
  which normal operation never does). Recovery is supplying the missing
  word, or a host reset/reload. All other UART behavior (TX framing, RX
  sampling at mid-bit +1 cycle, break detection at ≥ 8192 low cycles,
  RX timeout/framing errors) is as documented.

## Observer PULSE mode: pin 0 only

- The Observer's PULSE trigger watches **pin 0 only**, regardless of the
  PIN_SEL special-register value, because the top level ties the
  Observer's pin-select input to 0. EDGE and PATTERN trigger modes are
  unaffected (they use masks). Trace entries saturate at 204 and never
  wrap; TRACE_WM is sticky and is cleared only by OBS_CLR.

## SPI at 125 MHz: passed twice on this build, not a guaranteed point

- The proven SPI operating point is 50 MHz (full 15-milestone proof,
  signature 0xa6b864d9). The 256-word baseline failed deterministically at
  125 MHz (fail code 0x13); the 512-word build passed twice at 125 MHz
  with the identical signature, but the baseline failure was never
  root-caused, so 125 MHz is reported as observed, not as a guaranteed
  operating point.

## Protocol scope bounds

- USB: merged TX+RX in a single 299-word image is proven. A complete USB
  device stack (enumeration and beyond) is firmware work beyond the
  shipped image, not a chip limitation.
- 10BASE-T Ethernet is not feasible on this chip (Manchester timing on
  the 20 ns grid, the ~43.8 MHz slow-corner ceiling, and the need for an
  analog PHY). It is not claimed.
- Illegal opcodes (24–63) execute as NOP and set CONFIG_ERR. CALL on a
  full return stack drops the call and sets CONFIG_ERR; RET on an empty
  stack is a NOP and sets CONFIG_ERR. Unallocated special registers read
  as zero. These behaviors are defined and tested, even where the ISA
  TBD table still lists them open.
