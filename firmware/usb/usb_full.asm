; =============================================================================
; TEMPO-32 USB 1.1 LOW-SPEED TX+RX merged firmware (IMEM-512 expansion).
;
; Integration of the two proven standalone images, code reused VERBATIM
; except for the dispatch-merge items listed below (no bit-loop, timing,
; CRC, or decode logic was changed anywhere):
;   * usb/usb.asm            TX image, 243 words (init+dispatch 28 /
;                            staging 133 / bit-engine subroutines 82)
;   * usb/usb_rx_experiment.asm  RX experiment, 63 words standalone, of
;                            which the 47-word core (WAIT..EOP tail) is
;                            reused here; its 11 init-idiom words are
;                            replaced by the shared TX init + RX entry
;                            glue, and its 5 state-init words move to
;                            the RX entry.
; Merge deltas (complete list):
;   1. cmd dispatch: the 0x0002 check jumps to do_rx instead of the
;      TX-only unsupported stub (same word count).
;   2. do_tx entry: +2 glue words (pset J / pdir 0x03) restoring the TX
;      pin state in case the RX path ran first (untimed, pre-packet).
;   3. do_rx entry: 7 glue words -- pdir 0x00 (release D+/D- to the
;      peer), ldi r11,0x80, then the RX image's own state init verbatim
;      (xor r5 / ldi r6,8 / ldi r8,6 / xor r10 / ldi r2,2). pmask is
;      already 0x03 from the shared init; r0=0, r15=1, r3=3 are the
;      shared-init constants both paths preserve.
;   4. RX tail: final hlt -> jmp cmd_loop, mirroring the TX handler's
;      tail (push status / evt 0 / return to shared dispatch).
; Host commands: 0x0001 TX (as usb.asm), 0x0002 RX (decode one packet:
; PUSH each de-stuffed byte in stream order, PUSH 0x0000 status, evt 0,
; return to dispatch), 0x00FF HLT, other -> 0xFFFF.
; See usb.asm / usb_rx_experiment.asm headers for the full TX/RX timing
; and protocol documentation, which applies unchanged.
; =============================================================================

; ---- init: R_ONE idiom, pin config -----------------------------------------
        pdir 0x01
        pmask 0xFF
        pset 0x01, d=4
        pget r15                 ; r15 = 1 (preserve forever)
        xor r0, r0, r0           ; r0 = 0
        ldi r3, 2
        add r3, r3, r15          ; r3 = 3 (toggle mask / phase wrap value)
        pmask 0x03               ; pin ops touch only D+/D-
        pset 0x02                ; idle J levels first (D+=0, D-=1)
        pdir 0x03                ; then drive D+, D-

; ---- host command loop -------------------------------------------------------
cmd_loop:
        jmp cmd_have, rxne
        jmp cmd_loop
cmd_have:
        pull r6                  ; cmd word
        cmp r6, r15              ; 0x0001 = TX?
        jmp do_tx, z
        ldi r14, 0x0100
        sub r14, r14, r15        ; r14 = 0xFF
        cmp r6, r14              ; 0x00FF = halt?
        jmp do_hlt, z
        ldi r14, 2
        cmp r6, r14              ; 0x0002 = RX (not implemented)?
        jmp do_rx, z             ; MERGE: 0x0002 = RX (was TX-only stub)
do_unk:                          ; unknown / unsupported command
        ldi r6, 0xFFFE
        add r6, r6, r15          ; 0xFFFF
        push r6
        evt 0
        jmp cmd_loop
do_hlt:
        hlt                      ; falls through to cmd_loop on host GO

; ---- 0x0001 TX ---------------------------------------------------------------
do_tx:
        pset 0x02                ; MERGE GLUE: restore TX pin state (J levels
        pdir 0x03                ;   + drive D+/D-) in case RX ran before
do_tx_poll:
        jmp tx_nh, rxne          ; RXNE-guard the N word
        jmp do_tx_poll
tx_nh:
        pull r1                  ; r1 = N (payload bytes left, 1..8)
        mov r13, r1
        add r13, r13, r15        ; r13 = N+1 (djnz pull counter)
        ldi r10, 8               ; pack shift amount (phase reused later)
; pull + pack payload bytes, 2 per register, low byte first
pb0:    djnz r13, pb0_pull
        jmp pk_done
pb0_pull:
        pull r4
        mov r2, r4               ; pack0 low = byte0
        jmp pb1
pb1:    djnz r13, pb1_pull
        jmp pk_done
pb1_pull:
        pull r4
        shl r4, r4, r10
        or r2, r2, r4            ; pack0 high = byte1
        jmp pb2
pb2:    djnz r13, pb2_pull
        jmp pk_done
pb2_pull:
        pull r4
        mov r12, r4              ; pack1 low = byte2
        jmp pb3
pb3:    djnz r13, pb3_pull
        jmp pk_done
pb3_pull:
        pull r4
        shl r4, r4, r10
        or r12, r12, r4          ; pack1 high = byte3
        jmp pb4
pb4:    djnz r13, pb4_pull
        jmp pk_done
pb4_pull:
        pull r4
        mov r14, r4              ; pack2 low = byte4
        jmp pb5
pb5:    djnz r13, pb5_pull
        jmp pk_done
pb5_pull:
        pull r4
        shl r4, r4, r10
        or r14, r14, r4          ; pack2 high = byte5
        jmp pb6
pb6:    djnz r13, pb6_pull
        jmp pk_done
pb6_pull:
        pull r4
        mov r11, r4              ; pack3 low = byte6
        jmp pb7
pb7:    djnz r13, pb7_pull
        jmp pk_done
pb7_pull:
        pull r4
        shl r4, r4, r10
        or r11, r11, r4          ; pack3 high = byte7
pk_done:
; ---- packet 1: SETUP token ---------------------------------------------------
        call pkt_pre
        ldi r4, 0x2D80           ; SYNC + PID SETUP, LSB-first stream
        ldi r5, 16
        call lsb_loop
        ldi r4, 0xD004           ; ADDR/ENDP/CRC5 stream = 0xD005 (timed
        add r4, r4, r15          ;   setup block: exactly 7 cycles)
        ldi r5, 16
        sleep 3
        call lsb_loop
        call eop_from_lsb
        sleep 300                ; ~10 bit times of J idle between packets
; ---- packet 2: DATA0 ----------------------------------------------------------
        call pkt_pre
        ldi r4, 0xC380           ; SYNC + PID DATA0, LSB-first stream
        ldi r5, 16
        call lsb_loop
        ldi r6, 0xFFFE           ; payload setup (exactly 7 cycles):
        add r6, r6, r15          ;   crc = 0xFFFF
        ldi r7, 0xA000
        add r7, r7, r15          ;   poly = 0xA001 (reflected 0x8005)
        mov r4, r2               ;   byte0 = pack0 low
        ldi r5, 8
        sleep 0
        call lsb_loop            ; payload byte0
next0:  djnz r1, load1
        jmp crc_path
load1:  ldi r13, 8
        mov r4, r2
        shr r4, r4, r13          ; byte1 = pack0 high
        ldi r5, 8
        sleep 1
        call lsb_loop
next1:  djnz r1, load2
        jmp crc_path
load2:  mov r4, r12              ; byte2 = pack1 low
        ldi r5, 8
        sleep 3
        call lsb_loop
next2:  djnz r1, load3
        jmp crc_path
load3:  ldi r13, 8
        mov r4, r12
        shr r4, r4, r13          ; byte3 = pack1 high
        ldi r5, 8
        sleep 1
        call lsb_loop
next3:  djnz r1, load4
        jmp crc_path
load4:  mov r4, r14              ; byte4 = pack2 low
        ldi r5, 8
        sleep 3
        call lsb_loop
next4:  djnz r1, load5
        jmp crc_path
load5:  ldi r13, 8
        mov r4, r14
        shr r4, r4, r13          ; byte5 = pack2 high
        ldi r5, 8
        sleep 1
        call lsb_loop
next5:  djnz r1, load6
        jmp crc_path
load6:  mov r4, r11              ; byte6 = pack3 low
        ldi r5, 8
        sleep 3
        call lsb_loop
next6:  djnz r1, load7
        jmp crc_path
load7:  ldi r13, 8
        mov r4, r11
        shr r4, r4, r13          ; byte7 = pack3 high
        ldi r5, 8
        sleep 1
        call lsb_loop
next7:  sleep 0                  ; byte7 exit has no djnz: pad 1c so the
        jmp crc_path             ;   CRC transition budget stays 28c
crc_path:                        ; CRC16 tx value = ~rc, emitted LSB-first
        sub r4, r0, r15          ;   (= ~crc MSB-first on the wire)
        xor r4, r4, r6           ; r4 = complemented reflected CRC16
        ldi r5, 16
        sleep 1                  ; transition budget: 5+1+1+5+1+15 = 28c
        call lsb_loop
        call eop_from_lsb
        push r0                  ; status 0x0000 = OK
        evt 0
        jmp cmd_loop

; ---- packet preamble (untimed): reset per-packet bit state -------------------
pkt_pre:
        ldi r9, 2                ; pin state = J
        ldi r8, 6                ; ones countdown = 6
        xor r10, r10, r10        ; dither phase = 0
        xor r7, r7, r7           ; poly = 0 (CRC passes through unchanged)
        xor r6, r6, r6           ; crc = 0 (stays 0 with poly=0)
        ldi r4, 0x80             ; SYNC (overwritten by callers)
        ldi r5, 8
        ret

; ---- shared stuff-bit preparation (call; 12 cycles body+ret) -----------------
; Toggles the pin state (stuff bit is a data 0) and resets the ones count.
stuff_pre:
        xor r9, r9, r3
        ldi r8, 6
        sleep 8
        ret

; ---- LSB-first bit loop (subroutine) -----------------------------------------
; Emits r5 bits from r4 (LSB first). Cell = 33c, every 3rd cell 34c.
lsb_loop:
lsb_head:
        cmp r8, r0               ; stuff bit needed before this bit?
        jmp lsb_core, nz
        call stuff_pre
        psetr r9, d=4            ; stuff cell boundary
        add r10, r10, r15        ; stuff tail (13c): dither + sleep + jmp
        cmp r10, r3
        jmp lsb_snod, nz
        xor r10, r10, r10
lsb_snod:
        sleep 8
        jmp lsb_head
lsb_core:
        and r13, r4, r15         ; data bit = shifter LSB
        shr r4, r4, r15
        cmp r13, r15             ; ones/NRZI segment (5c executed)
        jmp lsb_bit0, nz
        sub r8, r8, r15          ; bit=1: ones countdown--
        mov r0, r0
        jmp lsb_crc
lsb_bit0:
        ldi r8, 6                ; bit=0: ones reset
        xor r9, r9, r3           ;        NRZI transition
        mov r0, r0
lsb_crc:                         ; CRC step (6c executed), reflected form:
        shr r6, r6, r15          ; rc >>= 1; C = old rc LSB = true-crc msb;
                                 ; fb = C XOR data bit (same branch tree)
        jmp lsb_cset, c
        cmp r13, r15
        jmp lsb_cskip, nz        ; C=0,bit=0 -> fb=0
        xor r6, r6, r7           ; C=0,bit=1 -> fb=1
        jmp lsb_emit
lsb_cset:
        cmp r13, r15
        jmp lsb_cskip, z         ; C=1,bit=1 -> fb=0
        xor r6, r6, r7           ; C=1,bit=0 -> fb=1
        jmp lsb_emit
lsb_cskip:
        mov r0, r0
        mov r0, r0
lsb_emit:
        psetr r9, d=4            ; *** cell boundary ***
        add r10, r10, r15        ; tail: dither (3c, +1c on wrap)
        cmp r10, r3
        jmp lsb_nod, nz
        xor r10, r10, r10
lsb_nod:
        djnz r5, lsb_pad
        ret
lsb_pad:
        sleep 7                  ; continuing pad (8c) + jmp = 9c
        jmp lsb_head

; ---- EOP wrappers -------------------------------------------------------------
; Entered (via call) right after a packet's last field loop returns. If the
; CRC ended on six 1s, emit the mandatory stuff bit first (fake 0-bit
; through the emitting loop's core), then the shared EOP sequence.
eop_from_lsb:
        cmp r8, r0
        jmp eop_lsb_go, nz
        xor r4, r4, r4           ; fake stuff bit: shifter = 0, count = 1
        mov r5, r15
        sleep 4
        call lsb_core
        sleep 1                  ; return-site pad
eop_lsb_go:
        sleep 14
        jmp eop_setup
; Shared EOP: SE0 x2 cells, J x1 cell (33c/34c grid), J left driven.
eop_setup:                       ; (5 cycles: xor, ldi, mov, sleep1)
        xor r9, r9, r9           ; pin state = SE0 (doubles as EOP stage:
        ldi r5, 2                ;   2 SE0 cells; stage test is r9==0)
        mov r0, r0
        sleep 1
eop_loop:
        psetr r9, d=6            ; *** EOP cell boundary ***
        add r10, r10, r15
        cmp r10, r3
        jmp eop_nod, nz
        xor r10, r10, r10
eop_nod:
        sleep 15                 ; 16c
        djnz r5, eop_pad
        cmp r9, r0               ; SE0 phase done? (r9==0 during SE0)
        jmp eop_done, nz
        mov r0, r0               ; J phase: state=J, 1 cell
        ldi r9, 2
        mov r5, r15
        jmp eop_loop
eop_done:
        ret
eop_pad:
        sleep 4
        jmp eop_loop

; ---- 0x0002 RX (entry glue + verbatim experiment core) -----------------------
do_rx:
        pdir 0x00                ; MERGE GLUE: D+/D- are inputs (peer drives)
        ldi r11, 0x80            ; MERGE GLUE: byte-assembly MSB mask
        xor r5, r5, r5           ; RX state init (verbatim from experiment)
        ldi r6, 8
        ldi r8, 6
        xor r10, r10, r10
        ldi r2, 2
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
        jmp cmd_loop   ; MERGE: return to shared dispatch (standalone ended in hlt)
