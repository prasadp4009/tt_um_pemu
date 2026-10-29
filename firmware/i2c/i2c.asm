; ============================================================================
; Tarang-32 firmware: I2C master, 100 kHz (bit = 500 cycles @50 MHz)
; Worker C — Jane Street Protocol Emulator ASIC competition, firmware phase
; ============================================================================
; HOST COMMAND / RESPONSE WORDS (16-bit words via RX/TX FIFOs)
;   cmd 0x0001 (write): PULL addr_word (7-bit addr in [7:1], R/W#=0 in [0]),
;                       PULL N, PULL N data words.
;                       -> transaction; all ACKed: PUSH 0x0000, EVT 0.
;                       -> NACK on byte idx: PUSH 0xFFE0|idx, STOP, EVT 1.
;   cmd 0x0002 (read):  PULL addr_word (R/W# forced to 1), PULL N.
;                       -> START, address, N bytes (ACK all but last=NACK),
;                          STOP; PUSH each received byte word; EVT 0.
;                       -> NACK on address: PUSH 0xFFE0, STOP, EVT 1.
;   cmd 0x00FF: HLT.  unknown cmd words: ignored.
;   SCL stuck low > 4096 cycles (clock-stretch timeout): PUSH 0xFFFD,
;                       release bus, EVT 3.
;
; OBSERVER DEBUG RECIPE (host-side; Q4: PE never reads trace)
;   Capture a failing transaction on a START condition
;   (SDA falling while SCL high):
;     msr EDGE_MASK, 0x80     ; pin7 (SDA)
;     msr EDGE_CFG1, 0x80     ; pin7 = falling (bits[7:6]=10)
;     msr TRIG_MODE, 1        ; EDGE (write disarms; configure first)
;     msr OBS_CTL, 1          ; OBS_EN, LAST
;   ... run transaction ...
;   host RD_TRACE (0x07) -> entries {ts,pins}; PULSE alt: PIN_SEL=7 with
;   PATTERN (MASK=0xC0, VALUE=0x40) = "SCL high & SDA low" level window.
;
; CYCLE BUDGET (theory @50 MHz; measured = sim pin-log, see test_i2c.py)
;   bit time (SCL rise->rise, nominal) :  500 theory /   499 measured
;   SCL high phase                     :  250 theory /   248 measured
;   SCL low phase                      :  250 theory /   251 measured
;   byte (9 clocks, nominal)           : 4500 theory / ~4402 measured
;   SDA setup before SCL rise (SS)     :   19-22 cycles (per path)
;   clock-stretch tolerance            : up to 4096 cycles/bit (tsel=1 WAIT)
;   SPEC GATES (std-mode, measured over 92 highs / 90 lows, all comply):
;     t_HIGH >= 200c : min measured 247c
;     t_LOW  >= 235c : min measured 242c (ackbit->rxbit path)
;     t_BUF  >= 235c : measured 270c, 261c
;
; TIMING DERIVATION (nominal, no stretch; e = WAIT elapsed = 1, sync delay)
;   txbit : 16 + e + SH+SL+SS = 499 -> SH=248, SL=251, SS=19
;     (the old "17 overhead -> 500" theory miscounted by one; sim shows a
;      stable 499c bit = 100.2 kHz, well within I2C tolerance)
;   rxbit : 19 + e + SA2+SB2+SL+SS = 500 -> SA2=118, SB2=120, SL=220, SS=22
;   ackbit: high = 9+e+SA+SB = 250 -> SA=119, SB=121
;   (see test log for measured values)
;
; BUGFIXES 2026-09-27 (coordinator): three data-integrity bugs found by
; the test author (verified in a /tmp copy, then fixed below):
;   1. wr_byte sent bits [15:8] (always 0x00) -- added shl-by-8
;      left-align prologue before the MSB-first loop.
;   2. ackbit clobbered Z (`and r8,r8,r7` after the flag-setting `and`)
;      -- the SDA-isolating `and` is now the last flag-setter before ret.
;   3. mackbit clobbered Z (r8 drive between flag-set and `jmp nz`) --
;      drive moved before the flag-setting `and`.
;   4. t_LOW violations on ACK-family clocks: the 9th-clock low phases
;      were 149-206c (< 235c spec min) because ackbit/pulse250 used
;      sleep-120 tails sized for txbit's overhead, not the shorter
;      ACK-path overheads. Padded per subroutine (ackbit SL2 120->204,
;      pulse250 tail 120->216, nack_abort entry +40, i2c_start first-
;      clock low 100->200): all 90 measured lows now >= 242c.
;   5. t_BUF violation: back-to-back transactions had 130c bus-free
;      (< 235c). i2c_stop bus-free sleep 100->240: t_BUF = 270/261c.
;
; REGISTER MAP: r15=1 (R_ONE, preserved). r0-r7 scratch (r0=zero temp,
;   r4=7 const, r5=0xFFE0 const, r6=0x40 SCL mask, r7=0x80 SDA mask).
;   r8 = pin shadow {SDA=bit7, SCL=bit6}. r9 = WAIT elapsed.
;   r10-r11 temps (r11=status), r12=bytes remaining, r13=byte reg,
;   r14=bit counter / byte index.
; ============================================================================

; ---------------- init ----------------
        pdir 0xFF
        pmask 0xFF
        pset 0x01, d=4        ; drive pin0 high, settle
        pget r15              ; r15 = 1  (R_ONE idiom; preserved forever)
        ; --- I2C pin config: SCL=pin6, SDA=pin7, open-drain + pull-up ---
        ldi r0, 0xF000
        pmode r0              ; pins 6,7 = {od=1,pu=1}
        pdir 0xC0             ; PE drives pins 6,7 (open-drain)
        pmask 0xC0            ; PSET touches pins 6,7 only
        ldi r8, 0xC0          ; shadow: both lines released
        pset 0xC0             ; release SCL+SDA -> idle bus
        ; --- constants ---
        ldi r6, 0x0040        ; SCL mask
        ldi r7, 0x0080        ; SDA mask
        ldi r5, 0xFFE0        ; NACK status base
        ldi r4, 0x0006
        add r4, r4, r15       ; r4 = 7 (rxbit shift amount)
        ldi r3, 0xFFFE        ; addr mask: force R/W#=0
        jmp cmd_loop

; ---------------- host command loop ----------------
cmd_loop:
        jmp cmd_have, rxne    ; spin until RX FIFO non-empty
        jmp cmd_loop
cmd_have:
        pull r0               ; cmd word
        ldi r1, 0x0000
        add r1, r1, r15       ; r1 = 1
        cmp r0, r1
        jmp do_write, z       ; 0x0001 = write
        ldi r1, 0x00FE
        add r1, r1, r15       ; r1 = 0x00FF
        cmp r0, r1
        jmp do_hlt, z         ; 0x00FF = halt
        ldi r1, 0x0002
        cmp r0, r1
        jmp do_read, z        ; 0x0002 = read
        jmp cmd_loop          ; unknown: ignore
do_hlt:
        hlt

; ---------------- write transaction ----------------
; RACE FIX 2026-09-27: every PULL is preceded by an RXNE wait. The serial
; host port delivers words ~2000 core clocks apart; the old code pulled
; frame words back-to-back, so 2nd+ words hit an empty FIFO and PULL
; returned 0 (a write would send 0x00 bytes / read the wrong N).
do_write:
        jmp ww_a_have, rxne      ; wait for addr word
        jmp do_write
ww_a_have:
        pull r11              ; addr word
ww_n_wait:
        jmp ww_n_have, rxne      ; wait for N word
        jmp ww_n_wait
ww_n_have:
        pull r12              ; N data bytes
        msr r15, STATUS       ; clear TIMEOUT sticky (W1C bit0)
        and r11, r11, r3      ; force R/W#=0
        ldi r0, 0             ; zero temp
        ldi r14, 0            ; byte index 0 = address
        mov r13, r11
        call i2c_start
        call wr_byte          ; send addr; Z=1 -> ACK
        jmp ww_ack, z
        or r11, r5, r14       ; status = 0xFFE0|idx
        jmp nack_abort
ww_ack:
        cmp r12, r0
        jmp wr_end, z         ; N==0: address probe only
wr_loop:
        jmp ww_d_have, rxne      ; wait for data word (SCL held low: legal
        jmp wr_loop              ; master clock-stretch while waiting)
ww_d_have:
        pull r13              ; data word
        add r14, r14, r15     ; idx++
        call wr_byte
        jmp ww_ack2, z
        or r11, r5, r14
        jmp nack_abort
ww_ack2:
        djnz r12, wr_loop
wr_end:
        call i2c_stop
        ldi r11, 0
        push r11              ; 0x0000 = OK
        evt 0
        jmp cmd_loop

; ---------------- read transaction ----------------
do_read:
        jmp rw_a_have, rxne      ; wait for addr word (RACE FIX, see above)
        jmp do_read
rw_a_have:
        pull r11              ; addr word
rw_n_wait:
        jmp rw_n_have, rxne      ; wait for N word
        jmp rw_n_wait
rw_n_have:
        pull r12              ; N bytes to read
        msr r15, STATUS       ; clear TIMEOUT sticky
        or r11, r11, r15      ; force R/W#=1
        ldi r0, 0
        ldi r14, 0
        mov r13, r11
        call i2c_start
        call wr_byte          ; send addr; Z=1 -> ACK
        jmp rw_ack, z
        or r11, r5, r14       ; 0xFFE0 (addr NACK)
        jmp nack_abort
rw_ack:
        cmp r12, r0
        jmp rd_end, z         ; N==0
rd_loop:
        call rd_byte          ; r13 = received byte
        push r13
        djnz r12, rd_ackmore  ; more bytes? (new r12 != 0)
        ldi r0, 0             ; last byte -> NACK
        call mackbit
        jmp rd_end
rd_ackmore:
        mov r0, r15           ; r0=1 -> ACK
        call mackbit
        jmp rd_loop
rd_end:
        call i2c_stop
        evt 0
        jmp cmd_loop

; ============================================================================
; subroutines (CALL depth <= 2; 4-deep HW stack)
; ============================================================================

; ---- i2c_start: SDA fall while SCL high; ends with SCL low ----
i2c_start:
        and r8, r8, r6        ; r8 = 0x40 (SDA low, SCL released)
        psetr r8              ; START condition
        sleep 100             ; hold
        and r8, r8, r7        ; r8 = 0x00
        psetr r8              ; SCL low
        sleep 200             ; first-clock low (fix 2026-09-27: was 100;
                             ; measured 149c < 235c t_LOW. +100 -> 249c)
        ret

; ---- i2c_stop: SDA rise while SCL high; ends idle (r8=0xC0) ----
i2c_stop:
        and r8, r8, r6        ; r8 = 0x00 (SDA low, SCL low)
        psetr r8
        sleep 60
        or r8, r8, r6         ; SCL release
        psetr r8
        wait 6,1,level,1,r9   ; ensure SCL high (no tmo check; cleared per txn)
        sleep 60
        or r8, r8, r7         ; SDA release -> STOP edge
        psetr r8
        sleep 240             ; bus-free time (fix 2026-09-27: was 100;
                             ; measured t_BUF was 130c < 235c spec min.
                             ; +140 -> t_BUF >= 261c on all paths)
        ldi r8, 0xC0          ; shadow = idle
        ret

; ---- txbit: send 1 bit; C = data bit on entry. SCL low on entry. ----
; 500 cycles rise->rise nominal: 17 + e + SH+SL+SS, SH=243, SL=220, SS=19
txbit:
        and r8, r8, r6        ; SDA <- 0
        jmp txb1, c
        jmp txb0
txb1:
        or r8, r8, r7         ; SDA <- 1 (release)
txb0:
        psetr r8              ; SDA setup, SCL low
        sleep 19              ; SS
        or r8, r8, r6         ; SCL release
        psetr r8              ; SCL rise
        wait 6,1,level,1,r9   ; stretch-tolerant (tsel=1 -> 4096)
        jmp tmo_abort, tmo
        sleep 243             ; SH: high = 7+243 = 250
        and r8, r8, r7        ; SCL <- 0, hold SDA
        psetr r8              ; SCL fall
        sleep 220             ; SL
        ret

; ---- wr_byte: send r13 MSB-first + ACK clock. Z=1 -> ACK (SDA low). ----
; r13 holds the byte in [7:0]; left-align to [15:8] first so the
; shl-by-1 loop below shifts the true MSB into C (fix 2026-09-27: the
; loop used to send bits [15:8], i.e. always 0x00).
wr_byte:
        ldi r14, 8
wal:    shl r13, r13, r15     ; align: [7:0] -> [15:8]
        djnz r14, wal
        ldi r14, 8
wbl:
        shl r13, r13, r15     ; MSB -> C
        call txbit
        djnz r14, wbl
        or r8, r8, r7         ; release SDA for ACK bit
        psetr r8
        sleep 19              ; SS
        call ackbit           ; Z=1 iff slave ACKed
        ret

; ---- ackbit: 9th clock, sample slave ACK. Z=1 -> ACK. ----
; high = 9+e+SA+SB = 250: SA=119, SB=121
ackbit:
        or r8, r8, r6         ; SCL release
        psetr r8              ; SCL rise
        wait 6,1,level,1,r9
        jmp tmo_abort, tmo
        sleep 119             ; SA: sample ~mid-high
        pget r10
        sleep 121             ; SB
        and r8, r8, r7        ; SCL <- 0 (SDA stays released)
        psetr r8              ; SCL fall
        sleep 204             ; SL2 (fix 2026-09-27: was 120; the ACK clock's
                             ; low phase was 175c -> next txbit, 158c -> next
                             ; rxbit, i.e. under the 235c t_LOW spec minimum.
                             ; +84 pads the shortest outgoing path to 242c)
        and r10, r10, r7      ; isolate SDA; Z=1 iff low (ACK).
                             ; MUST stay the last flag-setting insn before
                             ; ret (fix 2026-09-27: the r8 mask above used
                             ; to clobber Z, so NACK was always reported).
        ret

; ---- rxbit: receive 1 bit (SDA released), shift into r13. ----
; 500 cycles rise->rise: 19 + e + SA2+SB2+SL+SS, SA2=118, SB2=120, SL=220, SS=22
rxbit:
        or r8, r8, r7         ; release SDA
        psetr r8
        sleep 22              ; SS
        or r8, r8, r6         ; SCL release
        psetr r8              ; SCL rise
        wait 6,1,level,1,r9
        jmp tmo_abort, tmo
        sleep 118             ; SA2
        pget r10
        shr r10, r10, r4      ; r4=7: SDA bit -> bit0
        shl r13, r13, r15     ; r13 <<= 1
        or r13, r13, r10      ; insert bit
        sleep 120             ; SB2
        and r8, r8, r7        ; SCL <- 0
        psetr r8              ; SCL fall
        sleep 220             ; SL
        ret

; ---- rd_byte: receive byte -> r13 ----
rd_byte:
        ldi r14, 8
        ldi r13, 0
rbl:
        call rxbit
        djnz r14, rbl
        ret

; ---- mackbit: master ACK/NACK bit. r0=1 -> ACK (SDA low); r0=0 -> NACK. ----
; Fix 2026-09-27: the flag-setting `and` must sit immediately before the
; `jmp .., nz` -- the r8 drive used to sit between them and clobber Z,
; so the master always NACKed.
mackbit:
        and r8, r8, r6        ; SDA low (drive first)
        and r1, r0, r0        ; Z = (r0==0); keep directly before use
        jmp mck_ack, nz
        or r8, r8, r7         ; NACK: release SDA
mck_ack:
        psetr r8
        sleep 19              ; SS
        call pulse250
        ret

; ---- pulse250: plain SCL pulse, 250/250 (no sample). ----
pulse250:
        or r8, r8, r6         ; SCL release
        psetr r8              ; SCL rise
        wait 6,1,level,1,r9
        jmp tmo_abort, tmo
        sleep 243             ; SH
        and r8, r8, r7        ; SCL <- 0
        psetr r8              ; SCL fall
        sleep 216             ; low-phase pad (fix 2026-09-27: was 120; the
                             ; mackbit clock's low was 155c -> next rxbit,
                             ; under the 235c t_LOW minimum. +96 -> nominal)
        ret

; ---- nack_abort: r11 = 0xFFE0|idx. Entry: SCL low (ackbit tail), SDA released. ----
nack_abort:
        sleep 40              ; extend the 9th-clock low: ackbit tail leaves
                             ; 206c, +40 -> 246c >= 235c t_LOW (fix 2026-09-27)
        pset 0x40             ; SDA low, SCL released (rises)
        wait 6,1,level,1,r9   ; already high -> e=0
        pset 0xC0             ; SDA rise while SCL high = STOP
        sleep 30
        evt 1
        jmp abort_common

; ---- tmo_abort: SCL stuck low. Release bus, report 0xFFFD. ----
tmo_abort:
        ldi r11, 0xFFFC
        add r11, r11, r15     ; r11 = 0xFFFD (odd imm16 not LDI-able)
        pset 0xC0             ; release both lines
        sleep 20
        evt 3
        jmp abort_common

; ---- abort_common: push status, resync shadow, clear TIMEOUT, loop ----
abort_common:
        push r11
        ldi r8, 0xC0          ; shadow = idle
        msr r15, STATUS       ; W1C: clear TIMEOUT sticky
        jmp cmd_loop
