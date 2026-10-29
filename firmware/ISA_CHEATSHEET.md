# TEMPO-32 ISA Cheatsheet (firmware phase)

Authoritative source: `../isa_v0.2.yaml`. This is a convenience summary.
50 MHz core → **1 cycle = 20 ns**. All instructions: **1+d cycles** (d=0..31),
except SLEEP (1+imm13), WAIT (1..1+timeout), HLT (indefinite).

## Assembler (`tools/asm.py`)

```
python3 tools/asm.py in.asm -o out.hex --listing out.lst
```
Labels, `.org addr`, `.word`, `;` comments. Registers `r0`..`r15`.
Delay suffix `, d=N` where allowed. `python3 tools/tb.py run tests/test_x.py`
runs a test module; `python3 tools/tb.py selftest` checks the tools.

## Instruction syntax

| Mnemonic | Operands | Notes |
|---|---|---|
| `pset imm8 [, d=N]` | 0..255 | pins ← (pins&~PMASK)\|(imm8&PMASK), effect end of cycle 0 |
| `psetr rs [, d=N]` | reg | pins ← (pins&~PMASK)\|(rs[7:0]&PMASK) |
| `pget rd [, d=N]` | reg | rd ← synchronized pins (2-FF delay!) sampled end of base cycle |
| `pmask imm8 [, d=N]` | 0..255 | write pin-mask (reset 0xFF) |
| `pdir imm8 [, d=N]` | 0..255 | 1=drive, 0=Hi-Z (reset 0x00 = all Hi-Z) |
| `pmode rs [, d=N]` | reg | rs[2i+1:2i]={open_drain,pull_up} per pin i |
| `sleep imm13` | 0..8191 | exactly 1+imm13 cycles. **Use for precise delays.** |
| `wait pin,pol,mode,tsel,rd` | pin 0..7, pol 0/1, mode level/rising/falling/either, tsel 0..3, rd | rd ← elapsed (0 if true at entry); TIMEOUT sticky on expiry |
| `cap rd [, d=N]` | reg | rd ← ts[15:0]; full snapshot in CTS_HI / CTS_PINS |
| `mov rd,rs [, d=N]` | regs | |
| `ldi rd,imm16 [, d=N]` | **imm16 even only** (bit0 reserved!) | see R_ONE idiom |
| `push rs [, d=N]` | reg | TX FIFO ← rs; full → drop + TX_OVERRUN (never stalls) |
| `pull rd [, d=N]` | reg | rd ← RX FIFO; empty → rd=0 + RX_UNDERRUN |
| `mrs rd,sreg [, d=N]` | sreg name/number | |
| `msr rs,sreg [, d=N]` | sreg name/number | STATUS = W1C; EVTFLAG writes ignored |
| `add/sub rd,rs1,rs2` | regs | Z,N,C |
| `and/or/xor rd,rs1,rs2` | regs | Z,N |
| `shl/shr rd,rs1,rs2` | regs | amount=rs2[3:0]; C=last bit shifted out; Z,N |
| `cmp rs1,rs2 [, d=N]` | regs | flags only |
| `jmp target[,cond] [, d=N]` | label/0..255; cond al,z,nz,c,nc,tmo,rxne,txnf | 1+d either way |
| `djnz rs,target [, d=N]` | reg; label/0..255 | decrements first, branches if NEW rs≠0 |
| `call target [, d=N]` | label/0..255 | 4-deep return stack |
| `ret [, d=N]` | | |
| `hlt` | | PE stops; host GO wakes |
| `evt imm4 [, d=N]` | 0..15 | raise host event flag |

WAIT timeouts: tsel 0→256, 1→4096, **2→65536, 3→1048576**.
**T17-OPEN: never use tsel 2/3** (elapsed overflows 16-bit rd; behavior
undecided). Max single WAIT budget: 4096 cycles. Longer waits = loops.

## Special registers (MRS/MSR)

STATUS, CYCLES_LO/HI, CTS_HI, CTS_PINS, OBS_PTR (0..204, saturates),
PMASKR, PDIRR, PMODER, TRIG_MODE (00=DISABLED,01=EDGE,10=PATTERN,11=PULSE;
any write disarms), PIN_SEL, MASK, VALUE, EDGE_MASK, EDGE_CFG0/1,
WMARK, PRESCALER (shared!), OBS_CTL (bit0 OBS_EN, bit2 OBS_CLR strobe),
EVTFLAG.

STATUS bits: 0 TIMEOUT, 1 TX_OVERRUN, 2 RX_UNDERRUN, 3 TRACE_FULL,
4 CONFIG_ERR (stickies, W1C); 8 PE_RUNNING, 9 PE_HALTED, 10 TX_EMPTY,
11 RX_FULL (live); 12 TRACE_WM (sticky event); 13 CFG_DIRTY.

## Pin assignment (logical pins 0..7)

| Pin | Use | Dir |
|---|---|---|
| 0 | UART TX | PE out |
| 1 | UART RX | PE in |
| 2 | SPI SCLK | PE out |
| 3 | SPI MOSI | PE out |
| 4 | SPI MISO | PE in |
| 5 | SPI CS# | PE out |
| 6 | I2C SCL | open-drain bidir |
| 7 | I2C SDA / 1-Wire | open-drain bidir (reconfigured per demo) |

Open-drain: `pmode` bit[2i+1]=1; then PSET 0 = drive low, PSET 1 = release
(Hi-Z). Set pull_up bit[2i]=1 for I2C/1-Wire.

## Firmware conventions

* **R_ONE idiom** (LDI/ALU are closed over *even* values — LDI bit0 is
  reserved): materialize 1 at boot from the pin unit:
  ```
  pdir 0xFF / pmask 0xFF
  pset 0x01, d=4      ; drive pin0 high, settle 2-FF sync
  pget r15            ; r15 = 1  (preserve r15 forever)
  ```
* Register use: r0–r7 scratch; r8–r14 protocol state; **r15 = 1 (preserved)**.
* Each protocol = **standalone image** (own init + R_ONE + host command
  loop), target ≤150 words, hard limit 256.
* Host commands are **16-bit words** via RX FIFO (host WR_RXFIFO packs
  bytes MSB-first; workers define word-oriented commands):
  cmd 0x0001 = run demo, followed by arg words; PE PUSHes result words,
  `evt 0` on completion, loops for next command; cmd 0x00FF = HLT.
* **Q4**: firmware can NEVER read trace SRAM. Debug = Observer configured
  for host readout (see recipe below) + PUSH/EVT to host.
* Delays: `sleep` for exact timing; `wait` for event sync + elapsed
  measurement. Remember the **2-cycle input sync**: an edge on the wire
  is visible to PGET/WAIT/CAP 2 core cycles later — calibrate sampling
  points against the *synchronized* pins (the sim models this exactly).

## Observer debug recipe (for your .asm header)

```
; capture failing transaction on pin1 falling edge, host reads trace:
msr rX, EDGE_MASK   ; rX = 0x02 (pin1)
msr rY, EDGE_CFG0   ; rY = 0x04 (pin1 = falling, bits[3:2]=10)
msr rZ, TRIG_MODE   ; rZ = 1 (EDGE; write disarms, so...)
msr rW, OBS_CTL     ; rW = 1 (OBS_EN, LAST)
; ... run transaction ...
; host: RD_TRACE (0x07) -> entries {ts,pins}, OBS_PTR count
```

## Cycle math (theory)

| Protocol | Rate | Bit time | Notes |
|---|---|---|---|
| UART | 115200 | **434 cycles** | 10 bits/byte = 4340 + loop ovhd |
| SPI | 1 MHz | **50 cycles** | SCLK half-period 25 |
| I2C | 100 kHz | **500 cycles** | SCL high/low 250 |
| 1-Wire | — | 1 µs = 50 cycles | reset 480µs=24000c; slot 70µs=3500c |

Report **measured vs theory** per byte/transaction from sim logs.
