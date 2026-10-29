; =============================================================================
; Tarang-32 UART firmware — 115200 8N1, bit = 434 cycles @ 50 MHz (20 ns/cycle)
; Worker A deliverable, Jane Street Protocol Emulator ASIC competition.
;
; Pins: TX = pin0 (PE push-pull out, idle high), RX = pin1 (PE in, Hi-Z).
; r15 = 1 (R_ONE idiom, preserved). r0-r7 scratch. r8-r14 protocol constants.
; Standalone image: own init + host command loop. No randomness.
;
; ---- Host command / response words (16-bit, via RX/TX FIFOs) ----
;   Host -> PE (PULL):
;     0x0001            TX demo: next word N, then N data words (byte in [7:0])
;     0x0002            RX demo: next word N, then receive N bytes from pin1
;     0x00FF            HLT
;     other             -> PE PUSHes 0xFFFF, evt 0, loops (unknown command)
;   PE -> host (PUSH):
;     TX demo: 0x0000 status on success, then evt 0
;     RX demo: one word per byte received; 0xFFFF on RX timeout / framing
;              error; 0xFFFD on host underrun; 0xFFFE on break; evt 0 on
;              clean completion, evt 1 on RX-timeout abort, evt 2 on break.
;
; ---- Overrun / starvation policy (RACE FIX 2026-09-27) ----
;   The serial host port delivers words ~2000 core clocks apart, but the
;   old code pulled multi-word frame words back-to-back (~5 cycles apart):
;   2nd+ words hit an empty RX FIFO and set RX_UNDERRUN. Every PULL below
;   is now preceded by an RXNE wait, so the firmware blocks until the
;   word is actually available instead of racing the host. The post-PULL
;   RX_UNDERRUN checks are retained as a safety net (unreachable in
;   normal operation -- no other FIFO consumer exists -- but they
;   preserve the abort path if a future edit pulls without waiting).
;   * PUSH can never overrun: a demo pushes at most N+1 words; keep N <= 14
;     (FIFO depth 16, worst case N data + status + error words).
;   * RX inter-byte gap: the start-edge WAIT uses tsel=1 (4096 cycles), so the
;     peer must begin the next byte within ~4096 cycles of the previous
;     byte's end or a spurious 0xFFFF timeout fires. Back-to-back is fine.
;
; ---- Observer debug recipe (RX debug: trigger on pin1 falling edge) ----
;   PE cannot read trace SRAM (Q4). Configure the Observer, run, host reads:
;     ldi rX, 0x02  |  msr rX, EDGE_MASK   ; watch pin1
;     ldi rX, 0x08  |  msr rX, EDGE_CFG0   ; pin1 bits[3:2] = 10 (falling)
;     ldi rX, 1     |  msr rX, TRIG_MODE   ; EDGE mode (any write disarms)
;     ldi rX, 1     |  msr rX, OBS_CTL     ; OBS_EN, LAST
;   ... run the RX demo ...
;   host: RD_TRACE (0x07) -> entries {ts[31:0], pins[7:0]}, OBS_PTR = count.
;   Correlate entry ts with the firmware's deterministic sample schedule
;   (first data-bit sample at wire time start_edge+652, then every 434).
;
; ---- Deviations from the task brief (measured, deliberate) ----
;   D1. WAIT edge modes (rising/falling) were broken in tools/sim.py at
;       firmware-authoring time (wait_prev latched before wait_cond(), so
;       v == pv always; verified: edge modes always timed out). FIXED by
;       the tool owner after 1-Wire bring-up (commit 86cbacb): check-then-
;       latch order, T8-exact elapsed, selftest regression pinned. This
;       firmware keeps its LEVEL waits -- functionally identical here
;       because the line state at each WAIT entry is known:
;       `wait 1,0,level,1` == falling-edge wait (line high at entry);
;       `wait 1,1,level,1` == rising-edge wait (line low at entry).
;       Tsel <= 1 everywhere (T17 respected, no chained >4096).
;       NOTE D3's "no chained >4096" is superseded: the break rule chains
;       two tsel=1 waits (each <= 4096, never one long wait) -- see D2.
;   D2. BREAK THRESHOLD (coordinator decision 2026-09-27, supersedes the
;       brief's "6000 low cycles"): break = pin1 low for >= 8192 cycles
;       (two chained tsel=1 rising-waits, both timing out). Rationale: the
;       longest legitimate low run is start+8 zero data bits = 9*434 =
;       3906 cycles, so any threshold > 3906 discriminates; 8192 uses two
;       identical tsel=1 windows with no T17 exposure and no extra
;       chaining arithmetic. A 6000-cycle low is (correctly, per the rule)
;       treated as a garbled byte, not a break. The test peer drives the
;       break low for 14000 cycles (> 8192 + sampling time).
;   D3. Break check runs AFTER sampling (on stop-bit == 0 framing error),
;       not before: a pre-sample rising-wait would consume the byte time
;       (stop bit of 0x00 arrives at 3906 cycles < 4096) and destroy the
;       sample schedule. Sampling first, then the two chained 4096-cycle
;       high-waits on framing error, preserves both requirements.
;   D4. Cheatsheet says "sleep 433 per bit -> 434 cycles"; the wire interval
;       between PSET commits is 1 (pset) + (1+433) (sleep) = 435. This
;       firmware folds the per-bit housekeeping into the slot so every bit
;       cell is EXACTLY 434 cycles: psetr(1)+shr(1)+sleep 430(431)+djnz(1).
;
; ---- Cycle budget: theory vs measured (sim) ----
;   TX bit cell on wire ......... theory 434            measured 434 exact
;   TX byte pitch (start edge to next start edge)
;                                 theory 4349 (10*434 + 9 loop cycles)
;                                                       measured 4349
;   RX first data-bit sample .... theory start_edge+652 (offset +1 from
;                                 ideal mid-bit; sync-calibrated, see below)
;                                                       measured +1
;   RX sample spacing ........... theory 434            measured 434 exact
;   RX byte time (edge -> stop sample) theory 4124      measured 4124
;   RX back-to-back margin ...... +/-216 cycles to nearest bit edge
;
; ---- RX sampling calibration ----
;   WAIT(level,low) detects the wire falling edge with exactly 2 cycles of
;   latency (the architectural 2-FF sync): WAIT returns at end of cycle R =
;   k+2 where k = wire-edge cycle (measured with CAP vs a peer-driven edge
;   at a known cycle; see tests/test_uart.py calibration sub-test).
;   Sample schedule after WAIT: mov+ldi (2) + sleep 648 (649) -> first PGET
;   base at R+652, sampling wire at R+650 = k+652 = ideal mid-bit(k+651)+1.
;   Each following sample is exactly 434 cycles later (loop body
;   pget+and+shl+shr+or+sleep427+djnz = 1+1+1+1+1+428+1). Stop bit PGET
;   reuses the loop tail spacing (no extra sleep). All 9 samples sit +1
;   cycle from ideal mid-bit: margin +/-216 cycles.
;
; Word count: 125 words (see listing). Target <= 150, hard limit 256.
; =============================================================================

; ---- boot: R_ONE idiom -> r15 = 1 (preserve forever) ----
        pdir 0xFF
        pmask 0xFF
        pset 0x01, d=4           ; drive pin0 high; settle through 2-FF sync
        pget r15                ; r15 = 1

; ---- protocol constants, r8-r14 (LDI takes even immediates only) ----
        ldi r8, 0x0002          ; CMD_RX
        ldi r9, 0x00FE
        add r9, r9, r15         ; r9  = 0x00FF CMD_HLT
        ldi r10, 0xFFFE
        add r10, r10, r15       ; r10 = 0xFFFF ERR (rx timeout / framing)
        ldi r11, 0xFFFE         ; r11 = 0xFFFE ERR_BREAK
        ldi r12, 0xFFFC
        add r12, r12, r15       ; r12 = 0xFFFD ERR_UNDERRUN
        ldi r13, 0x0200         ; TX frame stop bit (bit 9)
        ldi r14, 0x0004         ; STATUS W1C mask: RX_UNDERRUN

; ---- UART pin config ----
        pdir 0x01               ; only pin0 driven (TX); pin1 = RX input
        pset 0x01               ; TX idle high

; ---- host command loop ----
cmdloop:
        jmp gotcmd, rxne        ; wait until RX FIFO non-empty
        jmp cmdloop
gotcmd:
        pull r0                 ; command word
        cmp r0, r15             ; 0x0001 = TX demo ?
        jmp txdemo, z
        cmp r0, r8              ; 0x0002 = RX demo ?
        jmp rxdemo, z
        cmp r0, r9              ; 0x00FF = HLT ?
        jmp dohlt, z
        push r10                ; unknown command -> 0xFFFF
        evt 0
        jmp cmdloop
dohlt:
        hlt

; =============================================================================
; TX demo: 0x0001, N, N data words. 10-bit frame, LSB-first, 434 cyc/bit.
; =============================================================================
txdemo:
        ldi r3, 0x0000          ; zero
        ldi r4, 0x00FE
        or r4, r4, r15          ; r4 = 0x00FF byte mask
tx_n_wait:
        jmp tx_n_have, rxne     ; RACE FIX: wait for N word
        jmp tx_n_wait
tx_n_have:
        pull r0                 ; N
        mrs r1, STATUS
        and r1, r1, r14         ; RX_UNDERRUN ?
        jmp tx_underrun, nz
        mov r5, r0              ; byte counter
        cmp r5, r3
        jmp txdone, z           ; N == 0: ack, send nothing
txloop:
        jmp tx_d_have, rxne     ; RACE FIX: wait for data word
        jmp txloop
tx_d_have:
        pull r0                 ; data word
        mrs r1, STATUS
        and r1, r1, r14
        jmp tx_underrun, nz
        and r0, r0, r4          ; keep [7:0]
        shl r7, r0, r15         ; r7 = byte << 1
        or r7, r7, r13          ; r7[9] = stop(1): 10-bit frame, bit0 = start
        ldi r6, 10              ; bit counter
txbit:
        psetr r7                ; emit r7[0] on pin0
        shr r7, r7, r15         ; advance frame (C = emitted bit, unused)
        sleep 430               ; bit cell: 1+1+431+1 = 434 cycles exactly
        djnz r6, txbit
        djnz r5, txloop
txdone:
        ldi r0, 0x0000
        push r0                 ; status 0x0000
        evt 0
        jmp cmdloop
tx_underrun:
        msr r14, STATUS         ; W1C: clear RX_UNDERRUN
        push r12                ; 0xFFFD: host starved TX data
        evt 0
        jmp cmdloop

; =============================================================================
; RX demo: 0x0002, N. Calibrated mid-bit PGET sampling (see header).
; Scratch: r0=N, r1=sample/wait-rd, r2=6 (shift const), r3=0, r4=0x0002
;          (pin1 mask), r5=byte counter, r6=bit counter, r7=byte accumulator.
; =============================================================================
rxdemo:
        ldi r3, 0x0000          ; zero
        ldi r4, 0x0002          ; pin1 mask
        ldi r2, 6               ; 0x0002 << 6 = 0x0080 (sample -> bit7)
rx_n_wait:
        jmp rx_n_have, rxne     ; RACE FIX: wait for N word
        jmp rx_n_wait
rx_n_have:
        pull r0                 ; N
        mrs r1, STATUS
        and r1, r1, r14         ; RX_UNDERRUN ?
        jmp rx_underrun, nz
        mov r5, r0              ; byte counter
        cmp r5, r3
        jmp rxdone, z           ; N == 0: ack, receive nothing
rxloop:
        wait 1, 0, level, 1, r1 ; wait for start bit (line low), tsel=1
        jmp rx_timeout, tmo      ; >4096 idle -> 0xFFFF, evt 1, abort
rx_sample:
        mov r7, r3              ; byte accumulator = 0
        ldi r6, 8               ; data-bit counter
        sleep 648               ; 2 + 649: first PGET lands on data-bit-1
                                ; mid-bit (wire k+652, ideal k+651)
rxbit:
        pget r1                 ; sample synchronized pins
        and r1, r1, r4          ; isolate pin1 -> 0x0002 / 0x0000
        shl r1, r1, r2          ; -> 0x0080 / 0x0000 (bit7)
        shr r7, r7, r15         ; accumulator >>= 1
        or r7, r7, r1           ; new bit into bit7 (LSB-first assembly)
        sleep 427               ; 1+1+1+1+1+428+1 = 434 between samples
        djnz r6, rxbit
        pget r1                 ; stop bit (spacing comes from loop tail)
        and r1, r1, r4
        jmp stop_ok, nz         ; stop high -> byte good
; ---- stop sampled low: framing error; is it a break? ----
; Two chained tsel=1 waits for the line to go HIGH; both timing out means
; the line stayed low >= 8192 cycles (~1.9 frames) -> BREAK. (D1: level
; waits; line is known-low at entry, so identical to rising-edge waits.)
        wait 1, 1, level, 1, r1 ; 1st window: wait for high, 4096 cycles
        jmp brk1, tmo
        jmp frame_err           ; line rose -> framing error only
brk1:
        msr r15, STATUS         ; clear TIMEOUT
        wait 1, 1, level, 1, r1 ; 2nd window: wait for high, 4096 cycles
        jmp brk2, tmo
        msr r15, STATUS
        jmp frame_err           ; rose in 2nd window -> not a break
brk2:
        msr r15, STATUS         ; clear TIMEOUT
        push r11                ; 0xFFFE BREAK
        evt 2
rxresync:
        wait 1, 1, level, 1, r1 ; wait for the break to end (line high)
        jmp rxrsync_c, tmo
        jmp rxrsync2
rxrsync_c:
        msr r15, STATUS         ; still in break; keep waiting
        jmp rxresync
rxrsync2:
        wait 1, 0, level, 1, r1 ; wait for the next start edge
        jmp rx_timeout, tmo      ; nothing comes -> 0xFFFF, evt 1, abort
        jmp rx_sample           ; got an edge: sample it (byte slot retries)
frame_err:
        push r10                ; 0xFFFF receive error; byte slot consumed
        djnz r5, rxloop
        jmp rxdone
stop_ok:
        push r7                 ; received byte word
        djnz r5, rxloop
rxdone:
        evt 0
        jmp cmdloop
rx_timeout:
        msr r15, STATUS         ; clear TIMEOUT
        push r10                ; 0xFFFF
        evt 1
        jmp cmdloop
rx_underrun:
        msr r14, STATUS         ; clear RX_UNDERRUN
        push r12                ; 0xFFFD
        evt 0
        jmp cmdloop
