; =============================================================================
; TEMPO-32 CAN 2.0A (standard 11-bit ID) firmware -- logic level, 1 Mbit/s
; 50 MHz core -> 20 ns/cycle; 1 Mbit/s -> exactly 50 cycles/bit.
;
; PINS: pin0 = TXD out (1=recessive, 0=dominant, as a transceiver expects)
;       pin1 = RXD in  (bus level: 0=dominant, 1=recessive)
; The bus is wired-AND at the transceiver: bus is dominant iff ANY node
; drives dominant. The testbench bus model resolves TXD + peer drive onto
; pin1 every cycle; firmware only ever reads the bus via pin1 (PGET).
;
; HOST COMMAND WORDS (16-bit, via RX FIFO; responses via TX FIFO):
;   0x0001 TX FRAME : PULL ID word (11-bit, MSB-first on wire), PULL DLC
;                     word (0..2), PULL DLC byte-words (low 8 bits used).
;                     Sends one CAN data frame, samples the ACK slot,
;                     PUSHes status (0 = ACK dominant, 1 = no ACK),
;                     `evt 0`, loop.
;   0x0002 ARB TEST : PULL ID word. Sends a DLC=0 frame with that ID under
;                     arbitration monitoring. If arbitration is lost in the
;                     ID field: TXD stays recessive, frame aborts, PUSH
;                     0xFFA0, `evt 0`, loop. If not lost, completes the
;                     frame and PUSHes the ACK status like 0x0001.
;   0x00FF HALT     : HLT (host GO wakes).
;   other           : PUSH 0xFFFF (unknown), `evt 0`, loop.
;   DLC > 2         : arg words are consumed and discarded, PUSH 0xFFFF.
;
; DLC CAP = 2 (stated cap): TEMPO has no data RAM and the 16 GPRs are fully
;   allocated (see register map). The data stream (up to 16 bits) must
;   survive the SOF..DLC fields intact in a register while the DLC field's
;   own shifter, the ID shifter, and the arbitration flag are also live;
;   the only spare byte-wide homes are observer sregs, and a 16-bit stream
;   cannot be reloaded from 8-bit sregs inside the inter-bit gap. DLC 3..8
;   would need a second stream register that does not exist. All other
;   fields are DLC-independent loops, so the cap is a data-length limit.
;
; FRAME (on wire): SOF(0) | ID 11b MSB-first | RTR=0 | IDE=0 | r0=0 |
;   DLC 4b MSB-first | data 8*DLC MSB-first | CRC-15 | CRC-delim(1) |
;   ACK slot (TXD recessive; receiver drives dominant) | ACK-delim(1) |
;   EOF 7x recessive + IFS 3x recessive (one 10-cell recessive loop).
; CRC-15: poly 0x4599, init 0x0000, computed in firmware over the DESTUFFED
;   stream SOF..data. Firmware keeps it left-aligned (crc<<1) so the MSB
;   is bit15 and the poly constant is 0x4599<<1 = 0x8B32.
; BIT STUFFING across SOF..CRC (incl. CRC field): after 5 consecutive equal
;   transmitted bits, one complement bit is inserted (send_bit/cell track
;   run length r9 / last bit r10; stuff bits are not CRC'd).
;
; BIT CELL (exactly 50 cycles, psetr-to-psetr): period =
;   cell (30 cycles call->ret, psetr at its cycle 1) + send_bit ret (1)
;   + uniform inter-bit gap I=10 + send_bit call (1) + send_bit entry (8).
;   In-cell work order: run-length update (5c), CRC-15 update (12c,
;   branch-equalized), then SLEEP to the sample point: PGET executes at
;   cell cycle 20 (0-based from the psetr cycle), sampling the
;   synchronized bus (wire value from ~cycle 18, 2-FF synchronizer).
;   Sample placement is forced by the per-bit workload: run+CRC+arbitration
;   bookkeeping is 27 fixed cycles of the 30-cycle cell, so the sample
;   sits at cycle 20 -- still 30 cycles before the cell ends, and the
;   peer/monitor drives each cell for its full 50 cycles, so the sample
;   is unambiguous. Arbitration combine (sent & arb_en & ~sample) folds
;   into r11 in-cell. Every inter-bit path (loop iteration via a loop-top
;   pad that entries skip with a jump, loop exit, section entry, stuff
;   entry/exit) is padded to exactly I=10; cell-direct gaps (post-CRC)
;   are padded to their own exact values (19/20 cycles).
;
; ARBITRATION: there is NO branch-on-pin instruction in TEMPO. The sample
;   path is PGET -> normalize -> AND-combine in the cell (flag r11), then
;   the ID loop tests r11 after each bit (CMP + JMP nz): branch-on-sample
;   costs ~3-4 cycles of loop overhead and is absorbed in the gap padding.
;   On loss: the current bit was sent recessive, so TXD is ALREADY
;   recessive; firmware simply never drives the next bit. The abort
;   decision completes before the next bit cell begins (measured from
;   the PC trace in the golden test; see stretch_results/can.md).
;
; HOST STAGING NOTE: the full command (<= 5 words for DLC<=2) fits the
;   16-deep RX FIFO, and every PULL is RXNE-guarded (wait_rx), so a host
;   that pre-stages the command gets exact 50-cycle cells throughout.
;   All arg pulls and the data-stream build happen BEFORE SOF, so frame
;   timing itself never waits on the host.
;
; Register map: r0=0 (never written after init), r1=field/stream shifter,
;   r2=cell scratch / setup counter, r3=bus sample (0/1, from cell),
;   r4=bit into cell / setup temp, r5=crc_en | (DLC==0 ? 2 : 0) flag pack
;   (cell gate tests r5 != 0), r6=arb_en / raw DLC (setup only),
;   r7=bit counter, r8=CRC-15 (left-aligned) / CRC shifter (CRC loop),
;   r9=run length, r10=last bit sent, r11=arb_lost accumulator,
;   r12=0x8B32 (aligned poly), r13=DLC work reg (revDLC) / data stream
;   relay then ACK status, r14=5 (stuff threshold), r15=1 (R_ONE).
; Sreg use: EDGE_MASK=b0 stash, EDGE_CFG0=b1 stash then revDLC,
;   EDGE_CFG1=total data bits, WMARK=CRC bit count (15);
;   VALUE/MASK = send_bit stash.
; =============================================================================

; ---- init: R_ONE idiom (CAN variant), pin config, constants -----------------
        pmask 0xFF
        pset 0x01               ; preset TXD latch recessive BEFORE pdir
                                ; (else TXD glitches dominant at boot)
        pdir 0x01               ; drive pin0 only for R_ONE
        pset 0x01, d=4          ; TXD recessive, settle 2-FF sync
        pget r15                ; pins byte: bit0=1 (driven), bit1=bus idle
                                ; recessive=1, bits2-7=0 -> 0x03 (CAN bus
                                ; idles recessive, so the stock idiom's
                                ; "all other pins read 0" fails on RXD)
        ldi r14, 0x0002
        sub r15, r15, r14       ; 0x03-2=1 (C=1); if bus were dominant
                                ; 0x01-2=0xFFFF (C=0) -> fix path adds back
        jmp rone_ok, c
        add r15, r15, r14       ; 0xFFFF+2 = 1
rone_ok:
        pmask 0x01              ; pin ops touch pin0 (TXD) only
        pdir 0x01               ; TXD out, RXD (pin1) in
        xor r0, r0, r0          ; r0 = 0
        ldi r12, 0x8B32         ; CRC poly 0x4599, left-aligned
        ldi r14, 0x0004
        add r14, r14, r15       ; r14 = 5 (stuff threshold)

; ---- host command loop -------------------------------------------------------
cmd_loop:
        jmp cmd_have, rxne
        jmp cmd_loop
cmd_have:
        pull r6                 ; cmd word
        cmp r6, r15             ; 0x0001?
        jmp do_tx, z
        add r2, r15, r15        ; r2 = 2
        cmp r6, r2              ; 0x0002?
        jmp do_arb, z
        ldi r2, 0x0100
        sub r2, r2, r15         ; r2 = 0xFF
        cmp r6, r2              ; 0x00FF = halt?
        jmp do_hlt, z
        jmp push_ffff           ; unknown cmd
do_hlt:
        hlt
push_ffff:
        ldi r4, 0xFFFE
        add r4, r4, r15         ; r4 = 0xFFFF
        push r4
        evt 0
        jmp cmd_loop

; ---- wait_rx: block until RX FIFO non-empty (RACE FIX pattern) ----------------
wait_rx:
        jmp wait_rx_done, rxne
        jmp wait_rx
wait_rx_done:
        ret

; ---- 0x0001: pull ID -> r11, DLC -> r13 --------------------------------------
do_tx:
        call wait_rx
        pull r11                ; ID word
        call wait_rx
        pull r13                ; DLC word (raw, 0..2)
        ldi r2, 0x0002
        add r2, r2, r15         ; r2 = 3
        sub r4, r13, r2         ; C=1 iff DLC >= 3 (i.e. DLC > cap)
        jmp dlc_big, c
        jmp pull_data
do_arb:
        call wait_rx
        pull r11                ; ID word
        xor r13, r13, r13       ; DLC = 0
        jmp pull_data

; DLC > 2: consume + discard DLC words, report 0xFFFF
dlc_big:
        mov r7, r13             ; words to discard
dlc_big_loop:
        call wait_rx
        pull r4                 ; discard
        djnz r7, dlc_big_loop
        jmp push_ffff

; ---- pull data bytes into sreg stash (b0 -> EDGE_MASK, b1 -> EDGE_CFG0) ------
pull_data:
        cmp r13, r0
        jmp frame, z            ; DLC == 0
        call wait_rx
        pull r4
        msr r4, EDGE_MASK       ; b0
        sub r2, r13, r15        ; DLC-1: == 0 iff DLC == 1
        jmp frame, z
        call wait_rx
        pull r4
        msr r4, EDGE_CFG0       ; b1

; ---- frame setup (NOT timing-critical: all before SOF) ------------------------
frame:
        mov r6, r13             ; r6 = raw DLC (setup temp)
        xor r13, r13, r13       ; data stream = 0
        cmp r6, r0
        jmp hi_done, z
        mrs r4, EDGE_MASK       ; b0
        call align8             ; r4 = byte << 8
        or r13, r13, r4
        ldi r2, 0x0002
        cmp r6, r2
        jmp hi_done, z          ; DLC == 1
        mrs r4, EDGE_CFG0       ; b1
        call align8
        or r13, r13, r4
hi_done:
        ; revDLC (bit-reversed DLC nibble, for the DLC loop's LSB extractor)
        mov r4, r6
        xor r2, r2, r2
        ldi r7, 0x0004
rev_loop:
        shr r4, r4, r15         ; C = next DLC bit, LSB first (test C
                                ; BEFORE any other shift clobbers it)
        jmp rev_set, c
        shl r2, r2, r15         ; rev <<= 1, bit = 0
        jmp rev_next
rev_set:
        shl r2, r2, r15         ; rev <<= 1
        or r2, r2, r15          ; bit = 1
rev_next:
        djnz r7, rev_loop
        msr r2, EDGE_CFG0       ; revDLC (b1 stash consumed)
        mov r2, r6
        add r2, r2, r2
        add r2, r2, r2
        add r2, r2, r2          ; r2 = total data bits = DLC*8
        msr r2, EDGE_CFG1
        ldi r2, 0x000E
        add r2, r2, r15         ; 15
        msr r2, WMARK           ; CRC bit count for both CRC entries
        ; ID align: r1 = ID << 5
        mov r1, r11
        ldi r2, 0x0004
        add r2, r2, r15         ; 5
id_align:
        shl r1, r1, r15
        djnz r2, id_align
        xor r8, r8, r8          ; CRC = 0
        xor r9, r9, r9          ; run = 0
        xor r11, r11, r11       ; arb_lost = 0
        ; r5 = crc_en(1) | skip-data flag (2) if DLC == 0
        mov r5, r15
        cmp r6, r0
        jmp sof, nz
        add r5, r5, r15
        add r5, r5, r15         ; r5 = 3 (crc on, skip data)

; ---- SOF (dominant, crc_en=1, arb_en=1) ---------------------------------------
sof:
        xor r4, r4, r4          ; bit = 0
        mov r6, r15             ; arb_en = 1
        call send_bit
        sleep 3                 ; SOF->ID entry: sleep3(4)+ldi+add+extract = 10
        ldi r7, 0x000A
        add r7, r7, r15         ; 11 ID bits

; ---- ID field loop (arb check after every bit) --------------------------------
; iteration inter = arbcheck(2)+bottom pad sleep2(3)+djnz(1)+extract(4) = 10
; (pad at bottom; ID exit pays it and RTR's setup is sized to compensate)
id_loop:
        shl r1, r1, r15         ; C = next ID bit
        jmp id_b1, c
        ldi r4, 0x0000
        jmp id_send
id_b1:
        mov r4, r15
        mov r0, r0
id_send:
        call send_bit
        cmp r11, r0             ; arbitration lost?
        jmp abort, nz
        sleep 2
        djnz r7, id_loop

; ---- RTR / IDE / r0 (all dominant 0, crc_en via r5, arb_en=0) -----------------
; ID-exit -> RTR inter = arbcheck(2)+sleep2(3)+djnz(1)+setup(4) = 10;
; single->single inter = setup(10).
        xor r4, r4, r4          ; RTR = 0
        xor r6, r6, r6          ; arb_en = 0
        sleep 1                 ; RTR setup = xor+xor+sleep1(2) = 4
        call send_bit           ; RTR
        xor r4, r4, r4          ; IDE = 0
        sleep 8                 ; setup: xor(1)+sleep8(9) = 10
        call send_bit           ; IDE
        xor r4, r4, r4          ; r0 = 0
        sleep 8
        call send_bit           ; r0

; ---- DLC field (4 bits, LSB-extractor over revDLC in r13) ---------------------
; entry: stream moves r13->r1, revDLC loaded into r13.
; entry inter = mov(1)+mrs(1)+ldi(1)+sleep1(2)+jmp(1)+extract(4) = 10;
; iteration inter = djnz(1)+top pad sleep4(5)+extract(4) = 10 (entries
; jump to dlc_loop, skipping the pad).
        mov r1, r13             ; data stream -> r1 (ready for data field)
        mrs r13, EDGE_CFG0      ; r13 = revDLC (LSB = first DLC bit)
        ldi r7, 0x0004
        sleep 1
        jmp dlc_loop
dlc_loop_pad:
        sleep 4
dlc_loop:
        mov r2, r13
        and r2, r2, r15         ; bit = LSB
        mov r4, r2
        shr r13, r13, r15       ; advance
        call send_bit
        djnz r7, dlc_loop_pad
        ; DLC-loop exit: test r5 skip flag (r5-1 == 0 iff DLC>0)
        sub r2, r5, r15
        jmp data_entry, z
        ; skip data -> CRC entry: inter = djnz(1)+sub(1)+jmp(1)+xor(1)
        ; +mrs(1)+jmp(1)+extract(4) = 10
        xor r5, r5, r5          ; crc_en = 0
        mrs r7, WMARK           ; 15
        jmp crc_loop

; ---- data field entry ----------------------------------------------------------
; entry inter = djnz(1)+sub(1)+jmp(1)+mrs(1)+sleep0(1)+jmp(1)+extract(4) = 10
data_entry:
        mrs r7, EDGE_CFG1       ; total bits (stream already in r1)
        sleep 0
        jmp data_loop

; ---- data field loop ------------------------------------------------------------
; iteration inter = djnz(1)+top pad sleep4(5)+extract(4) = 10
data_loop_pad:
        sleep 4
data_loop:
        shl r1, r1, r15
        jmp dat_b1, c
        ldi r4, 0x0000
        jmp dat_send
dat_b1:
        mov r4, r15
        mov r0, r0
dat_send:
        call send_bit
        djnz r7, data_loop_pad
        ; data exit -> CRC entry: inter = djnz(1)+xor(1)+mrs(1)+sleep1(2)
        ; +jmp(1)+extract(4) = 10
        xor r5, r5, r5          ; crc_en = 0
        mrs r7, WMARK           ; 15
        sleep 1
        jmp crc_loop

; ---- CRC field (15 bits MSB-first from aligned crc in r8, crc_en=0) -----------
; iteration inter = djnz(1)+top pad sleep4(5)+extract(4) = 10
crc_loop_pad:
        sleep 4
crc_loop:
        shl r8, r8, r15         ; C = next CRC bit (bit15 first)
        jmp crc_b1, c
        ldi r4, 0x0000
        jmp crc_send
crc_b1:
        mov r4, r15
        mov r0, r0
crc_send:
        call send_bit
        djnz r7, crc_loop_pad

; ---- CRC delimiter / ACK slot / ACK delimiter / EOF+IFS (direct cell calls) ---
; cell-direct period: (R-1) + ret_sb(1) + gap + call(1) = 50 (first gap),
; then (R-1) + gap + call(1) = 50; R=30.
        mov r4, r15             ; CRC delimiter = recessive
        sleep 16                ; CRC->delim gap: djnz(1)+mov(1)+sleep16(17) = 19
        call cell               ; CRC delim
        mov r4, r15             ; ACK slot: drive recessive, sample bus
        sleep 18                ; delim->ACK gap: mov(1)+sleep18(19) = 20
        call cell               ; ACK slot -> r3 = bus sample
        mov r13, r3             ; status = sample (0=ACK dominant, 1=none)
        mov r4, r15             ; ACK delimiter = recessive
        sleep 17                ; ACK->delim gap: mov(1)+mov(1)+sleep17(18) = 20
        call cell               ; ACK delim
        mov r4, r15             ; EOF+IFS: 10 recessive cells
        sleep 18                ; delim->EOF gap: mov(1)+sleep18(19) = 20
        ldi r7, 0x000A          ; 10
eof_loop:
        call cell
        sleep 18                ; EOF cell gap: sleep18(19)+djnz(1) = 20
        djnz r7, eof_loop

; ---- report status --------------------------------------------------------------
        push r13                ; 0 = ACK, 1 = no ACK
        evt 0
        jmp cmd_loop

; ---- arbitration lost -----------------------------------------------------------
abort:
        pset 0x01               ; TXD recessive (already is; make it explicit)
        ldi r4, 0xFFA0
        push r4                 ; 0xFFA0
        evt 0
        jmp cmd_loop

; =============================================================================
; align8: r4 = (r4 & 0xFF) << 8, via 8 shl (high bits shift out). Clobbers r2.
; Called only in frame setup (not timing-critical). Returns via ret.
; =============================================================================
align8:
        ldi r2, 0x0008
al8_loop:
        shl r4, r4, r15
        djnz r2, al8_loop
        ret

; =============================================================================
; send_bit: send one DESTUFFED bit (r4), with stuff insertion.
;   in:  r4=bit, r5=crc flag pack (!=0 = on), r6=arb_en
;   Stuff rule: if run==5, first send a stuff cell (bit=~last, crc_en=0),
;   then the real bit. Entry paths cycle-equalized (8 cycles from
;   call send_bit to call cell either way); stuff->data gap padded to
;   the normal period. Period (psetr->psetr) = (R-1) + ret_sb(1) +
;   I(10) + call_sb(1) + entry(8) + call_cell(1) = R + 20 = 50, R=30.
; =============================================================================
send_bit:
        msr r4, VALUE           ; stash destuffed bit
        cmp r9, r14             ; run == 5?
        jmp sb_main, nz
        msr r5, MASK            ; stash crc flag pack
        mov r4, r10
        xor r4, r4, r15         ; stuff bit = ~last
        xor r5, r5, r5          ; stuff bits are not CRC'd
        mov r0, r0              ; entry pad (stuff entry = 8 cycles)
        call cell               ; send stuff bit (own 50-cycle cell)
        mrs r5, MASK            ; restore crc flag pack
        mrs r4, VALUE           ; restore destuffed bit
        sleep 16                ; stuff->data gap: mrs+mrs+sleep16(17)+jmp = 20
        jmp sb_cell
sb_main:
        sleep 4                 ; entry pad (5c): msr+cmp+jmp+sleep4 = 8
sb_cell:
        call cell
        ret

; =============================================================================
; cell: send one RAW bit for exactly 30 cycles (call->ret), psetr at cycle 1.
;   in:  r4=bit (0/1), r5=crc flag pack (!=0 = CRC on), r6=arb_en
;   out: r3 = sampled bus bit (RXD, 0/1); r11 |= arb_en & bit & ~sample
;   updates: r9/r10 (run/last), r8 (CRC if enabled)
;   clobbers r2, r3. Sample: PGET at cell cycle 20 (sync-effective ~18).
;   Cycle count (call->ret): call1 + psetr1 + run5 + gate12 +
;   sleep2(3) + pget1 + shr1 + and1 + arb4 + ret1 = 30.
; =============================================================================
cell:
        psetr r4                ; drive TXD = bit (commit end of this cycle)
        cmp r4, r10             ; run update: bit == last?
        jmp cell_same, z
        mov r9, r15             ; run = 1
        mov r10, r4             ; last = bit
        jmp cell_rd
cell_same:
        add r9, r9, r15         ; run++
        sleep 1                 ; pad 2c (path equalization)
cell_rd:
        cmp r5, r0              ; CRC gate (r5 != 0 = on)
        jmp cell_nc, z
        mov r2, r8              ; fb = top(crc) ^ bit
        shl r2, r2, r15         ; C = crc bit15 (aligned MSB)
        jmp cell_fb1, c
        mov r2, r4              ; top=0: fb = bit
        jmp cell_fbd
cell_fb1:
        xor r2, r4, r15         ; top=1: fb = ~bit
        mov r0, r0              ; pad
cell_fbd:
        shl r8, r8, r15         ; crc <<= 1
        sub r2, r0, r2          ; fb ? 0xFFFF : 0
        and r2, r2, r12         ; & poly (0x8B32)
        xor r8, r8, r2          ; crc ^= poly if fb
        jmp cell_cd
cell_nc:
        sleep 9                 ; 10c pad (gate path equalization: 2+10=12)
cell_cd:
        sleep 2                 ; to sample point (cycle 20)
        pget r3                 ; sample bus (2-FF sync)
        shr r3, r3, r15         ; RXD is pin1 -> bit0
        and r3, r3, r15         ; r3 = bus bit (0/1)
        xor r2, r3, r15         ; arb: lost |= arb_en & sent & ~sample
        and r2, r2, r4
        and r2, r2, r6
        or r11, r11, r2
        ret
