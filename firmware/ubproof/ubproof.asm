; =============================================================================
; Tarang-32 ubproof -- upper-bank EXECUTION proof (IMEM-512 expansion, Phase 6)
;
; Purpose: prove on hardware that code fetched from IMEM addresses >= 256
; actually EXECUTES (not just loads/verifies). The GENERIC host loader
; (fpga/emu_tt_loader.v) only ever sends one RX FIFO word after GO: the
; HALT command 0x00FF. The only code that can respond to it lives at
; .org 280, so a PASS (PE_HALTED after the command, magic words pushed)
; is reachable only by executing the upper-bank routine.
;
; Layout:
;   word 0      : jmp main            (9-bit target 280, crosses 256)
;   words 1..279: zero padding (assembler .org gap fill)
;   .org 280    : main routine (19 words, 280..298; image = 299 words)
;
; Contract (GENERIC loader):
;   main polls the RX FIFO (RXNE-guarded, same idiom as usb.asm dispatch),
;   waits for the host HALT command word 0x00FF, then PUSHes two magic
;   words to the TX FIFO -- 0xBEEF then 0x0512 -- and executes HLT.
;   Evidence on the host side: PE reaches HALTED only via this routine;
;   the two pushes clear TX_EMPTY in the halted RD_STATUS byte
;   (st_halt = 0x40 instead of the usual 0x50), which is folded into the
;   loader signature and visible in dbg0.
;
; Register use: r15 = 1 (R_ONE idiom, preserved), r0 = 0,
;               r6 = pulled command word, r14 = 0x00FF compare constant,
;               r7 = magic word scratch.
; =============================================================================

        jmp main

        .org 280
main:
; ---- init: R_ONE idiom (same as usb.asm) -----------------------------------
        pdir 0x01
        pmask 0xFF
        pset 0x01, d=4
        pget r15                 ; r15 = 1 (preserve forever)
        xor r0, r0, r0           ; r0 = 0

; ---- poll RX FIFO for the HALT command 0x00FF -------------------------------
poll:
        jmp have, rxne
        jmp poll
have:
        pull r6                  ; command word
        ldi r14, 0x0100
        sub r14, r14, r15        ; r14 = 0x00FF (LDI imm16 must be even)
        cmp r6, r14
        jmp is_halt, z
        jmp poll                 ; ignore any non-HALT word, keep polling
is_halt:
        ldi r7, 0xBEF0
        sub r7, r7, r15          ; r7 = 0xBEEF (LDI imm16 must be even)
        push r7                  ; magic word 1: 0xBEEF
        ldi r7, 0x0512
        push r7                  ; magic word 2: 0x0512
        hlt
