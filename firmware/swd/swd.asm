; =============================================================================
; Tarang-32 SWD master firmware -- ARM Serial Wire Debug, DP access only
; 50 MHz core -> 20 ns/cycle. SWCLK period = 32 cycles exactly within any
; clocked phase -> SWCLK = 50 MHz / 32 = 1.5625 MHz.
;
; PIN MAP (logical pins, standalone image -- overrides the cheatsheet map):
;   pin0 = SWCLK  PE output, idle low
;   pin1 = SWDIO  bidirectional, PUSH-PULL when PE drives (never open-drain)
;   pins 2..7 unused (PMASK 0x03, never driven)
;
; HOST COMMAND WORDS (16-bit, via RX FIFO; responses via TX FIFO):
;   0x0001  SWD_READ_IDCODE : no args. Runs one full DP transaction:
;             (a) LINE RESET -- SWDIO=1 for 56 SWCLK cycles (bits)
;             (b) DP IDCODE READ REQUEST, 8 bits LSB-first on the wire:
;                 start=1, APnDP=0, RnW=1, A[2]=0, A[3]=0, parity=1,
;                 stop=0, park=1   (parity = XOR(APnDP,RnW,A2,A3) = 1;
;                 wire byte assembled LSB-first = 0xA5)
;             (c) TURNAROUND 1 SWCLK, SWDIO released (PDIR pin1=0)
;             (d) ACK: 3 bits LSB-first from target (expect OK: bits
;                 1,0,0 => ACK value 1)
;             (e) READ DATA: 32 bits LSB-first from target
;             (f) PARITY: 1 bit, even parity over the 32 data bits
;             (g) TURNAROUND back (1 SWCLK, released), SWCLK idle low,
;                 PE drives SWDIO again.
;             PUSH words, in order: ACK value, IDCODE low 16 bits,
;             IDCODE high 16 bits, parity-ok flag (1 if the received
;             parity bit equals the parity computed from the received
;             data, else 0). Then `evt 0`, loop.
;   0x00FF  HALT : HLT (host GO wakes).
;   other        : PUSH 0xFFFF (unknown), `evt 0`, loop.
;
; BIT TIMING (all phases, identical 32-cycle cell):
;   SWCLK low phase = 16 cycles, high phase = 16 cycles.
;   TX bits: PE sets SWDIO at the SWCLK falling commit, holds it through
;     the rising commit (the target samples on the rising edge).
;   RX bits: target presents the bit at the SWCLK falling commit (edge-
;     driven peer/real target changes SWDIO there); the PE PGET executes
;     in the last low-phase cycles and, through the 2-FF synchronizer,
;     samples the physical line ~2 cycles before the rising commit --
;     i.e. late in the low phase, bit stable since the falling commit.
;     Bit accounting (add/shift) runs in the high phase, after the rise.
;   Phase boundaries stretch the SWCLK high phase by a few setup cycles
;     (RET + result-store + count setup + CALL + init = +6 cycles on
;     RX->RX boundaries, measured 38-cycle rise-to-rise there). SWD is
;     fully static: a stretched high/low phase between phases is legal.
;
; CYCLE BUDGET (measured by the golden test, see tests/test_swd.py):
;   reset 56 bits, request 8, turnaround 1, ACK 3, data 32, parity 1,
;   turnaround 1  = 102 SWCLK rising edges total per transaction.
;
; OBSERVER DEBUG RECIPE (host programs via WR_CFG; firmware never reads
; trace SRAM -- Q4): capture SWCLK rising windows (PATTERN):
;   MASK=0x01 VALUE=0x01 TRIG_MODE=0x02, OBS_CTL=0x01 -> one trace entry
;   per SWCLK-high cycle; host RD_TRACE / OBS_PTR reads it back.
;
; REAL-WORLD NOTE: real SWD targets expect SWDIO through a small series
; resistor (~100 ohm) and the host must respect the target's minimum
; turnaround / SWCLK timing; this firmware is push-pull both ways and
; relies on strict phase separation (PE and target never drive at the
; same time -- verified by the checker) instead of resistor sharing.
; Wiring to a real target (e.g. a Cortex-M board) is listed in the
; campaign report; no hardware run is claimed here.
;
; Register use: r0=0 (preserved), r1/r2 = TX pins bytes, r3 = RX bit,
; r4 = RX place value (subroutine), r5 = RX result (subroutine),
; r6 = scratch / parity fold, r7 = bit counter / fold scratch,
; r8 = reset counter / fold shift amount, r9 = ACK store,
; r10 = IDCODE low, r11 = IDCODE high, r12 = received parity bit,
; r13 = parity-ok flag, r14 = 0xFF (halt compare), r15 = 1 (R_ONE).
; Image: see listing (target <=150 words, hard limit 256).
; =============================================================================

; ---- init: R_ONE idiom (pin0 only, as in the SPI image: pin0 = SWCLK) ------
        pdir 0x01
        pmask 0xFF
        pset 0x01, d=4           ; drive SWCLK high, settle 2-FF sync
        pget r15                 ; r15 = 1 (preserve forever)
        xor r0, r0, r0           ; r0 = 0
        pmask 0x03               ; pin ops touch only SWCLK/SWDIO
        pset 0x00                ; idle levels: SWCLK=0, SWDIO=0
        pdir 0x03                ; drive SWCLK + SWDIO (push-pull)
        ldi r14, 0x0100
        sub r14, r14, r15        ; r14 = 0xFF (0x00FF halt compare)

; ---- host command loop -------------------------------------------------------
cmd_loop:
        jmp cmd_have, rxne       ; wait for host command word
        jmp cmd_loop
cmd_have:
        pull r6                  ; cmd word
        cmp r6, r15              ; 0x0001 = SWD IDCODE read?
        jmp do_txn, z
        cmp r6, r14              ; 0x00FF = halt?
        jmp do_hlt, z
        jmp do_unk               ; unknown cmd

do_unk:                          ; unknown command -> 0xFFFF
        ldi r6, 0xFFFE
        add r6, r6, r15          ; r6 = 0xFFFF (ldi is even-only)
        push r6
        evt 0
        jmp cmd_loop

do_hlt:
        hlt

; ---- 0x0001: line reset + DP IDCODE read -------------------------------------
do_txn:
; (a) line reset: SWDIO=1 for 56 SWCLK bits, 32 cycles each
        ldi r8, 56
reset_loop:
        pset 0x02                ; SWCLK=0, SWDIO=1 (falling commit)
        sleep 14                 ; low phase: 15 + pset-high = 16
        pset 0x03                ; SWCLK=1, SWDIO=1 (rising commit)
        sleep 13                 ; high phase: 14 + djnz + pset-low = 16
        djnz r8, reset_loop
; (b) request byte 0xA5, LSB-first (wire: 1,0,1,0,0,1,0,1)
        ldi r7, 8                ; bit counter
        ldi r4, 0x00A4
        add r4, r4, r15          ; r4 = 0xA5 request shifter
tx_loop:                         ; 32 cycles/bit, SWDIO set at falling commit
        shr r4, r4, r15          ; C = next wire bit (LSB first)
        jmp tx_one, c
        ldi r1, 0x00             ; SWCLK=0, SWDIO=0
        jmp tx_go
tx_one:
        ldi r1, 0x02             ; SWCLK=0, SWDIO=1
        jmp tx_go
tx_go:                           ; both branch paths = 4 cycles
        psetr r1                 ; falling commit: SWDIO = bit
        sleep 13                 ; 14 + or + psetr-high = 16 low
        or r2, r1, r15           ; set SWCLK bit (pin0)
        psetr r2                 ; *** rising commit: target samples ***
        sleep 9                  ; 10 + djnz+shr+jmp+ldi+jmp+psetr = 16 high
        djnz r7, tx_loop
; (c) turnaround: release SWDIO, 1 SWCLK
        pdir 0x01                ; SWDIO = input (PE no longer drives)
        pset 0x00                ; falling commit (SWCLK low)
        sleep 14
        pset 0x01                ; rising commit (turnaround bit)
        sleep 13
; (d) ACK: 3 bits LSB-first from target
        ldi r7, 2
        add r7, r7, r15          ; r7 = 3
        call rx_bits
        mov r9, r5               ; ACK value
; (e) read data: 32 bits LSB-first, in two 16-bit halves
        ldi r7, 16
        call rx_bits
        mov r10, r5              ; IDCODE low
        ldi r7, 16
        call rx_bits
        mov r11, r5              ; IDCODE high
; (f) parity: 1 bit
        mov r7, r15              ; r7 = 1
        call rx_bits
        mov r12, r5              ; received parity bit
; (g) turnaround back: SWDIO still released for this clock, then re-drive
        pset 0x00                ; falling commit (target releases here)
        sleep 14
        pset 0x01                ; rising commit (turnaround bit)
        sleep 13
        pset 0x00                ; SWCLK idle low
        pdir 0x03                ; PE drives SWDIO again (idle low)
; parity check: computed even parity = XOR-fold of (low ^ high)
        xor r6, r10, r11
        ldi r8, 8
        shr r7, r6, r8
        xor r6, r6, r7
        ldi r8, 4
        shr r7, r6, r8
        xor r6, r6, r7
        add r8, r15, r15         ; r8 = 2
        shr r7, r6, r8
        xor r6, r6, r7
        shr r7, r6, r15
        xor r6, r6, r7
        and r6, r6, r15          ; r6 = computed parity bit
        cmp r6, r12
        jmp pok, z
        mov r13, r0              ; parity bad -> flag 0
        jmp push_seq
pok:
        mov r13, r15             ; parity ok -> flag 1
push_seq:
        push r9                  ; ACK value
        push r10                 ; IDCODE low
        push r11                 ; IDCODE high
        push r13                 ; parity-ok flag
        evt 0
        jmp cmd_loop

; ---- subroutine: receive r7 bits LSB-first -> r5 ----------------------------
; Target presents each bit at the SWCLK falling commit; PGET samples the
; synchronized line late in the low phase (see header). 32 cycles/bit.
; Uses r2,r3,r4,r6. Preserves r0, r9-r15. Clobbers r5,r7.
rx_bits:
        mov r4, r15              ; place value = 1
        ldi r5, 0x0000           ; accumulator = 0
rx_loop:
        pset 0x00                ; falling commit: target presents bit
        sleep 13                 ; 14 cycles of low phase
        pget r2                  ; sample sync'd SWDIO (phys ~2c earlier)
        pset 0x01                ; *** rising commit (16c low phase) ***
        shr r3, r2, r15          ; pin1 -> bit0
        and r3, r3, r15          ; r3 = received bit
        cmp r3, r0
        jmp rx_add, nz
        mov r6, r6               ; pad: 0-path = 1-path (4 cycles)
        jmp rx_cont
rx_add:
        or r5, r5, r4            ; acc |= place
        jmp rx_cont
rx_cont:
        shl r4, r4, r15          ; place <<= 1
        sleep 6                  ; high phase pad: 7+proc7+djnz+pset = 16
        djnz r7, rx_loop
        ret
