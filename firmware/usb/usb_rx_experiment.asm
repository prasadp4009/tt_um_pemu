; =============================================================================
; TEMPO-32 USB LS RECEIVE experiment (STANDALONE image, NOT the product
; firmware). Purpose: measure whether a PGET sample-at-cell-center loop can
; hold the 33.333-cycle LS grid: NRZI decode + de-stuff + byte assembly in
; the per-bit loop. See stretch_results/usb.md for the verdict/accounting.
;
; Behavior: wait for a packet on D+/D- (pins 0/1, both inputs), decode it,
; PUSH each de-stuffed byte (stream order, bits assembled LSB-first), PUSH
; 0x0000 status (or 0xFFFE if a stuff-bit/EOP error is seen), evt 0, HLT.
; Per-bit loop cost: 33 cycles (34 on dither wrap) -- see header in the
; report; the spacing SLEEP at the loop top is the calibration knob.
; =============================================================================
        pdir 0x04
        pmask 0xFF
        pset 0x04, d=4
        pget r15                 ; bit2 set (peer may also drive D+/D-:
        ldi r3, 2                ;   isolate bit2 -> r15 = 1)
        shr r15, r15, r3
        xor r0, r0, r0           ; r0 = 0
        add r3, r3, r15          ; r3 = 3
        ldi r11, 0x80            ; byte-assembly MSB mask
        pmask 0x03
        pdir 0x00                ; D+/D- are inputs (host/peer drives)
        xor r5, r5, r5           ; byte accumulator
        ldi r6, 8                ; bits per byte
        ldi r8, 6                ; ones countdown (stuff after 6 ones)
        xor r10, r10, r10        ; dither phase
        ldi r2, 2                ; prev sample = J (idle)
; wait for SYNC start: D+ rising edge (J -> K)
        wait 0, 1, rising, 1, r7
        sleep 8          ; align first sample to SYNC cell-0 center
rx_bit:
        sleep 4                  ; spacing filler (loop total = 33c)
        pget r4                  ; *** sample (synchronized pins) ***
        cmp r4, r0               ; SE0? (both D+/D- low) -> EOP
        jmp rx_not_eop, nz
        jmp rx_eop
rx_not_eop:
        xor r13, r4, r2          ; r13 = 0 if same state (data 1), 3 if
                                 ; transition (data 0)
        mov r2, r4               ; prev sample = current
        cmp r8, r0               ; stuff bit due? (six previous 1s)
        jmp rx_nostuff, nz
        ldi r8, 6                ; stuff bit: drop it, reset ones count
        sleep 12                 ; (pad to the full store-path length)
        jmp rx_tail
rx_nostuff:
        cmp r13, r0              ; ones update (5c executed)
        jmp rx_ob0, nz           ; transition -> data 0 -> ones reset
        sub r8, r8, r15          ; data 1: ones countdown--
        mov r0, r0
        jmp rx_store
rx_ob0:
        ldi r8, 6
        mov r0, r0
        mov r0, r0
rx_store:                        ; shift data bit into byte (LSB-first)
        shr r5, r5, r15
        cmp r13, r0              ; data 1 (no transition)?
        jmp rx_shd0, nz          ; data 0: +1c pad (matches the or path)
        or r5, r5, r11           ; set MSB (first-received bit ends at LSB
        jmp rx_shd               ;   after 8 shifts; bit1 path = or+jmp,
rx_shd0:
        mov r0, r0
        mov r0, r0
rx_shd:                          ;   after 8 shifts)
        djnz r6, rx_tailpad
        push r5                  ; byte complete
        xor r5, r5, r5
        ldi r6, 8
        jmp rx_tail
rx_tailpad:
        mov r0, r0
        mov r0, r0
        mov r0, r0
        mov r0, r0
rx_tail:                         ; dither tail: +1c on phase wrap
        add r10, r10, r15
        cmp r10, r3
        jmp rx_nowrap, nz
        xor r10, r10, r10
rx_nowrap:
        sleep 1
        jmp rx_bit
rx_eop:
        push r0                  ; status 0 = OK
        evt 0
        hlt
