; =============================================================================
; TEMPO-32 SPI master firmware -- mode 0 (CPOL=0, CPHA=0), 1 MHz
; 50 MHz core -> 20 ns/cycle; 1 Mbit/s -> exactly 50 cycles/bit.
;
; HOST COMMAND WORDS (16-bit, via RX FIFO; responses via TX FIFO):
;   0x0001  TRANSFER : PULL N (byte count, 0..15), then PULL N data words
;                      (low 8 bits used). CS# low for the whole N-byte
;                      transaction, full-duplex MSB-first bit-bang.
;                      PUSH one received-byte word per byte, then PUSH
;                      0x0000 status, `evt 0`, loop.
;   0x0003  SET MODE : PULL one mode word (0=mode0, 1=mode3). Mode 3 is NOT
;                      implemented (see decision below); consumes the arg
;                      word, PUSHes 0xFFFF (unsupported), `evt 0`, loop.
;   0x00FF  HALT     : HLT (host GO wakes).
;   other            : PUSH 0xFFFF (unknown), `evt 0`, loop.
; Max N = 15 (N rx words + 1 status word must fit the 16-deep TX FIFO).
;
; OBSERVER DEBUG RECIPE (host programs via WR_CFG, firmware never touches
; trace SRAM -- Q4):
;   Capture every SCLK-high window of a transaction (PATTERN, level):
;     WR_CFG TRIG_MODE=0x02 (PATTERN) ; MASK=0x24 (pins 5,2) ; VALUE=0x04
;       -> fires while {CS#=0 & SCLK=1}; one byte = 8*25 = 200 entries,
;       fits the 204-entry trace exactly. Then OBS_CTL=0x01 (OBS_EN, LAST).
;     Host: RD_TRACE -> entries {ts,pins}; OBS_PTR = entry count.
;   Or mark transaction boundaries only (EDGE): EDGE_MASK=0x20,
;     EDGE_CFG1=0x08 (pin5 falling, bits[3:2]=10), TRIG_MODE=0x01, OBS_EN.
;
; CYCLE BUDGET (theory; SCLK period measured rising-edge -> rising-edge):
;   bit time        = 50  = 17 fixed insns + SLEEP16 + SLEEP3 + SLEEP14
;                           (17 = shl+jmp+ldi+jmp + psetr + or + psetr
;                            + pget+shr+and+shl+or + psetr + djnz)
;   SCLK high       = 25 cycles (phys), SCLK low = 25 cycles (phys)
;   MISO sample     = pget base cycle R+5 -> samples phys(R+3); SCLK is
;                     high on phys(R+1)..phys(R+25), so the sample lands
;                     mid-high-period, 2-cycle input sync accounted.
;   byte time       = 407 cycles rising-edge -> rising-edge across the
;                     byte boundary = 400 + 7 overhead. (7 = inter-byte
;                     gap 32c falling->rising vs 25c within a bit: the
;                     13-insn byte prologue/epilogue costs 7c more than
;                     one 50c bit slot.)
;   N=0 transfer    = 13 cycles (CS# low for 3 cycles), no SCLK edges.
;   per-cmd decode  <= 8 cycles. init = 15 cycles.
;
; INIT DEVIATION from the stock R_ONE idiom: R_ONE is done with
; `pdir 0x01` (pin0 only) instead of `pdir 0xFF`, and the idle pin levels
; (`pset 0x20`) are committed BEFORE `pdir 0x2E` enables the SPI drivers.
; The stock order (pdir 0x2E while pin_drv[5]=0) would glitch CS# low for
; ~2 cycles at boot -- a real slave would see a phantom transaction.
;
; MODE-3 DECISION: omitted. Mode 3 needs a second pin-byte pair
; (CPOL=1 idle: 0x24/0x2C/0x28 variants), inverted edge order in the bit
; loop, and a second sample path -- ~20 extra words for a second 50-cycle
; bit loop, over the <15-word budget. 0x0003 therefore returns 0xFFFF.
;
; Register use: r0=0 (zeroed at init, never written), r1=MOSI pins byte,
; r2=pins byte+SCLK, r3=MISO sample, r4=tx shifter, r5=rx accumulator,
; r6=cmd/misc, r7=bit counter, r8=byte counter, r9=4 (SCLK mask/shr4),
; r12=8 (shl8), r13=3 (cmd compare), r14=0xFF (byte mask/cmd compare),
; r15=1 (R_ONE, preserved). No WAIT used (T17 pressure: none).
; Image: 71 words (target <=150, hard limit 256).
; =============================================================================

; ---- init: R_ONE idiom, pin config, constants -------------------------------
; NOTE: pdir 0x01 (not 0xFF) for R_ONE -- see header INIT DEVIATION note.
        pdir 0x01
        pmask 0xFF
        pset 0x01, d=4
        pget r15                 ; r15 = 1 (preserve forever)
        pmask 0x2C               ; pin ops touch only pins 2,3,5
        pset 0x20                ; idle levels first: CS#=1, SCLK=0, MOSI=0
        pdir 0x2E                ; THEN drive SCLK(2), MOSI(3), CS#(5)
        xor r0, r0, r0           ; r0 = 0
        ldi r9, 4                ; SCLK bit mask, also shr-by-4 amount
        ldi r14, 0x0100
        sub r14, r14, r15        ; r14 = 0xFF (byte mask, 0x00FF compare)
        ldi r12, 8               ; shl-by-8 amount
        add r13, r15, r15
        add r13, r13, r15        ; r13 = 3 (0x0003 compare)

; ---- host command loop -------------------------------------------------------
; RACE FIX 2026-09-27: every PULL is now preceded by an RXNE wait. The
; serial host port delivers words ~2000 core clocks apart, but the old
; code pulled frame words back-to-back (~5 cycles apart): 2nd+ words hit
; an empty FIFO, PULL returned 0, and multi-word frames degenerated
; (e.g. N=0 transfer, leftover words eaten as "unknown" commands).
cmd_loop:
        jmp cmd_have, rxne       ; wait for host command word
        jmp cmd_loop
cmd_have:
        pull r6                  ; cmd word
        cmp r6, r15              ; 0x0001 = transfer?
        jmp do_xfer, z
        cmp r6, r13              ; 0x0003 = set mode?
        jmp do_mode, z
        cmp r6, r14              ; 0x00FF = halt?
        jmp do_hlt, z
        jmp do_unk               ; unknown cmd

; ---- 0x0001 transfer ----------------------------------------------------------
do_xfer:
        jmp xfer_n_have, rxne    ; wait for N word (see RACE FIX note)
        jmp do_xfer
xfer_n_have:
        pull r8                  ; N bytes
        pset 0x00                ; CS# low (SCLK=0, MOSI=0)
        cmp r8, r0               ; N == 0?
        jmp xfer_done, z
byte_next:
        jmp byte_have, rxne      ; wait for data word (see RACE FIX note)
        jmp byte_next
byte_have:
        pull r4                  ; tx data word
        and r4, r4, r14          ; low 8 bits
        shl r4, r4, r12          ; byte -> bits[15:8] (MSB-first via shl/C)
        ldi r5, 0x0000           ; rx accumulator = 0
        ldi r7, 8                ; bit counter
bit_loop:                        ; 50 cycles/bit; rising edge = `psetr r2`
        shl r4, r4, r15          ; C = next tx bit (MSB first)
        jmp mbit1, c
        ldi r1, 0x00             ; MOSI=0 pins byte
        jmp mbitx
mbit1:
        ldi r1, 0x08             ; MOSI=1 pins byte
        jmp mbitx
mbitx:                           ; both paths = 4 cycles (jmp is 1c either way)
        psetr r1                 ; SCLK=0, MOSI=bit, CS#=0
        sleep 16                 ; SCLK low half-period
        or r2, r1, r9            ; set SCLK bit
        psetr r2                 ; *** SCLK rising edge ***
        sleep 3                  ; settle past 2-cycle input sync
        pget r3                  ; sample MISO (SCLK high)
        shr r3, r3, r9           ; pin4 -> bit0
        and r3, r3, r15          ; isolate MISO bit
        shl r5, r5, r15          ; rx <<= 1
        or r5, r5, r3            ; rx |= MISO bit
        sleep 14                 ; SCLK high half-period
        psetr r1                 ; *** SCLK falling edge ***
        djnz r7, bit_loop
        push r5                  ; report received byte
        djnz r8, byte_next
xfer_done:
        pset 0x20                ; CS# high
        push r0                  ; status 0x0000 = OK
        evt 0
        jmp cmd_loop

; ---- 0x0003 set mode (mode 3 not implemented) ----------------------------------
do_mode:
        jmp mode_have, rxne      ; wait for mode word (see RACE FIX note)
        jmp do_mode
mode_have:
        pull r6                  ; consume mode word, then report unsupported
do_unk:                          ; unknown command -> 0xFFFF
        ldi r6, 0xFFFE
        add r6, r6, r15          ; r6 = 0xFFFF (ldi is even-only)
        push r6
        evt 0
        jmp cmd_loop

do_hlt:
        hlt
