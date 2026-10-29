; ======================================================================
; TEMPO-32 stretch firmware -- 1-Wire master on pin7 (Worker D)
; ----------------------------------------------------------------------
; 1-Wire master, 50 MHz core (1 cycle = 20 ns; 1 us = 50 cycles).
; Pin7 = open-drain + pull-up (pmode bits[15:14] = {1,1}); PSET bit7
; 0 = drive low, 1 = release. All other pins Hi-Z (pdir 0x80).
;
; HOST COMMANDS (RX FIFO, 16-bit words):
;   0x0001         reset + presence detect
;                    -> TX 0x0001 : device present            (EVT 0)
;                    -> TX 0x0000 : no device / bus fault     (EVT 1)
;   0x0002 <byte>  write byte, LSB-first
;                    -> TX 0x0000 : ack                       (EVT 0)
;   0x0003         read byte, LSB-first
;                    -> TX <byte>                             (EVT 0)
;   0x0004         DS18B20 demo: reset -> SKIP ROM (0xCC) ->
;                    READ SCRATCHPAD (0xBE) -> read 9 bytes
;                    -> TX 9 words (scratchpad bytes)         (EVT 0)
;                    -> TX 0x0000 : no device                 (EVT 1)
;   0x00FF         HLT
;   other          -> TX 0xFFFF                              (EVT 1)
;
; OBSERVER DEBUG RECIPE (host-side; firmware never touches the Observer --
; Q4: PE cannot read trace SRAM, host reads it via RD_TRACE):
;   capture every 1-Wire edge on pin7 (slot + presence activity):
;     WR_CFG EDGE_MASK = 0x80   ; pin7 armed
;     WR_CFG EDGE_CFG1 = 0xC0   ; pin7 = either (bits[7:6] = 11)
;     WR_CFG TRIG_MODE = 0x01   ; EDGE (any write disarms)
;     WR_CFG OBS_CTL   = 0x01   ; OBS_EN -- set LAST
;   ... run transaction ...
;   RD_TRACE -> {ts,pins} entries; OBS_PTR = committed entry count.
;
; CYCLE BUDGET -- theory vs measured in sim (20 ns/cycle):
;   op                       theory = measured       spec window
;   reset low (master)       24001 cyc = 480.02 us   >= 480 us (tRSTL)
;   presence fall after rel  1500 cyc = 30.00 us     15-60 us  (tPDH)
;   presence low (slave)     6000 cyc = 120.0 us     60-240 us (tPDL)
;   write-1 low              300 cyc = 6.00 us       1-15 us   (tLOW1)
;   write-0 low              3050 cyc = 61.00 us     60-120 us (tLOW0)
;   read slot low (master)   300 cyc = 6.00 us       1-15 us
;   read sample point        F+751 cyc = 15.02 us    slave valid by 15 us
;                            (PGET at F+753, 2-cyc sync)
;   slot period              3500 cyc = 70.00 us     60-120 us (tSLOT)
;   recovery after write-0   450 cyc = 9.0 us        >= 1 us   (tREC)
;   (measured in tests/out/onewire.log; theory == measured to the
;   cycle -- the slot math in the code comments is exact)
;
; SIM TOOL NOTE (2026-09-26; RESOLVED 2026-09-27, commit 86cbacb):
; tools/sim.py WAIT edge modes (rising/falling/either) never fired --
; wait_prev was latched AFTER the sync tick instead of before, so pv==v
; on every check (verified: real falling edge at cyc 500 -> TIMEOUT 4096).
; The tool owner fixed the latch order (check-then-latch) and made WAIT
; T8-exact; a selftest regression pins it. This firmware KEEPS its
; level-mode WAIT pairs -- wait-for-low (presence start) then chained
; wait-for-high (presence end) -- which are semantically identical here
; (a level cannot be missed the way an edge can) and still report
; elapsed cycles (the measurement-as-ISA thesis). Flipping the mode
; operand level->falling / level->rising at the three WAIT sites restores
; the intended edge semantics on RTL; no other change needed.
; The chained tsel=1 waits for the presence rising level are T17-
; compliant (never tsel 2/3); up to 4 x 4096 = 16384 cycles covers the
; full 60-240 us presence window.
;
; WORD COUNT: 132 (target <= 150, hard limit 256).
; ROM SEARCH: DEFERRED -- a search-ROM routine needs ~40+ words
; (bit-conflict loop, 64-bit ROM buffer, CRC8) which would break the
; 150-word target; SKIP ROM covers the single-drop demo case.
;
; REGISTER USE: r15 = 1 (R_ONE, preserved). r0-r4 scratch; r5 free;
; r6 = rise-chain attempts (ow_reset) / demo byte counter (do_demo,
; sequential -- never live across a call); r7 = command word.
; ow_reset clobbers r0,r4,r6; ow_write_byte clobbers r1,r2;
; ow_read_byte clobbers r0,r1,r2,r3,r4.
; ======================================================================

; ---------------- init ----------------
        pdir 0xFF
        pmask 0xFF
        pset 0x01, d=4        ; R_ONE: pin0 high; 2-FF settle
        pget r15              ; r15 = 1 (preserve forever)
        ldi r0, 0xC000        ; pin7 = {open_drain=1, pull_up=1}
        pmode r0
        pmask 0x80            ; PSET affects pin7 only
        pdir 0x80             ; drive pin7 only; pins 0-6 Hi-Z
        pset 0x80             ; release line -> idle high

; ---------------- host command loop ----------------
cmd_loop:
        jmp cmd_have, rxne    ; spin until host sends a command
        jmp cmd_loop, al
cmd_have:
        pull r7               ; r7 = command word
        ldi r0, 0
        add r0, r0, r15       ; r0 = 1
        cmp r7, r0
        jmp do_reset, z       ; 0x0001 reset+presence
        add r0, r0, r15       ; r0 = 2
        cmp r7, r0
        jmp do_write, z       ; 0x0002 write byte
        add r0, r0, r15       ; r0 = 3
        cmp r7, r0
        jmp do_read, z        ; 0x0003 read byte
        add r0, r0, r15       ; r0 = 4
        cmp r7, r0
        jmp do_demo, z        ; 0x0004 DS18B20 demo
        ldi r0, 0x00FE
        add r0, r0, r15       ; r0 = 0x00FF
        cmp r7, r0
        jmp do_hlt, z         ; 0x00FF halt
        ldi r0, 0xFFFE        ; unknown command
        add r0, r0, r15       ; r0 = 0xFFFF
        push r0
        evt 1
        jmp cmd_loop, al
do_hlt:
        hlt

; ---------------- 0x0001 : reset + presence ----------------
do_reset:
        call ow_reset         ; r0 = 1 present / 0 absent-or-fault
        cmp r0, r15
        jmp dr_yes, z
        ldi r0, 0
        push r0               ; 0x0000 = no device
        evt 1
        jmp cmd_loop, al
dr_yes:
        push r15              ; 0x0001 = present
        evt 0
        jmp cmd_loop, al

; ow_reset: 1-Wire reset + presence detect.
;   Returns r0 = 1 (device present) / 0 (no device or stuck bus).
;   Clobbers r0, r4, r6. Preserves r15.
ow_reset:
        pset 0x00             ; drive low
        sleep 7999            ; \
        sleep 7999            ;  } 24000 cycles
        sleep 7999            ; /
        pset 0x80             ; release -> low 24001 cyc = 480.02 us
        wait 7, 1, level, 0, r4  ; confirm line high (absorbs 2-cyc sync)
        wait 7, 0, level, 1, r4  ; presence falling, 4096-cycle window
        jmp or_nopres, tmo    ; TIMEOUT -> no device
        ldi r6, 4             ; up to 4 chained tsel=1 windows (T17)
or_rise:
        mrs r0, STATUS
        msr r0, STATUS        ; W1C: clear TIMEOUT sticky
        wait 7, 1, level, 1, r4  ; presence rising, 4096 cycles
        jmp or_rise_nxt, tmo
        jmp or_present, al
or_rise_nxt:
        djnz r6, or_rise
        jmp or_nopres, al     ; stuck low -> bus fault = no device
or_present:
        sleep 8191            ; \
        sleep 8191            ;  } pad toward ~480 us window (16384 cyc)
        ldi r0, 0
        add r0, r0, r15       ; r0 = 1
        ret
or_nopres:
        ldi r0, 0             ; r0 = 0
        ret

; ---------------- 0x0002 : write byte ----------------
; RACE FIX 2026-09-27: wait for the data word -- the old back-to-back
; PULL hit an empty FIFO when the host word arrived ~2000 cycles later,
; so a 0x0002 command wrote a phantom 0x00 byte instead of the real data.
do_write:
        jmp dw_have, rxne
        jmp do_write
dw_have:
        pull r2               ; data byte (low 8 bits)
        call ow_write_byte
        ldi r0, 0
        push r0               ; ack 0x0000
        evt 0
        jmp cmd_loop, al

; ow_write_byte: write r2 LSB-first, 70 us slots.
;   write-1: low 300 cyc (6.0 us); write-0: low 3050 cyc (61.0 us).
;   Clobbers r1, r2. Preserves r15.
ow_write_byte:
        ldi r1, 8
ow_wbit:
        shr r2, r2, r15       ; C = next bit (LSB first), r2 >>= 1
        jmp ow_w1, c
        pset 0x00             ; write-0
        sleep 3048            ; 3049 cyc
        pset 0x80             ; release -> low 3050 cyc
        sleep 444             ; 445 cyc -> slot 3500 cyc
        jmp ow_wnxt, al
ow_w1:
        pset 0x00             ; write-1
        sleep 298             ; 299 cyc
        pset 0x80             ; release -> low 300 cyc
        sleep 3195            ; 3196 cyc -> slot 3500 cyc
ow_wnxt:
        djnz r1, ow_wbit
        ret

; ---------------- 0x0003 : read byte ----------------
do_read:
        call ow_read_byte
        push r2
        evt 0
        jmp cmd_loop, al

; ow_read_byte: read byte LSB-first into r2, 70 us slots.
;   Master low 300 cyc, release, PGET samples at F+753 (sync-stale ->
;   true wire F+751 = 15.02 us after falling edge).
;   Clobbers r0, r1, r2, r3, r4. Preserves r15.
ow_read_byte:
        ldi r1, 8
        ldi r2, 0
        ldi r4, 0x0080        ; bit-insert mask
        ldi r0, 6
        add r0, r0, r15       ; r0 = 7 (pin7 extract shift)
ow_rbit:
        pset 0x00             ; drive low
        sleep 298             ; 299 cyc -> low 300 cyc = 6.0 us
        pset 0x80             ; release
        sleep 451             ; 452 cyc
        pget r3               ; sample (2-cyc stale)
        shr r3, r3, r0        ; r3 = pin7 sample (0/1)
        shr r2, r2, r15       ; r2 >>= 1
        cmp r3, r15
        jmp ow_rb0, nz
        or r2, r2, r4         ; insert 1 at bit7
        jmp ow_rbnxt, al
ow_rb0:
        sleep 1               ; 2 cyc: balance or+jmp path
ow_rbnxt:
        sleep 2738            ; 2739 cyc -> slot 3500 cyc = 70.0 us
        djnz r1, ow_rbit
        ret

; ---------------- 0x0004 : DS18B20 demo ----------------
do_demo:
        call ow_reset
        cmp r0, r15
        jmp dd_yes, z
        ldi r0, 0
        push r0               ; 0x0000 = no device
        evt 1
        jmp cmd_loop, al
dd_yes:
        ldi r2, 0xCC          ; SKIP ROM
        call ow_write_byte
        ldi r2, 0xBE          ; READ SCRATCHPAD
        call ow_write_byte
        ldi r6, 8
        add r6, r6, r15       ; r6 = 9 (ow_read_byte clobbers r1!)
dd_rd:
        call ow_read_byte
        push r2
        djnz r6, dd_rd
        evt 0
        jmp cmd_loop, al
