; =============================================================================
; Tarang-32 JTAG (IEEE 1149.1) master firmware -- stretch protocol
; 50 MHz core -> 20 ns/cycle.
;
; PIN MAP (logical pins 0..7):
;   pin0 = TCK  (PE out, idle LOW)
;   pin1 = TMS  (PE out)
;   pin2 = TDI  (PE out)
;   pin3 = TDO  (PE in, NEVER driven: pdir bit3 = 0 for the whole image)
;   pins 4..7 unused (Hi-Z).
;
; TCK RATE: <= 2 MHz bound respected with margin. One clock_bit is a
;   31-cycle subroutine (+1 call). Measured rising->rising periods from
;   the golden sim (see tests/test_jtag.py checker): 33 cycles in
;   straight-line navigation / reset loops (1.52 MHz), 37 cycles in the
;   IDCODE Shift-DR and Shift-IR loops (1.35 MHz), 41 cycles in the
;   BYPASS Shift-DR loop (1.22 MHz). TCK high time = 12 cycles,
;   low time = period-12. JTAG is static, so the (deterministic)
;   per-segment periods are spec-legal.
;
; SAMPLING CONTRACT (precise, mirrored by the TB TAP model):
;   * TMS/TDI are driven while TCK is low (psetr at clock_bit entry).
;   * The target samples TMS/TDI on the TCK RISING edge.
;   * The target changes TDO on the TCK FALLING edge.
;   * Firmware samples TDO with PGET during the TCK-low phase, 12 cycles
;     after the falling edge that produced that TDO bit (>> the 2-cycle
;     input synchronizer latency), i.e. TDO is sampled BEFORE the rising
;     edge that shifts it out. Shift data is LSB-first, per 1149.1.
;
; HOST COMMAND WORDS (16-bit, via RX FIFO; responses via TX FIFO):
;   0x0001  IDCODE READ : full sequence from any TAP state --
;                      5x TMS=1 -> Test-Logic-Reset, RTI -> Select-DR ->
;                      Select-IR -> Capture-IR -> Shift-IR (IDCODE opcode
;                      0b0001, 4-bit IR, LSB-first, last bit TMS=1) ->
;                      Update-IR -> RTI -> Select-DR -> Capture-DR ->
;                      Shift-DR 32 bits LSB-first (TDI=0) -> Update-DR ->
;                      RTI. PUSH IDCODE low word, PUSH IDCODE high word,
;                      `evt 0`, loop.
;   0x0002  BYPASS TEST : same navigation, IR <- 0b1111 (BYPASS), then
;                      Shift-DR 8 bits with TDI = 0xA5 LSB-first.
;                      The 1-bit bypass register captures 0, so the bits
;                      shifted out are [0, TDI0..TDI6] = byte 0x4A
;                      (the TDI pattern delayed by exactly one bit).
;                      PUSH that byte as one word, `evt 0`, loop.
;                      Proves both the IR path (opcode decode selects the
;                      1-bit DR) and the DR path (pattern delay).
;   0x00FF  HALT     : HLT (host GO wakes).
;   other            : PUSH 0xFFFF (unknown), `evt 0`, loop.
;
; TARGET MODEL (TB + recorder share it): faithful 16-state TAP, IR
;   length 4, IR capture pattern 0b1101, opcode 0b0001 = IDCODE (also the
;   TLR default), 0b1111 = BYPASS, all other opcodes act as BYPASS;
;   IDCODE = 0x1BA00477 (plausible ARM-style vendor/device code);
;   DR = 32-bit IDCODE register or 1-bit bypass register (captures 0).
;
; INIT DEVIATION (same class as SPI): the stock R_ONE idiom drives pin0,
;   which here IS TCK, so boot emits ONE spurious TCK rising edge with
;   TMS=0 (TLR -> RTI in the target). It is harmless by construction:
;   every host command begins with the 5x TMS=1 reset, which reaches
;   Test-Logic-Reset from ANY state, so no command depends on the TAP
;   state left by boot. pdir is 0x01 during R_ONE, then 0x07 -- pin3
;   (TDO) is never an output, so no TDO contention is possible.
;
; Register use: r0=0 (const), r2=bit-build tmp, r3=TDO sample (clock_bit
;   out), r4=TDI shifter (IR opcode / BYPASS pattern), r5=acc bit mask,
;   r6=cmd word / loop counter, r7=clock_bit scratch (TCK-high byte),
;   r8=clock_bit input pins byte (TCK=0 | TMS<<1 | TDI<<2),
;   r9=result low / BYPASS accumulator, r10=result high,
;   r11=3 (TDO shr amount), r12=2 (TMS value / TDI shl amount),
;   r13=0x0002 compare, r14=0x00FF compare, r15=1 (R_ONE, preserved).
;   CALL depth: handlers -> nav/shift subroutines -> clock_bit = 2 deep
;   (limit 4). No WAIT used (no tsel 2/3, nothing to wait for: TCK is
;   firmware-generated and TDO is statically sampled).
; =============================================================================

; ---- init: R_ONE idiom, pin config, constants -------------------------------
        pdir 0x01                ; R_ONE on pin0 only (see INIT DEVIATION)
        pmask 0xFF
        pset 0x01, d=4
        pget r15                 ; r15 = 1 (preserve forever)
        pmask 0x07               ; pin ops touch only TCK/TMS/TDI
        pset 0x00                ; idle levels first: TCK=0, TMS=0, TDI=0
        pdir 0x07                ; THEN drive pins 0,1,2 (pin3 stays input)
        xor r0, r0, r0           ; r0 = 0
        add r12, r15, r15        ; r12 = 2 (TMS byte value; TDI shl amount)
        add r11, r12, r15        ; r11 = 3 (TDO bit position, shr amount)
        mov r13, r12             ; r13 = 2 (0x0002 compare)
        ldi r14, 0x0100
        sub r14, r14, r15        ; r14 = 0xFF (0x00FF compare)

; ---- host command loop -------------------------------------------------------
cmd_loop:
        jmp cmd_have, rxne       ; wait for host command word
        jmp cmd_loop
cmd_have:
        pull r6                  ; cmd word
        cmp r6, r15              ; 0x0001 = IDCODE read?
        jmp do_idcode, z
        cmp r6, r13              ; 0x0002 = BYPASS test?
        jmp do_bypass, z
        cmp r6, r14              ; 0x00FF = halt?
        jmp do_hlt, z
        jmp do_unk               ; unknown cmd

; ---- clock_bit: one full TCK cycle -------------------------------------------
; in:  r8 = pins byte with TCK=0 (bit1=TMS, bit2=TDI)
; out: r3 = TDO bit sampled during the low phase (0/1)
; clobbers r7, r3. 31 cycles + call. TCK high = 12 cycles.
clock_bit:
        psetr r8                 ; TCK low: drive TMS/TDI (falling edge if
                                 ; TCK was high -- target updates TDO now)
        sleep 10                 ; low settle >> 2-cycle input sync
        pget r3                  ; *** sample TDO (TCK low, pre-rise) ***
        shr r3, r3, r11          ; pin3 -> bit0
        and r3, r3, r15          ; isolate TDO bit
        mov r7, r8
        or r7, r7, r15           ; TCK=1 byte
        psetr r7                 ; *** TCK RISING edge (target samples) ***
        sleep 10                 ; TCK high phase
        psetr r8                 ; *** TCK FALLING edge (target updates TDO)
        ret

; ---- tap_reset: 5 clocks TMS=1 -> Test-Logic-Reset from any state ------------
tap_reset:
        ldi r8, 0x02             ; TMS=1, TDI=0, TCK=0
        ldi r6, 4
        add r6, r6, r15          ; r6 = 5
tr_loop:
        call clock_bit
        djnz r6, tr_loop
        ret

; ---- goto_shift_ir: RTI -> SelDR -> SelIR -> CapIR -> ShiftIR ----------------
goto_shift_ir:
        ldi r8, 0x02             ; TMS=1 -> Select-DR
        call clock_bit
        ldi r8, 0x02             ; TMS=1 -> Select-IR
        call clock_bit
        ldi r8, 0x00             ; TMS=0 -> Capture-IR
        call clock_bit
        ldi r8, 0x00             ; TMS=0 -> Shift-IR
        call clock_bit
        ret

; ---- shift_ir: shift r4[3:0] LSB-first into IR (enter in Shift-IR) -----------
; last bit driven with TMS=1 -> Exit1-IR. Clobbers r2, r4, r6, r8 (+clock_bit).
shift_ir:
        ldi r6, 2
        add r6, r6, r15          ; r6 = 3 (bits 0..2 with TMS=0)
sir_loop:
        and r2, r4, r15          ; next TDI bit
        shl r2, r2, r12          ; -> pin2 position
        mov r8, r2               ; pins: TCK=0, TMS=0, TDI=bit
        shr r4, r4, r15          ; advance shifter
        call clock_bit
        djnz r6, sir_loop
        and r2, r4, r15          ; final bit (bit3)
        shl r2, r2, r12
        mov r8, r2
        or r8, r8, r12           ; TMS=1 -> Exit1-IR
        call clock_bit
        ret

; ---- goto_shift_dr: Exit1-IR -> Update-IR -> RTI -> SelDR -> CapDR -> ShiftDR
goto_shift_dr:
        ldi r8, 0x02             ; TMS=1 -> Update-IR (IR latched)
        call clock_bit
        ldi r8, 0x00             ; TMS=0 -> Run-Test/Idle
        call clock_bit
        ldi r8, 0x02             ; TMS=1 -> Select-DR
        call clock_bit
        ldi r8, 0x00             ; TMS=0 -> Capture-DR (DR captures)
        call clock_bit
        ldi r8, 0x00             ; TMS=0 -> Shift-DR
        call clock_bit
        ret

; ---- exit_to_rti: Exit1-x -> Update-x -> RTI ----------------------------------
exit_to_rti:
        ldi r8, 0x02             ; TMS=1 -> Update
        call clock_bit
        ldi r8, 0x00             ; TMS=0 -> Run-Test/Idle
        call clock_bit
        ret

; ---- 0x0001 IDCODE read --------------------------------------------------------
do_idcode:
        call tap_reset           ; -> Test-Logic-Reset (from any state)
        ldi r8, 0x00             ; TMS=0 -> Run-Test/Idle
        call clock_bit
        call goto_shift_ir
        mov r4, r15              ; IR opcode = 0b0001 (IDCODE)
        call shift_ir
        call goto_shift_dr
        ldi r9, 0x0000           ; result low = 0
        mov r10, r0              ; result high = 0
        mov r5, r15              ; bit mask = 1
        ldi r6, 14
        add r6, r6, r15          ; r6 = 15 (DR bits 0..14)
        ldi r8, 0x00             ; TMS=0, TDI=0 for all non-final DR bits
drlo_loop:
        call clock_bit
        cmp r3, r0
        jmp drlo_one, nz
        jmp drlo_done
drlo_one:
        or r9, r9, r5            ; set low bit
drlo_done:
        shl r5, r5, r15          ; next bit position
        djnz r6, drlo_loop
        call clock_bit           ; DR bit 15 (TMS still 0)
        cmp r3, r0
        jmp dr15_one, nz
        jmp dr15_done
dr15_one:
        or r9, r9, r5
dr15_done:
        mov r5, r15              ; bit mask restarts for the high word
        ldi r6, 14
        add r6, r6, r15          ; r6 = 15 (DR bits 16..30)
drhi_loop:
        call clock_bit
        cmp r3, r0
        jmp drhi_one, nz
        jmp drhi_done
drhi_one:
        or r10, r10, r5          ; set high bit
drhi_done:
        shl r5, r5, r15
        djnz r6, drhi_loop
        ldi r8, 0x02             ; DR bit 31 with TMS=1 -> Exit1-DR
        call clock_bit
        cmp r3, r0
        jmp dr31_one, nz
        jmp dr31_done
dr31_one:
        or r10, r10, r5
dr31_done:
        call exit_to_rti
        push r9                  ; IDCODE low word first
        push r10                 ; then high word
        evt 0
        jmp cmd_loop

; ---- 0x0002 BYPASS test ---------------------------------------------------------
do_bypass:
        call tap_reset
        ldi r8, 0x00             ; TMS=0 -> Run-Test/Idle
        call clock_bit
        call goto_shift_ir
        ldi r4, 14
        add r4, r4, r15          ; IR opcode = 0b1111 (BYPASS)
        call shift_ir
        call goto_shift_dr
        ldi r4, 0x00A4
        add r4, r4, r15          ; TDI pattern shifter = 0xA5
        mov r9, r0               ; captured-byte accumulator = 0
        mov r5, r15              ; bit mask = 1
        ldi r6, 6
        add r6, r6, r15          ; r6 = 7 (DR bits 0..6, TMS=0)
byp_loop:
        and r2, r4, r15          ; next TDI bit of 0xA5
        shl r2, r2, r12
        mov r8, r2               ; pins: TCK=0, TMS=0, TDI=bit
        shr r4, r4, r15          ; advance pattern
        call clock_bit
        cmp r3, r0
        jmp byp_one, nz
        jmp byp_done
byp_one:
        or r9, r9, r5            ; record captured TDO bit
byp_done:
        shl r5, r5, r15
        djnz r6, byp_loop
        and r2, r4, r15          ; final pattern bit (bit7 of 0xA5)
        shl r2, r2, r12
        mov r8, r2
        or r8, r8, r12           ; TMS=1 -> Exit1-DR
        call clock_bit
        cmp r3, r0
        jmp byf_one, nz
        jmp byf_done
byf_one:
        or r9, r9, r5
byf_done:
        call exit_to_rti
        push r9                  ; captured byte (expect 0x004A)
        evt 0
        jmp cmd_loop

; ---- unknown / halt --------------------------------------------------------------
do_unk:
        ldi r6, 0xFFFE
        add r6, r6, r15          ; r6 = 0xFFFF (ldi is even-only)
        push r6
        evt 0
        jmp cmd_loop

do_hlt:
        hlt
