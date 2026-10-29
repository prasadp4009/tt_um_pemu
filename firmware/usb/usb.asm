; =============================================================================
; TEMPO-32 USB 1.1 LOW-SPEED device-side TRANSMIT firmware
; 50 MHz core -> 20 ns/cycle. LS bit = 666.67 ns = 33.333 cycles (fractional).
; DITHER: per-bit loop is fully cycle-counted; cells are 33,33,34 repeating
; (phase counter adds exactly +1 cycle on every 3rd cell) -> average exactly
; 33.333 cycles/bit, max edge deviation from ideal grid <= 1 cycle (20 ns).
;
; PIN MAP: pin0 = D+, pin1 = D-, both push-pull outputs (pmask/pdir = 0x03).
;   J (LS idle) = D+=0,D-=1 -> pins byte 0x02 (1.5k pull-up is on D- on real
;   hardware, identifying a low-speed device). K = 0x01. SE0 = 0x00.
; NRZI: data 0 = transition, data 1 = no transition. Bit stuffing: a 0
; (transition) is inserted after six consecutive 1s, including after the CRC
; field. Bytes/fields are transmitted LSB-first, except CRCs, which are
; transmitted MSB-first of the complemented remainder (USB 1.1 spec 8.3.5).
; CRC algorithm (spec): MSB-first LFSR, init all-ones; per data bit in
; transmission order: fb = msb(crc) XOR bit; crc <<= 1; if fb: crc ^= poly
; (CRC5 poly low = 0x05, residue check 01100; CRC16 poly low = 0x8005,
; residue check 1000000000001101). The firmware maintains the CRC16 in
; REFLECTED form (rc = bit-reverse of the spec state, poly 0xA001, update
; rc >>= 1 with fb = rc-LSB XOR bit -- proven equivalent, and it makes the
; transmit value simply ~rc emitted LSB-first, so ONE bit loop serves all
; fields). The golden test's INDEPENDENT decoder uses the spec (MSB-first)
; form and the residue checks, so the two implementations cross-verify.
;
; HOST COMMANDS (16-bit words via RX FIFO; responses via TX FIFO):
;   0x0001 TX : PULL N (payload byte count, 1..8), then PULL N payload
;               byte-words. Transmits, back to back (~10 bit-time J gap):
;               (1) SETUP token: SYNC, PID SETUP=0x2D, ADDR=0x05, ENDP=0x0,
;                   CRC5 (constant field bits, precomputed), EOP.
;               (2) DATA0: SYNC, PID DATA0=0xC3, N payload bytes, CRC16, EOP.
;               Then PUSH 0x0000 status, evt 0, loop.
;   0x0002 RX : NOT IMPLEMENTED in this image (see stretch_results/usb.md
;               for the accounting). Falls through to unknown -> 0xFFFF.
;   0x00FF    : HLT.
;   other     : PUSH 0xFFFF, evt 0, loop.
; Payload words are pulled WITHOUT per-word RXNE waits (the host preloads
; the whole frame, exactly as the co-sim recorder does); the command word
; and the N word ARE RXNE-guarded.
;
; TIMING ARCHITECTURE (all counts verified against the golden model):
;   Bit loop (head=15c): stuff-check 2 + bit extract 2 + ones/NRZI 5 +
;     CRC step 6. psetr d=4 (5c). Tail (continuing) = 13c: dither 3 +
;     djnz 1 + pad sleep7+jmp 9. Cell = 5+13+15 = 33c (+1 on phase wrap).
;   Field transitions: loop exit path (dither3+djnz1+ret1 = 5c) + caller
;     block (setup+call, exactly 8c) + next head = the same 28c
;     between-psetr budget as a continuing bit. The CRC16 transition pads
;     +2c (its setup is shorter than a byte setup).
;   Stuff bits: shared stuff_pre subroutine (toggle + ones reset, 12c);
;     each loop has its own stuff psetr + 13c stuff tail.
;   EOP: SE0 for 2 cells + J for 1 cell on the same dithered grid
;     (psetr d=6 + dither + sleep15 + loop control = 33c/cell), then J is
;     left driven (idle). A stuff bit is emitted before EOP if the CRC
;     ended on six consecutive 1s (spec requirement), via a fake 0-bit
;     through the emitting loop's core.
;
; TOKEN FIELD CONSTANT: SYNC(0x80) + PID(0x2D) are emitted as one 16-bit
; LSB-first stream 0x2D80. ADDR/ENDP/CRC5 are the second 16-bit stream:
; bits in tx order = A0..A6 (1010000), E0..E3 (0000), CRC tx MSB-first
; (01011; CRC5 state over addr=5,endp=0 is 10100, complement 01011) ->
; packed LSB-first = 0xD005.
; DATA SYNC+PID stream = 0xC380 (SYNC 0x80 low byte, DATA0 0xC3 high byte).
;
; Register use: r0=0, r1=payload bytes left, r2=pack0 (payload bytes 0,1),
; r3=3 (pin toggle mask AND phase compare constant), r4=bit shifter,
; r5=bit count, r6=CRC state, r7=CRC poly (0 or 0x8005), r8=ones countdown
; to stuff (6..0), r9=pin state byte (0x01=K, 0x02=J), r10=dither phase,
; r11=pack3 (bytes 6,7), r12=pack1 (bytes 2,3), r13=scratch / pull counter,
; r14=pack2 (bytes 4,5) / cmd compare scratch, r15=1 (R_ONE, preserved).
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
        jmp do_unk, z            ; RX stub: report unsupported (0xFFFF)
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
        jmp tx_nh, rxne          ; RXNE-guard the N word
        jmp do_tx
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
