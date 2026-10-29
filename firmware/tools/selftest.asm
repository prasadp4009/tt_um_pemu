; tools self-test: exercises every opcode family
        pdir 0xFF                ; drive all pins
        pmask 0xFF
        pset 0xA5               ; pins <- A5 (effect end of cycle 0)
        pget r1                 ; sample (sync: sees pins 2 cycles later)
        sleep 3                 ; let sync settle: exactly 4 cycles
        pget r2                 ; r2 should be 0xA5 now
        ldi r3, 0x1234
        mov r4, r3
        add r5, r3, r4          ; 0x2468
        sub r6, r4, r3          ; 0
        and r7, r3, r4
        or  r8, r3, r4
        xor r9, r3, r4
        shl r10, r3, r4         ; shift by r4[3:0]=4
        shr r11, r3, r4
        cmp r3, r4              ; equal -> Z=1
        jmp jz_taken, z
        ldi r12, 0xBEEE         ; skipped
jz_taken:
        ldi r13, 6
djnz_loop:
        djnz r13, djnz_loop     ; 5 iterations
        call subr
        jmp after_sub
subr:
        ldi r14, 0xCAFE
        ret
after_sub:
        push r3
        push r4
        pull r0                 ; r0 = 0x1234
        pull r1                 ; r1 = 0x1234
        cap r2                  ; r2 = ts[15:0]
        mrs r3, CYCLES_LO
        mrs r4, OBS_PTR         ; 0
        ; materialize 1: LDI/ALU are closed over even values (LDI bit0 reserved),
        ; so boot firmware derives R_ONE from the pin unit (deterministic)
        pset 0x01, d=4          ; drive pin0 high; d=4 settles the 2-FF sync
        pget r5                 ; r5 = 0x01
        msr r5, TRIG_MODE       ; EDGE mode, disarms
        mrs r6, TRIG_MODE       ; 1
        evt 3
        hlt
