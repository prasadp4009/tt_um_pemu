; ============================================================================
; Tarang-32 firmware: PS/2 host (keyboard) interface, open-drain CLK + DATA
; Stretch-protocol worker -- Jane Street Protocol Emulator ASIC competition
; ============================================================================
; PIN MAP (logical pins 0..7)
;   pin0 = PS/2 CLK    open-drain + pull-up (PMODE bits[1:0]  = {od=1,pu=1})
;   pin1 = PS/2 DATA   open-drain + pull-up (PMODE bits[3:2]  = {od=1,pu=1})
;   pins 2..7 unused (Hi-Z).
; Open-drain discipline (same as I2C firmware): PSET bit=0 -> drive low,
; PSET bit=1 -> release (Hi-Z); the line's high level comes ONLY from the
; pull-up. The PE never drives CLK or DATA high push-pull.
; Pin shadow values used below (PMASK=0x03, PDIR=0x03):
;   0x03 = CLK released, DATA released   (idle)
;   0x02 = CLK released, DATA driven low
;   0x01 = CLK driven low, DATA released
;   0x00 = CLK driven low, DATA driven low
;
; HOST COMMAND / RESPONSE WORDS (16-bit words via RX/TX FIFOs)
;   cmd 0x0001 (receive): receive one device->host frame.
;                       -> PUSH received byte, PUSH status, EVT 0, loop.
;                          status 0x0000 = OK
;                          status 0x0001 = parity error (byte still pushed)
;                          status 0x0002 = framing error (start!=0/stop!=1)
;                          status 0x0004 = clock timeout (no device)
;                          (bits may combine, except timeout replaces)
;   cmd 0x0002 (transmit): PULL arg byte (e.g. 0xED = Set/Reset LEDs).
;                       -> inhibit + request-to-send + device-clocked frame;
;                          PUSH status, EVT 0, loop.
;                          status 0x0000 = device ACK bit seen (ACK = DATA
;                                            low on the 12th clock)
;                          status 0x0001 = no ACK (DATA high on 12th clock)
;                          status 0x0004 = clock timeout (no device)
;   cmd 0x00FF: HLT.  unknown cmd words: ignored.
;
; PS/2 FRAME (both directions, 11 clocks + host->device ACK clock)
;   start(0), data d0..d7 (LSB first), odd parity, stop(1).
;   Odd parity: total number of 1 bits in {data, parity} is odd.
;   Device generates the clock in BOTH directions (~10.0-16.7 kHz spec;
;   golden test models 12 kHz, bit cell 4167 cycles @50 MHz).
;
; DATA/CLOCK CONVENTION (stated once, used by firmware AND device model)
;   In both directions the TRANSMITTER changes DATA only while CLK is
;   high, and the RECEIVER samples DATA on the falling edge of CLK.
;   (This is the canonical PS/2 rule: "data is placed by the transmitter
;   while Clock is high and read by the receiver on the falling edge".)
;   - device->host: device sets DATA during each CLK-high phase; host
;     firmware waits for the synchronized CLK falling edge, then samples
;     DATA with PGET.
;   - host->device: after inhibit + RTS, device clocks; host firmware
;     waits for CLK high (level), sets DATA, waits for the CLK falling
;     edge (device samples there). After the stop bit the host releases
;     DATA; the device drives DATA low for the 12th (ACK) clock, which
;     the firmware samples after that falling edge.
;
; EDGE SYNC STRATEGY: firmware sequences on CLK *levels* (WAIT level
; high, then WAIT level low) instead of WAIT edge mode, so a falling
; edge can never be missed in the turnaround between two WAITs. Each
; WAIT uses tsel=1 (4096 cycles, the T17-safe maximum); the helpers
; loop it r12 times and clear the TIMEOUT sticky per iteration, so a
; 4167-cycle bit cell (which straddles one 4096 timeout) is handled.
; The 2-cycle input synchronizer delay is irrelevant at this timescale
; (half cell = 2083 cycles); sampling is consistent: PGET right after
; the low-level WAIT returns, when DATA is mid-low-phase and stable.
;
; HOST->DEVICE INHIBIT: firmware drives CLK low for 6000 cycles of
; SLEEP (6001 cycles incl. base; >= 5000 required = 100 us) before
; pulling DATA low (request-to-send), then releases CLK.
;
; REGISTER MAP: r15=1 (materialized by DJNZ, preserved forever -- the
;   pin-based R_ONE idiom is NOT used: it would drive pin0 high
;   push-pull at boot and break the open-drain invariant on pins 0/1).
;   r0,r1,r2 = scratch; r3 = 0 (zero const); r4 = 7 (shift amount);
;   r6 = TX shifter; r7 = bit counter; r9 = WAIT elapsed scratch;
;   r10 = status / TX parity bit; r11 = helper timeout flag (0/1);
;   r12 = helper WAIT-loop budget; r13 = byte register; r14 = ones count.
; ============================================================================

; ---------------- init ----------------
        ldi r15, 0x0002
        djnz r15, one_ready   ; r15 = 2-1 = 1 (DJNZ materializes R_ONE)
one_ready:
        xor r3, r3, r3        ; r3 = 0 (zero const, preserved)
        ldi r0, 0x000E
        add r0, r0, r15       ; r0 = 0x000F
        pmode r0              ; pins 0,1 = {open_drain=1, pull_up=1}
        pmask 0x03            ; PSET touches pins 0,1 only
        pset 0x03             ; pin_drv = release both (while PDIR=0: no drive)
        pdir 0x03             ; enable open-drain drivers on CLK+DATA (released)
        ldi r4, 0x0006
        add r4, r4, r15       ; r4 = 7
        jmp cmd_loop

; ---------------- host command loop ----------------
cmd_loop:
        jmp cmd_have, rxne    ; spin until RX FIFO non-empty
        jmp cmd_loop
cmd_have:
        pull r0               ; cmd word
        cmp r0, r15
        jmp do_rx, z          ; 0x0001 = receive
        ldi r1, 0x0002
        cmp r0, r1
        jmp do_tx, z          ; 0x0002 = transmit
        ldi r1, 0x00FE
        add r1, r1, r15       ; r1 = 0x00FF
        cmp r0, r1
        jmp do_hlt, z         ; 0x00FF = halt
        jmp cmd_loop          ; unknown: ignore
do_hlt:
        hlt

; ============================================================================
; cmd 0x0001: receive one device->host frame -> PUSH byte, PUSH status
; ============================================================================
do_rx:
        msr r15, STATUS       ; clear stickies (TIMEOUT W1C)
        pset 0x03             ; release both lines
        ldi r13, 0            ; byte accumulator
        ldi r14, 0            ; ones count (data + parity)
        ldi r10, 0            ; status
        ; ---- start bit ----
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp rx_tmo, nz
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp rx_tmo, nz
        pget r0
        shr r0, r0, r15       ; DATA (pin1) -> bit0
        and r0, r0, r15       ; r0 = start bit
        cmp r0, r3
        jmp rx_start_ok, z
        ldi r0, 0x0002
        or r10, r10, r0       ; status |= framing (start != 0)
rx_start_ok:
        ; ---- 8 data bits, LSB first ----
        ldi r7, 8
rx_bit:
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp rx_tmo, nz
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp rx_tmo, nz
        pget r0
        shr r0, r0, r15
        and r0, r0, r15       ; r0 = data bit
        add r14, r14, r0      ; ones += bit
        shr r13, r13, r15     ; accumulator >>= 1
        shl r0, r0, r4        ; bit -> bit7
        or r13, r13, r0       ; (after 8 bits r13 = byte, LSB-first order)
        djnz r7, rx_bit
        ; ---- parity bit ----
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp rx_tmo, nz
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp rx_tmo, nz
        pget r0
        shr r0, r0, r15
        and r0, r0, r15       ; r0 = parity bit
        add r14, r14, r0      ; ones += parity
        and r0, r14, r15      ; total ones must be ODD
        cmp r0, r3
        jmp rx_par_ok, nz
        or r10, r10, r15      ; status |= parity error (bit0 = r15 = 1)
rx_par_ok:
        ; ---- stop bit ----
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp rx_tmo, nz
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp rx_tmo, nz
        pget r0
        shr r0, r0, r15
        and r0, r0, r15       ; r0 = stop bit
        cmp r0, r15
        jmp rx_done, z
        ldi r0, 0x0002
        or r10, r10, r0       ; status |= framing (stop != 1)
rx_done:
        push r13              ; received byte
        push r10              ; status
        evt 0
        jmp cmd_loop
rx_tmo:
        ldi r10, 0x0004       ; timeout status (byte is partial/zero)
        jmp rx_done

; ============================================================================
; cmd 0x0002: transmit one byte (arg word) -> PUSH status
; ============================================================================
do_tx:
        jmp tx_arg_have, rxne ; wait for arg word (host delivers ~2000c apart)
        jmp do_tx
tx_arg_have:
        pull r13              ; byte to send
        ldi r1, 0x00FE
        add r1, r1, r15       ; r1 = 0x00FF
        and r13, r13, r1      ; low 8 bits only
        msr r15, STATUS       ; clear stickies
        ; ---- odd parity of r13 -> r10 (parity bit) ----
        mov r6, r13
        ldi r14, 0            ; ones count
        ldi r7, 8
tx_par:
        shr r6, r6, r15       ; C = next bit (LSB first; order irrelevant)
        jmp tx_par1, c
        jmp tx_par_next
tx_par1:
        add r14, r14, r15
tx_par_next:
        djnz r7, tx_par
        and r10, r14, r15     ; ones & 1
        cmp r10, r3
        jmp tx_par_even, z
        ldi r10, 0            ; ones odd -> parity bit 0
        jmp tx_inhibit
tx_par_even:
        mov r10, r15          ; ones even -> parity bit 1
        ; ---- inhibit: CLK low >= 5000 cycles, DATA released ----
tx_inhibit:
        pset 0x03             ; release both, then wait for the bus to be
        ldi r12, 8            ; idle-high before inhibiting: the previous
        call wf_high          ; frame's last clock low phase may still be
                              ; running, and driving CLK low during it would
                              ; merge the inhibit into that phase on the wire
                              ; (timeout result ignored: inhibit regardless)
        pset 0x02             ; CLK drive low, DATA released
        sleep 6000            ; 6001 cycles of CLK-low (spec >= 5000)
        ; ---- request-to-send: DATA low too (start bit presented) ----
        pset 0x00             ; CLK low, DATA low
        sleep 100
        pset 0x01             ; release CLK, DATA stays low (start bit)
        ; ---- start bit clock: device samples DATA=0 on falling edge ----
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp tx_tmo, nz
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp tx_tmo, nz
        ; ---- 8 data bits, LSB first; set DATA while CLK high ----
        mov r6, r13
        ldi r7, 8
tx_bit:
        ldi r12, 8
        call wf_high          ; CLK high phase begins
        cmp r11, r3
        jmp tx_tmo, nz
        and r2, r6, r15       ; next data bit
        shr r6, r6, r15
        cmp r2, r15
        jmp tx_bit1, z
        pset 0x01             ; DATA = 0 (drive low), CLK released
        jmp tx_bit_set
tx_bit1:
        pset 0x03             ; DATA = 1 (release), CLK released
tx_bit_set:
        ldi r12, 8
        call wf_low           ; falling edge: device samples DATA
        cmp r11, r3
        jmp tx_tmo, nz
        djnz r7, tx_bit
        ; ---- parity bit (r10) ----
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp tx_tmo, nz
        cmp r10, r15
        jmp tx_parb1, z
        pset 0x01             ; parity = 0
        jmp tx_parb_set
tx_parb1:
        pset 0x03             ; parity = 1
tx_parb_set:
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp tx_tmo, nz
        ; ---- stop bit (DATA = 1, released) ----
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp tx_tmo, nz
        pset 0x03             ; stop bit = 1
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp tx_tmo, nz
        ; ---- ACK clock (12th): DATA released; device drives ACK low ----
        ldi r12, 8
        call wf_high
        cmp r11, r3
        jmp tx_tmo, nz
        ldi r12, 8
        call wf_low
        cmp r11, r3
        jmp tx_tmo, nz
        pget r0
        shr r0, r0, r15
        and r0, r0, r15       ; ACK bit: 0 = device ACK
        cmp r0, r3
        jmp tx_ack_ok, z
        mov r10, r15          ; status 0x0001 = no ACK
        jmp tx_done
tx_ack_ok:
        ldi r10, 0            ; ACK seen
tx_done:
        pset 0x03             ; release both lines (idle)
        push r10              ; status
        evt 0
        jmp cmd_loop
tx_tmo:
        pset 0x03             ; release both lines
        ldi r10, 0x0004
        jmp tx_done

; ============================================================================
; subroutines (CALL depth 1 from handlers)
; ============================================================================
; wf_high: wait until synchronized CLK (pin0) == 1 (level).
;   r12 = max WAIT iterations (4096 cycles each, tsel=1, T17-safe).
;   Returns r11 = 0 (level reached) / 1 (budget exhausted).
;   Clobbers r9, r12. Clears TIMEOUT sticky on every timed-out iteration.
wf_high:
        ldi r11, 0
wf_h_loop:
        wait 0, 1, level, 1, r9
        jmp wf_h_tmo, tmo
        ret
wf_h_tmo:
        msr r15, STATUS       ; W1C: clear TIMEOUT
        djnz r12, wf_h_loop
        add r11, r11, r15     ; r11 = 1
        ret

; wf_low: wait until synchronized CLK (pin0) == 0 (level).
;   Same contract as wf_high.
wf_low:
        ldi r11, 0
wf_l_loop:
        wait 0, 0, level, 1, r9
        jmp wf_l_tmo, tmo
        ret
wf_l_tmo:
        msr r15, STATUS       ; W1C: clear TIMEOUT
        djnz r12, wf_l_loop
        add r11, r11, r15     ; r11 = 1
        ret
