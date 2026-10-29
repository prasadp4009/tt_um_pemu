# 10BASE-T Ethernet — Stretch Feasibility Analysis (TEMPO / tt_um_pemu)

**Analysis only.** No firmware was written and no simulation was run for
this document. Every number below is either quoted from a project file
(named inline), derived by arithmetic shown inline, or quoted from an
external source (cited in §9).

**Date:** 2026-10-27
**Design baseline:** Tiny Tapeout IHP cmos5l flow GREEN — GDS run
40575084383 on HEAD `76451e0` (FINAL_STATS.md), gl_test fixed and green
on HEAD `e99ff28`, run 40609957985 (SUBMISSION_READINESS_2026-10-27.md).

---

## Verdict (up top)

| Question | Verdict |
|---|---|
| (i) TEMPO-as-10BASE-T-PHY on the ASIC — firmware drives the wire directly, ASIC pins are the PHY | **NOT FEASIBLE** — fails on three independent grounds, any one of which is sufficient: (1) half-bit timing is not representable at 50 MHz (2.5 cycles/half-bit; dithered edges violate the 802.3 transmitter jitter limit by 1.25–1.8× before any other jitter source is counted); (2) the slow-corner silicon cannot even sustain the nominal 50 MHz (fmax ≈ **43.61 MHz**, §3), let alone the 100 MHz that would make the half-bit exact; (3) 10BASE-T is an analog specification — differential waveform template, magnetics, squelch receiver — and TEMPO exposes only 3.3 V single-ended digital GPIO with fixed-threshold digital inputs. There is no PHY to speak of. |
| (ii) TEMPO + external PHY/MAC-PHY chip as a *system* — TEMPO bit-bangs the chip's digital host interface, the chip does the wire | **ASIC CAPABILITY (system-level, honestly labelled)** — trivially feasible on timing (MII nibble at 10 Mb/s = 20 cycles/nibble; SPI-host chips even easier). But the Ethernet protocol emulation is then done by the PHY chip, not by the TEMPO ISA. The competition narrative may claim *"TEMPO controls an external 10BASE-T PHY"*, never *"TEMPO implements 10BASE-T."* See §7c. |
| FPGA Manchester-signalling demo at 100 MHz (Zybo) | **FPGA-ONLY CURIOSITY** — the cycle math closes exactly at 100 MHz, so a Manchester *bit-stream* demo on the FPGA is physically possible. It would prove the ISA timing model scales with clock; it would prove nothing about the ASIC, and it still would not be a compliant 10BASE-T PHY (analog grounds, §6, apply on the FPGA board too). See §7b. |

**ARCHITECTURE.md §5.5 is confirmed, independently and with numbers:**
its one-line verdict — *"10BASE-T Ethernet, 10 Mbps Manchester,
5 cycles/bit (2.5/half) — not feasible at 50 MHz"* — is correct, and if
anything understates the case: it cites only the cycle math, whereas
the STA ceiling (§3) and the analog PHY requirements (§6) each kill
the idea on their own.

---

## 1. The pin-toggle-rate claim, grounded in the contract

The fastest possible pin-edge rate is not an estimate; it is fixed by
two normative documents.

**ARCHITECTURE.md §2.2 (cycle-exact contract), item 2 — Pin-effect
point:**

> "PSET / PSETR / PDIR / PMODE take effect at the **end of the base
> cycle** (cycle 0); the `delay` cycles that follow run with pins
> stable. Two consecutive 1-cycle pin instructions therefore produce
> edges exactly 20 ns apart @50 MHz."

**ISA_v0.2.md §5 (timing contract, normative proof obligations):**

> "**T3.** PSET/PSETR/PDIR/PMODE shall commit their pin (or
> pin-control) effect at the end of cycle 0; the `d` delay cycles run
> with pins stable."
>
> "**T11.** Pin effects committed at end of cycle 0 shall be visible
> at the physical pins ≤ 1 cycle later…"
>
> "**T1.** Every instruction with opcode ≠ 7 shall occupy exactly
> `1+d` cycles." (WAIT, opcode 7, is the sole data-dependent
> exception, T2 — irrelevant to a transmitter, which cannot tolerate
> data-dependent timing anyway.)

Consequences, with no wiggle room:

1. **One pin-effect per instruction, one instruction per cycle at
   minimum** (`1+d`, `d ≥ 0`). There is no sideset, no concurrent pin
   action bundled into an ALU instruction (the ISA deliberately
   refused PIO-style sideset ambiguity — ARCHITECTURE.md §2.4).
2. Therefore the **minimum spacing between any two pin edges is
   exactly one core cycle = 20 ns at 50 MHz**, and every edge lands
   on the 20 ns clock grid. No edge can ever be placed at a
   non-multiple of 20 ns from program start.
3. The receive side is symmetric: **T5** makes the 2-FF synchronizer
   architectural — PGET/CAP/Observer see the physical pins exactly
   2 core cycles (40 ns) earlier, sampled on the same 20 ns grid.
   Input sampling resolution is therefore also 20 ns, with a fixed
   40 ns latency firmware must absorb.

Any protocol whose required edge placements do not lie on a 20 ns
grid at the required accuracy is unreachable in firmware, regardless
of code cleverness. §2 shows 10BASE-T is exactly such a protocol.

---

## 2. The cycle math — Manchester does not fit in 5 cycles/bit

10BASE-T (IEEE 802.3 Clause 14) line signalling:

| Quantity | Value | Derivation |
|---|---|---|
| Data rate | 10 Mb/s | definition |
| Bit cell | **100 ns** | 1 / 10 MHz |
| Coding | Manchester (differential on the wire) | Clause 14 |
| Transitions | one mandatory **mid-bit** transition per bit cell, plus a boundary transition iff consecutive bits are equal | Manchester definition |
| Half-bit (half-cell) | **50 ns** | 100 ns / 2 |
| Signalling rate on the wire | 20 Mtransitions/s worst case | 2 per bit cell |

TEMPO at the nominal harness clock:

| Quantity | Value |
|---|---|
| Core clock (nominal, designer-chosen in info.yaml) | 50 MHz |
| Cycle time | 20 ns |
| Cycles per bit cell | 100 ns / 20 ns = **5 cycles/bit** |
| Cycles per half-bit | 50 ns / 20 ns = **2.5 cycles/half-bit** ← the problem |

**2.5 is not an integer.** Mid-bit transitions must occur 50 ns after
cell-boundary transitions, but the pin grid (§1) only permits edges
at multiples of 20 ns: …0, 20, 40, 60, 80, 100… ns. 50 ns is not on
the grid. This is not a firmware-scheduling difficulty; it is a
representability failure. No instruction sequence, however written,
places an edge at 50 ns offset within a bit cell whose boundary edge
is at 0 ns.

### 2.1 The firmware budget fails even before the half-bit problem

Suppose, counterfactually, that the half-bit were representable. A
transmitter MAC still has to *do work* per bit: fetch the next data
bit, decide the two half-cell levels, handle the conditional boundary
transition, update CRC-32, count bits/bytes, detect collisions
(simultaneous TX/RX activity in half-duplex), enforce the 9.6 µs
(96-bit-time) interframe gap, and generate/check preamble (7 bytes)
+ SFD. At 5 cycles/bit total, with the pin instruction itself
consuming ≥1 cycle per half-cell (2 per bit), at most ~3 cycles/bit
remain for *all* loop overhead — a single `DJNZ` is 1 cycle, a shift
is 1 cycle, a CRC step is multiple cycles. For comparison, the
project's own proven firmware mappings (ARCHITECTURE.md §5) use
434 cycles/bit (UART 115200), ~50 cycles/bit (SPI @1 MHz) and
500 cycles/half-bit (I2C 100 kHz). 10BASE-T asks for two orders of
magnitude less time per bit than the slowest of the *working*
mappings' per-bit budgets, while demanding strictly more per-bit
work (Manchester + CRC-32 + CSMA/CD) than any of them. The receive
path is worse: clock recovery from a Manchester stream whose edges
arrive asynchronously, sampled through a 2-FF synchronizer on a
20 ns grid (§1, T5), requires sub-half-cell sampling decisions that
the grid cannot express.

This budget argument alone would justify "not feasible." The next
section shows the usual remedy — dither the half-bit — also fails,
quantitatively, against the standard's own jitter limit.

---

## 3. STA evidence — the silicon does not reach 50 MHz at the slow corner, and 100 MHz is not in the conversation

**Source:** FINAL_STATS.md §5 — post-P&R STA (step 58) from GitHub
Actions run **40575084383**, HEAD **76451e0**, LibreLane 3.1.0.dev3,
PDK `ihp-sg13cmos5l`, 20 ns (50 MHz) constraint. Cross-checked there
against `final/metrics.json` and the step logs. SUBMISSION_READINESS
_2026-10-27.md row 9 reports the same figures.

| Corner | Setup WNS | Setup TNS | Violators | Worst hold slack |
|---|---|---|---|---|
| nom_fast, 1.32 V, −40 °C | clean | 0 | 0 | +0.104 ns (hold WNS 0) |
| nom_typ, 1.20 V, 25 °C | clean — worst slack **+5.339 ns** | 0 | 0 | +0.289 ns |
| nom_slow, 1.08 V, 125 °C | **−2.933 ns** | **−171.68 ns** | **131** | +0.609 ns (hold clean) |

Hold is clean at all corners. All 131 slow-corner setup violators
share a **single source pin, `u_imem/A_DOUT[18]`** — one IMEM
read-data bit on the fetch path fanning out across the PE
(FINAL_STATS.md §5). One net ⇒ tractable in principle (fanout
buffering / replication / fetch pipelining), but it has not been
fixed, and it defines the silicon as it will tape out.

**Reconciliation note (files vs. files).** FINAL_STATS.md §5 flags
that the previous run (40520569898) reported slow WNS −2.880 ns /
TNS −164.90 / 129 violators, typ +5.37 ns. The −2.933 ns figures
above are from the later, green run 40575084383 and **supersede**
them (placement/routing changed). Both runs agree on the substance:
same single source net, slow-corner WNS ≈ −2.9 ns, typ/fast clean.

### 3.1 Slow-corner fmax, computed

A path with WNS = −2.933 ns against a 20 ns constraint needs a clock
period of at least:

```
T_min(slow) = 20 ns + |−2.933 ns| = 22.933 ns
fmax(slow)  = 1 / 22.933 ns        = 43.61 MHz
```

(FINAL_STATS.md rounds this to "≈ 43.6 MHz"; the precise figure is
**43.605 MHz**.)

For completeness, the same arithmetic at the clean corners:

```
fmax(typ)  = 1 / (20 − 5.339) ns = 1 / 14.661 ns = 68.21 MHz
fmax(fast) = 1 / (20 − 8.681) ns = 1 / 11.319 ns = 88.35 MHz
```

Read those three numbers carefully, because they bound every
"just clock it faster" argument in §7a:

- **Even the nominal 50 MHz is above slow-corner fmax (43.61 MHz).**
  At 1.08 V / 125 °C the chip as-hardened does not meet its own
  nominal clock. (The competition imposes no clock target —
  SUBMISSION_READINESS row 9 — so this is a warning, not a flow
  failure. But it means any Ethernet argument that starts "at
  50 MHz…" is already granting the design 15% more clock than the
  slow corner guarantees.)
- **100 MHz — the clock at which the Manchester half-bit becomes
  exact (10 ns cycle; 10 cycles/bit, 5 cycles/half-bit) — is
  2.29× the slow-corner fmax and still 1.47× the typical-corner
  fmax.** No corner of the manufactured part reaches it. This is
  not a margin problem that better firmware, a different constraint
  file, or optimism can close; it is the placed-and-routed critical
  path of the actual design.

---

## 4. Dithering — alternating 2/3-cycle half-bits, quantified

The standard trick for a non-integer cycles-per-half-bit ratio is
dithering: alternate half-cells of 2 cycles (40 ns) and 3 cycles
(60 ns). The long-term average is exactly 50 ns, so the *average*
bit rate is exactly 10 Mb/s. This section shows why "correct on
average" is not good enough — the standard regulates the
*instantaneous* edge placement, not the average.

### 4.1 Edge displacement

With the 2,3,2,3,… pattern starting on a cell boundary:

| Half-cell # | Ideal end (ns) | Actual end (ns) | Displacement |
|---|---|---|---|
| 1 | 50 | 40 | **−10 ns** |
| 2 | 100 | 100 | 0 |
| 3 | 150 | 140 | **−10 ns** |
| 4 | 200 | 200 | 0 |
| … | | | pattern repeats |

Starting with 3,2 instead flips the sign (+10 ns on odd half-cells).
Either way:

- **Worst-case edge displacement: ±10 ns**, on every other edge,
  for the entire frame. It never accumulates beyond ±10 ns (the one
  virtue of the pattern), but it also never goes away.
- As a fraction: **±10 ns = 20% of the 50 ns half-cell** (10% of the
  100 ns bit cell).
- As jitter: deterministic, data-stream-periodic jitter of
  **20 ns peak-to-peak**, present before the harness clock's own
  jitter, pad skew, output-buffer asymmetry, or any board effect is
  added. Dithering consumes more than the entire jitter budget by
  itself; everything else is additional violation.

(There is no smarter pattern. Half-cells must be whole cycles —
§1 — so every half-cell is 40 ns or 60 ns, i.e. every half-cell is
wrong by exactly 10 ns; patterns only choose the *sign sequence*.
Longer patterns such as 2,3,3,2 redistribute which edges are
displaced; none places any edge at 50 ns offset.)

### 4.2 Against the 802.3 transmitter jitter requirement

IEEE 802.3 Clause 14 (10BASE-T MAU) specifies transmitter output
timing jitter at the MDI, measured per §14.3.1.2.3. The grounded
compliance figures (TI application report SNLA266B, *DP8382x IEEE
802.3u Compliance and Debug*, §3.3.2.3–3.3.2.4 — a Clause-14 test
suite):

- **Jitter with Twisted Pair Model (TPM): must be < ±5.5 ns.**
- **Jitter without TPM: must be < ±8.0 ns.**

Dithered TEMPO output: **±10 ns** of deterministic jitter alone.

```
vs. with-TPM limit:    10.0 / 5.5  = 1.82× over the limit
vs. without-TPM limit: 10.0 / 8.0  = 1.25× over the limit
```

The transmitter fails the jitter test by 25–82% *on the dither term
alone*, in the best case, with a perfect clock and perfect pads
assumed. A skeptical reviewer does not need to argue about whether
a forgiving receiver might still decode it (many would, on a short
bench cable — Manchester receivers are deliberately tolerant, and
the *receiver* jitter tolerance in Clause 14 is far looser than the
*transmitter* jitter generation limit). The point is normative:
a device that generates ±10 ns of systematic jitter is not a
compliant 10BASE-T transmitter, and "a switch on my desk linked up"
is a bench anecdote, not a PHY. The competition stretch goal says
"10Mbit Ethernet," and the honest engineering claim has to be about
10BASE-T, not about edges a tolerant peer happened to accept.

### 4.3 Dithering does not even fix the receive path

Dithering is a TX-only idea. On RX, the incoming stream's mid-bit
edges arrive at true 50 ns offsets; TEMPO samples them on its 20 ns
synchronizer grid (§1, T5). The sampling quantisation error is up
to ±10 ns on every edge measurement — 20% of a half-cell — before
clock-recovery logic (which itself has only ~2.5 samples per
half-cell to work with) attempts to distinguish "mid-bit transition"
from "boundary transition." Combined with the per-bit firmware
budget of §2.1, RX clock recovery + Manchester decode + CRC-32 in
firmware at 5 cycles/bit is not a hard program; it is an
under-sampled one.

---

## 5. (Reserved — analysis continues in §6)

*Section numbering kept aligned with the task brief: cycle math §2,
STA §3, dither §4, analog/PHY §6, escape hatches §7, verdict §8.*

---

## 6. Even a perfect Manchester bit-stream is not 10BASE-T — the analog PHY

Sections 2–4 grant, for argument's sake, a perfect digital
Manchester engine and show it still fails. This section removes the
grant: 10BASE-T compliance is mostly *analog*, and TEMPO has no
analog capability at all. The Tiny Tapeout interface is 24 digital
pins at 3.3 V; the precheck analog-pin check passes precisely
because the design contains **no analog pins**
(SUBMISSION_READINESS row 8; FINAL_STATS.md §4).

### 6.1 Transmit path

A compliant 10BASE-T transmitter (802.3 §14.3.1) must deliver, at
the MDI (i.e. on the *line side* of the isolation magnetics):

1. **Differential signalling** on a dedicated TX pair — equal and
   opposite voltages on TX+/TX−. TEMPO pins are single-ended
   3.3 V CMOS. Two GPIO pins driven in anti-phase approximate a
   differential pair at the pins, but with uncontrolled skew,
   unmatched output impedance, no controlled common-mode, and no
   waveshaping; §14.3.1 also bounds common-mode output
   (< 50 mV peak, per the TI compliance suite §3.3.2.6) — a number
   two independent CMOS pads have no mechanism to meet.
2. **The output waveform template.** Every transmitted bit waveform
   — data pulses, the TP_IDL idle pulse that terminates each frame,
   and the link pulse — must fit inside a voltage-vs-time template
   (§14.3.1.2.1, tested against multiple loads, with and without the
   twisted-pair model). Peak differential voltage must be
   **2.2 V to 2.8 V** into 100 Ω (Clause-14 test table). The
   template exists because real PHYs *shape* their output
   (controlled rise/fall, pre-emphasis for the cable model). A raw
   CMOS square wave — full-swing, uncontrolled edges, ringing into
   an uncontrolled load — is exactly what the template, the
   harmonic-content test (harmonics ≥ 27 dB below fundamental,
   §14.3.1 test table), and the return-loss test (≥ 15 dB,
   5–10 MHz) exist to reject.
3. **Magnetics.** 10BASE-T requires transformer coupling at the
   MDI: typically a 1:1 isolation transformer plus common-mode
   choke (the familiar "magjack"). The transformer provides
   galvanic isolation, common-mode rejection, and part of the
   waveform shaping. TEMPO's board has TT demo-board GPIO routing,
   not a magnetics front end; adding a magjack to a carrier board
   still leaves items 1–2 unsolved, because the template is
   specified at the MDI and the *driver* behind the transformer
   must be a PHY driver, not a logic pad.
4. **Link integrity test pulses (NLP).** In the absence of data,
   the MAU must transmit a single nominally **100 ns** link pulse
   every **16 ms ± 8 ms**; the link partner declares link-loss if
   NLPs stop arriving (link-loss timer ~50–150 ms), and modern
   autonegotiation-era partners expect FLP bursts (Clause 28) in
   place of / compatible with NLPs. Firmware *can* schedule a pulse
   every 16 ms trivially (800,000 cycles) — this is the one PHY
   requirement whose *timing* is easy — but the pulse must still
   satisfy the link-pulse template at the MDI (item 2), as a
   shaped differential pulse through magnetics (items 1, 3). A
   100 ns single-ended GPIO blip is a pulse of the right width and
   the wrong everything else. Jabber protection (transmitter must
   self-disable after ~20–30 ms of continuous transmission) is
   likewise a PHY function TEMPO would have to emulate in firmware
   while simultaneously being the thing it is policing.

### 6.2 Receive path

The RX direction fails earlier and harder:

1. **There is no receiver.** A 10BASE-T receiver is a differential
   comparator chain behind the RX magnetics, with a **squelch**
   circuit: signals below a differential threshold (smart-squelch
   thresholds are a few hundred mV differential — e.g. 300–585 mV
   in legacy transceiver datasheets) must be rejected as noise/
   idle, and valid-signal detection must unsquelch within a few
   bit times. TEMPO's inputs are standard digital pads with fixed,
   single-ended, logic-level thresholds (a substantial fraction of
   the 3.3 V rail). They cannot see a ±2.5 V differential signal
   centred on a common-mode set by the magnetics, cannot implement
   squelch, and cannot reject the common-mode interference Clause
   14 requires the receiver to tolerate. Connecting a twisted pair
   to two GPIO inputs does not produce a degraded receiver; it
   produces no receiver — the signal of interest is differential
   and sub-threshold in single-ended terms for much of its swing.
2. **No differential pair, no polarity detection, no collision
   detection.** Clause 14 receivers detect and correct reversed
   polarity, and half-duplex operation derives collision detect
   from simultaneous TX/RX activity at the *analog* level. None of
   these functions has a digital-pad analogue.
3. Even granting an external comparator glued to a pin (at which
   point the "PHY" is already external — see §7c), the digital RX
   problems of §2.1 and §4.3 (20 ns sampling grid, 2-FF latency,
   5 cycles/bit firmware budget) remain fully in force.

**Summary of §6:** TX fails on template/voltage/common-mode/
magnetics; RX fails at the pad, before firmware is even reached.
These are not "stretch" difficulties. They are the definition of
what a PHY chip is for.

---

## 7. Escape hatches — each closed with numbers

| # | Hatch | Numbers | Status |
|---|---|---|---|
| a | Clock the ASIC faster | Need 100 MHz for exact half-bits (10 ns cycle). Slow-corner fmax = **43.61 MHz**; typ = 68.21 MHz; fast = 88.35 MHz (§3.1). 100 MHz is 2.29× slow fmax — unreachable at *every* corner. Even nominal 50 MHz exceeds slow-corner fmax. | **CLOSED** |
| b | Demo it on the FPGA (Zybo) at 100 MHz | 100 MHz ⇒ 10 ns cycle ⇒ 10 cycles/bit, **5 cycles/half-bit, exact**. Cycle math closes. §6 analog failures unchanged. Proves ISA timing scaling; proves nothing about the ASIC. | **OPEN as a demo; CLOSED as evidence for the ASIC** |
| c | External PHY / MAC-PHY chip | MII @10 Mb/s: TX_CLK = 2.5 MHz, nibble period = **400 ns = 20 cycles @50 MHz** — trivial. SPI-host MAC/PHY (e.g. ENC28J60 class): TEMPO SPI master already proven at ~50 cycles/bit firmware scale (§5.3 mapping) — easier still. PHY chip + magjack do *all* of §§2–6. | **FEASIBLE AS A SYSTEM** — with the claim boundary in §7c |
| d | A different 10M variant (10BASE-T1L / T1S) | T1L: PAM3, 4B3T, **7.5 MBd** — three analogue levels a binary GPIO cannot emit, ternary slicing a digital pad cannot do. T1S: DME at **25 MBd** — 40 ns symbols = 2 cycles/symbol, worse than Manchester. Neither relaxes §6. | **CLOSED (worse)** |

### 7a. "Run the ASIC faster"

The Tiny Tapeout harness clock is supplied by the demo board and
the competition imposes no clock target (SUBMISSION_READINESS
row 9), so nothing *administrative* stops one from feeding the chip
100 MHz. Physics does. STA (§3) is a property of the placed design:
the slow-corner critical path (the `u_imem/A_DOUT[18]` fetch net)
needs 22.933 ns. At a 10 ns period that path fails by ~12.9 ns —
not a marginal violation a lucky cool chip might survive, but a
path that is more than twice too slow, at the corner that
guarantees operation over voltage and temperature. Even the
*typical* corner (68.21 MHz) and the *fast* corner (88.35 MHz) are
below 100 MHz. There is no manufactured corner of this design at
which the half-bit becomes exact. Hatch closed.

(For scale: 60 MHz would give 6 cycles/bit, 3 cycles/half —
representable, but with §2.1's firmware budget at 6 cycles/bit
still implausible, §6 untouched, and 60 MHz still above slow-corner
fmax. No intermediate clock rescues the idea.)

### 7b. "The FPGA ran other protocols at 100/125/150 MHz"

True, and worth stating precisely. The Zybo (Zynq-7010) build of
this design family has run protocol firmware at 100 MHz and above
(the project's hardware campaigns include SPI work at 125 MHz).
At 100 MHz on the FPGA:

- cycle = 10 ns; bit cell = 10 cycles; half-bit = **5 cycles,
  exactly**. Dithering disappears; §4's jitter argument disappears
  *for the digital stream* (FPGA clock jitter and pad behaviour
  then set the jitter floor, comfortably inside ±5.5 ns scale).
- The §2.1 firmware budget doubles to 10 cycles/bit. A minimal
  Manchester TX loop — and plausibly a constrained RX — becomes
  writable. This is a legitimate, interesting firmware exercise.

What it would prove: that the TEMPO timing contract (§1) scales
with clock exactly as specified — the listing-is-the-proof model
holds at 10 ns just as at 20 ns. That is a real, if modest,
methodology data point.

What it would **not** prove:

- Anything about the ASIC. The ASIC's clock ceiling is set by its
  own STA (§3), not by what an Artix-7 fabric — a different process,
  different standard cells, different everything — sustains. A
  100 MHz FPGA result cited next to a 43.61 MHz slow-corner fmax
  ASIC invites exactly the misreading the project's honesty
  standard ("Do not claim," ARCHITECTURE.md §5.5) exists to avoid.
- 10BASE-T compliance. §6 applies verbatim to FPGA GPIO: single-
  ended pads, no template, no magnetics, no squelch receiver.
  The FPGA demo would be a *Manchester signalling* demo. Calling
  it "10BASE-T on TEMPO" would be wrong on the FPGA for the same
  analog reasons it is wrong on the ASIC.

Verdict for this hatch: **FPGA-only curiosity.** Build it only if
it is labelled as exactly that.

### 7c. External PHY — feasible system, and the claim boundary

Connect a real 10BASE-T PHY (or integrated MAC+PHY) to the board,
give it its magjack, and let TEMPO drive its *digital* interface:

- **MII (10 Mb/s mode):** TX_CLK = 2.5 MHz; data moves one nibble
  per TX_CLK ⇒ **400 ns per nibble = 20 core cycles @50 MHz**.
  TEMPO has 20 cycles to present 4 bits and manage TX_EN — against
  proven firmware patterns that do full SPI bytes in ~50 cycles/bit
  (§5.3), this is comfortable, with the Observer free to snoop the
  MII as a bonus demo. RX is symmetric (RX_CLK 2.5 MHz, plus the
  architectural 2-cycle synchronizer latency, constant and
  compensated per T5).
- **RMII** would be a poorer fit (50 MHz reference, 2-bit data at
  the core's own clock rate — synchronous-interface work for no
  benefit at 10 Mb/s). Prefer MII.
- **SPI-host MAC+PHY chips** (the ENC28J60 class: full MAC + 
  10BASE-T PHY behind an SPI slave interface, needing only the
  magnetics jack externally) are easier still: TEMPO's SPI-master
  firmware is a *proven, mandatory-protocol* capability, the chip
  absorbs every requirement in §§2–6 including Manchester, CRC,
  template, NLP and squelch, and TEMPO's job reduces to register
  writes and frame-buffer transfers at SPI speeds it already meets.

So the *system* — a TEMPO chip, on a board, exchanging real
Ethernet frames with a real switch, link LED lit, pings answered —
is entirely achievable, and would make a fine demo photograph.

The distinction that decides the narrative, stated plainly:

> **In this configuration the protocol emulation is performed by
> the PHY vendor's silicon. TEMPO is acting as a (very timing-
> capable) host controller. This demonstrates TEMPO's host-interface
> competence and its proven SPI/MII-class firmware — it does not
> demonstrate the timed ISA emulating the Ethernet protocol, which
> is the competition's premise ("protocols are firmware, not fixed
> logic" — here the protocol would be neither: it would be someone
> else's fixed logic).**

Permitted claim: *"TEMPO + external PHY: the chip drives a
commercial 10BASE-T PHY over MII/SPI and exchanges live Ethernet
frames."* Prohibited claim: *"TEMPO implements 10 Mbit Ethernet."*
Judges who know what a PHY is will draw this line themselves; the
submission is stronger for drawing it first.

### 7d. Other 10-megabit variants

- **10BASE-T1L** (802.3cg Clause 146, single-pair, 1 km reach):
  line coding is **PAM3 with 4B3T at 7.5 MBd** — three line levels
  (+/0/−). A binary GPIO cannot emit the zero-vs-driven distinction
  as a third *analogue* level, and a digital pad cannot slice a
  ternary signal, quite apart from its full-duplex echo-cancellation
  receiver. Strictly harder than Manchester on every axis that
  matters here.
- **10BASE-T1S** (Clause 147): differential Manchester (DME) but at
  **25 MBd** — 40 ns symbols = 2 cycles/symbol at 50 MHz. Worse
  than 10BASE-T's 2.5 cycles/half-bit.
- No standardised 10 Mb/s Ethernet variant reduces the signalling
  burden below 10BASE-T's while removing the analog PHY. Hatch
  closed.

---

## 8. Verdict restated, and the README paragraph

**(i) TEMPO-as-10BASE-T-PHY on the ASIC: NOT FEASIBLE.**
Three independent, individually sufficient grounds: non-representable
half-bit timing at any clock the silicon can reach (§§2–4), a
slow-corner fmax of 43.61 MHz against a 100 MHz requirement (§3),
and the absence of every analog element the standard defines a
10BASE-T PHY by (§6). ARCHITECTURE.md §5.5 / decision D8 ("10BASE-T
out of scope at 50 MHz") stand confirmed.

**(ii) TEMPO + external PHY as a system: ASIC CAPABILITY,
system-level only.** Feasible with large timing margin (§7c), on
the strict condition that all public wording attributes the
Ethernet PHY/MAC work to the external chip.

**(iii) FPGA Manchester demo at 100 MHz: FPGA-ONLY CURIOSITY.**
Physically possible, methodologically mildly interesting,
evidentially worthless for the ASIC, and still not 10BASE-T (§7b).

### README paragraph (drop-in, plain language)

> **Why TEMPO does not do 10 Mbit Ethernet on-chip — and what it
> does instead.** 10BASE-T sends data as Manchester code: every
> 100 ns bit has a transition in its middle, 50 ns in. TEMPO runs
> at 50 MHz, so its pins can only change every 20 ns — that's
> 5 cycles per bit but only 2.5 cycles per half-bit, and 50 ns
> simply isn't on the 20 ns grid. Alternating 40 ns and 60 ns
> half-bits averages out to the right rate but puts every other
> edge ±10 ns out of place, which alone exceeds the Ethernet
> standard's ±5.5–8 ns transmitter jitter limit — and the chip's
> slow-corner timing closure is 43.6 MHz, so the 100 MHz clock
> that would fix the arithmetic isn't reachable in silicon
> anyway. Even with perfect timing, 10BASE-T is an analogue
> standard — a shaped differential waveform through isolation
> magnetics, with a squelch receiver at the other end — and
> TEMPO's pins are plain digital I/O, so there is no on-chip PHY
> to build. What TEMPO *can* do is drive an external 10BASE-T PHY
> chip over its digital interface (an MII nibble lasts 20 TEMPO
> cycles; an SPI-attached MAC/PHY is easier still) and exchange
> real Ethernet frames that way — with the PHY chip, honestly
> credited, doing the wire protocol. We'd rather publish the
> arithmetic than claim the stretch goal.

---

## 9. Sources

**Project files (this repo / project directory):**

- ARCHITECTURE.md §2.2 (cycle-exact contract, items 1–2), §2.4,
  §5.3–§5.5 (firmware mappings; stretch table: "10BASE-T Ethernet …
  ❌ not feasible at 50 MHz"), §9.3 decision D8.
- ISA_v0.2.md §3 (instruction encodings, `1+d` cycles), §5
  (timing contract T1, T2, T3, T5, T11).
- FINAL_STATS.md §§4–5 — STA from GitHub Actions run 40575084383,
  HEAD `76451e0`: slow-corner (1.08 V / 125 °C) WNS −2.933 ns,
  TNS −171.68 ns, 131 violators, single source `u_imem/A_DOUT[18]`;
  typ worst slack +5.339 ns, fast +8.681 ns; hold clean all corners;
  prior-run reconciliation (−2.880 ns, run 40520569898). fmax
  figures in §3.1 are arithmetic on these quoted numbers.
- SUBMISSION_READINESS_2026-10-27.md rows 8–10 — 24 digital pins,
  no analog pins; no imposed clock target, designer-chosen 50 MHz;
  gl_test green on HEAD `e99ff28`, run 40609957985.

**External (802.3 numbers only; retrieved 2026-10-27):**

- Transmitter jitter limits (±5.5 ns with TPM, ±8.0 ns without),
  common-mode < 50 mV peak, return loss ≥ 15 dB (5–10 MHz):
  Texas Instruments, *DP8382x IEEE 802.3u Compliance and Debug*
  (SNLA266B), §§3.3.2.3–3.3.2.7 —
  https://www.ti.com/lit/an/snla266b/snla266b.pdf?ts=1783855792597
- Clause-14 test table (peak differential voltage 2.2–2.8 V,
  harmonic content ≥ 27 dB, output timing jitter, MAU template,
  IEEE Std 802.3-2022 §14.3.1.2.1 / §14.3.1.2.3): Fixture Solution
  10BASE-T TPM product/test summary —
  https://fixturesolution.com/product/10baset/
- Normal Link Pulse: nominally 100 ns, every 16 ms ± 8 ms in the
  absence of transmit data; link-loss behaviour: TI DP83843
  datasheet §2.4.5 (Normal Link Pulse Detection/Generation) —
  https://www.alldatasheet.co.uk/html-pdf/2203102/TI2/DP83843BVJESLASHNOPB.B/2009/24/DP83843BVJESLASHNOPB.B.html
  ; corroborated by Cisco, *Internetworking Technologies Handbook*,
  ch. 7 ("10Base-T … link integrity test … NLP about once every
  16 ms").
- 10BASE-T1L: PAM3 / 4B3T at 7.5 MBd for 10 Mb/s: *Electronic
  Design*, "New Ethernet Standard Solves Range Limitation for
  Industrial Applications"; IEEE 802.3cg variant table
  (10BASE-T1L 7.5 MBd PAM-3; 10BASE-T1S 25 MBd DME) via
  "Ethernet over twisted pair," Wikipedia (802.3cg rows).

*No number in §§2–4 depends on the external sources except the
±5.5 / ±8.0 ns jitter limits in §4.2; the representability failure
(§2), the STA ceiling (§3), and the analog absence (§6) stand on
project evidence alone.*
