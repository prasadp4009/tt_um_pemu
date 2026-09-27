; pe_smoke.asm -- PE block-bench program (tb_pe.v)
; Exercises: PSET/PDIR/PGET, LDI/ADD, PUSH/PULL, EVT, WAIT (level, TB drives pin1), HLT.
; TB preloads RX FIFO with 0xBEEF; expects TX push of 0x2468 and evt_code=3.

        pset 0xA5
        pdir 0xFF
        pget r1              ; r1 = synchronized pins (TB drives pins_in)
        ldi r2, 0x1234
        add r3, r2, r2       ; r3 = 0x2468
        push r3              ; TX FIFO <- 0x2468
        pull r4              ; r4 <- RX FIFO (0xBEEF from TB)
        evt 3
        wait 1, 1, level, 0, r5   ; wait pin1==1, tsel=0 (256-cycle timeout)
        hlt
