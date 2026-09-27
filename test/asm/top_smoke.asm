; top_smoke.asm -- top-level integration program (tb_top.v)
; Echoes 3 RX words to pins + TX, configures the observer (EDGE, pin0
; rising), then halts.
;
; NOTE: LDI immediates must be even (imm16 bit0 reserved), so odd config
; values (TRIG_MODE=1, OBS_CTL=3) are pulled from the RX FIFO instead --
; the TB sends 4 config words first: 0x0001,0x0001,0x0001,0x0003.
; Then 3 echo words: 0x0001,0x0002,0x0003. pin0 rises on echo words 1 and
; 3 -> 2 trace entries (pins 0x01, 0x03).
; TB checks: pin echo, TX echo, RD_TRACE entries, VERIFY_IMEM, HALT_REQ/GO.
;
; WR_RXFIFO is RUN-only per ISA (PROG -> NACK_ERR), so the TB sends GO
; first, then WR_RXFIFO. Each PULL spins on RXNE until the TB's data
; arrives (no race between PE start and FIFO fill).

        pdir 0xFF
wr1:    jmp wr1go, rxne
        jmp wr1, al
wr1go:  pull r10
        msr r10, TRIG_MODE   ; 1 = EDGE
wr2:    jmp wr2go, rxne
        jmp wr2, al
wr2go:  pull r10
        msr r10, EDGE_MASK   ; 1 = pin0
wr3:    jmp wr3go, rxne
        jmp wr3, al
wr3go:  pull r10
        msr r10, EDGE_CFG0   ; 1 = pin0 rising
wr4:    jmp wr4go, rxne
        jmp wr4, al
wr4go:  pull r10
        msr r10, OBS_CTL     ; 3 = OBS_EN|OBS_ARM
wr5:    jmp wr5go, rxne
        jmp wr5, al
wr5go:  pull r0
        psetr r0             ; pins = r0[7:0]; pin0 edges trigger observer
        push r0
wr6:    jmp wr6go, rxne
        jmp wr6, al
wr6go:  pull r0
        psetr r0
        push r0
wr7:    jmp wr7go, rxne
        jmp wr7, al
wr7go:  pull r0
        psetr r0
        push r0
        hlt
