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

        pdir 0xFF
        pull r10
        msr r10, TRIG_MODE   ; 1 = EDGE
        pull r10
        msr r10, EDGE_MASK   ; 1 = pin0
        pull r10
        msr r10, EDGE_CFG0   ; 1 = pin0 rising
        pull r10
        msr r10, OBS_CTL     ; 3 = OBS_EN|OBS_ARM
        pull r0
        psetr r0             ; pins = r0[7:0]; pin0 edges trigger observer
        push r0
        pull r0
        psetr r0
        push r0
        pull r0
        psetr r0
        push r0
        hlt
