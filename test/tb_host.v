// tb_host.v — Worker C self-check testbench (NOT for synthesis).
// Host bit-bang model framing commands on hp_rx and checking responses on
// hp_tx; exercises PROG LOAD, VERIFY_IMEM readback, GO (+RUN-restart pulse),
// HALT_REQ routing, FIFO pack/unpack + sticky/never-stall behavior, and
// RD_TRACE against a stub observer.
// [AMD-B] Worker D: updated for the amended host contract (VERIFY_IMEM
// ACKs with readback data; RD_STATUS bits 5/0 live; HALT_REQ drives
// halt_req; GO in RUN issues a 2-cycle prog_mode pulse).
`default_nettype none
`timescale 1ns / 1ps

module tb_host;

    reg clk = 0;
    always #10 clk = ~clk;  // 50 MHz

    reg rst_n = 0;
    reg ena = 1;
    reg hp_rx = 1;
    wire hp_tx;

    // PE FIFO side
    reg  [15:0] tx_data = 0;
    reg         tx_push = 0;
    wire        tx_full;
    wire [15:0] rx_data;
    reg         rx_pull = 0;
    wire        rx_empty;

    // events
    reg [3:0] evt_code = 0;
    reg       evt_pulse = 0;

    // loader
    wire        prog_mode;
    wire [8:0]  prog_addr;
    wire [31:0] prog_din;
    wire        prog_wen;
    wire        prog_ren;                      // [AMD-B]
    wire [31:0] prog_dout;                     // [AMD-B] TB stub IMEM model
    assign prog_dout = {8'hA5, 15'h0000, prog_addr};
    wire        halt_req;                      // [AMD-B]
    wire        tx_empty_w, rx_full_w;         // [AMD-B]

    // trace port (stub observer)
    wire       host_rd_en;
    wire [9:0] host_rd_addr;
    reg  [7:0] host_rd_data = 0;
    reg        host_rd_ack = 0;

    // status
    reg       pe_running = 0;
    reg       pe_halted = 0;
    reg       timeout_sticky = 0;              // [AMD-B] -> RD_STATUS bit5
    reg       config_err = 0;                  // [AMD-B] -> RD_STATUS bit0
    // [AMD-B] GO-pulse monitor: set while a GO-in-RUN frame is in flight
    reg       go_pulse_armed = 0, go_pulse_seen = 0;
    reg [7:0] obs_ptr = 0;
    reg       trace_full = 0;
    reg       trace_wm = 0;

    integer T_host = 100;  // host bit period in core clocks (autobaud target)
    integer fail = 0;
    integer nchecks = 0;

    tt_um_pemu_host dut (
        .clk(clk), .rst_n(rst_n), .ena(ena),
        .hp_rx(hp_rx), .hp_tx(hp_tx),
        .tx_data(tx_data), .tx_push(tx_push), .tx_full(tx_full),
        .rx_data(rx_data), .rx_pull(rx_pull), .rx_empty(rx_empty),
        .evt_code(evt_code), .evt_pulse(evt_pulse),
        .prog_mode(prog_mode), .prog_addr(prog_addr),
        .prog_din(prog_din), .prog_wen(prog_wen),
        .prog_ren(prog_ren), .prog_dout(prog_dout),
        .host_rd_en(host_rd_en), .host_rd_addr(host_rd_addr),
        .host_rd_data(host_rd_data), .host_rd_ack(host_rd_ack),
        .pe_running(pe_running), .pe_halted(pe_halted),
        .obs_ptr(obs_ptr), .trace_full(trace_full), .trace_wm(trace_wm),
        .halt_req(halt_req), .tx_empty(tx_empty_w), .rx_full(rx_full_w),
        .timeout_sticky(timeout_sticky), .config_err(config_err)
    );

    // [AMD-B] GO-pulse monitor
    always @(posedge clk) if (go_pulse_armed && prog_mode) go_pulse_seen <= 1'b1;

    // ------------------------------------------------------------------
    // Stub observer: 2-cycle ack; entry i byte j of addr=5*i+j:
    //   ts = 32'h00000100 + i, pins = i[7:0], MSB-first
    // ------------------------------------------------------------------
    function [7:0] entry_byte(input [9:0] addr);
        reg [7:0] i; reg [2:0] j; reg [31:0] ts;
        begin
            i = addr / 5; j = addr % 5; ts = 32'h00000100 + i;
            case (j)
                0: entry_byte = ts[31:24];
                1: entry_byte = ts[23:16];
                2: entry_byte = ts[15:8];
                3: entry_byte = ts[7:0];
                default: entry_byte = i;
            endcase
        end
    endfunction

    reg obs_en_d = 0, obs_armed = 0;
    reg [1:0] obs_cnt = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            obs_en_d <= 0; obs_armed <= 0; obs_cnt <= 0; host_rd_ack <= 0;
        end else begin
            obs_en_d <= host_rd_en;
            host_rd_ack <= 1'b0;
            if (host_rd_en && !obs_en_d) begin obs_armed <= 1; obs_cnt <= 0; end
            else if (obs_armed) begin
                if (obs_cnt == 2'd2) begin
                    host_rd_data <= entry_byte(host_rd_addr);
                    host_rd_ack <= 1;
                    obs_armed <= 0;
                end else obs_cnt <= obs_cnt + 2'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Host bit-bang tasks (changes driven on negedge for setup margin)
    // ------------------------------------------------------------------
    task send_level(input v, input integer nclks);
        begin
            @(negedge clk); hp_rx = v;
            repeat (nclks) @(posedge clk);
        end
    endtask

    task send_byte(input [7:0] b);
        integer k;
        begin
            send_level(0, T_host);            // start
            for (k = 0; k < 8; k = k + 1) send_level(b[k], T_host);
            send_level(1, T_host);            // stop
        end
    endtask

    // Always-on host RX monitor: catches every DUT byte even if the DUT
    // starts transmitting while send_frame is still holding its last
    // stop bit. Bytes are queued in arrival order; recv_byte pops.
    reg [7:0] rx_queue [0:63];
    integer rx_qw = 0, rx_qr = 0;
    always begin
        reg [7:0] bmon;
        integer kmon;
        @(negedge hp_tx);
        #(T_host * 20 * 1.5);
        for (kmon = 0; kmon < 8; kmon = kmon + 1) begin
            bmon[kmon] = hp_tx;
            #(T_host * 20);
        end
        // NOTE: no trailing stop-bit wait; re-arm at t0+9.5*T must precede
        // the next start bit at t0+10*t_bit (t_bit < T_host always).
        rx_queue[rx_qw[5:0]] = bmon;
        rx_qw = rx_qw + 1;
    end

    task recv_byte(output reg [7:0] b);
        integer to;
        begin
            to = 0;
            while (rx_qw == rx_qr && to < 30000) begin #1000; to = to + 1; end
            if (rx_qw == rx_qr) begin
                $display("FAIL: recv_byte timeout waiting for DUT byte");
                fail = 1; b = 8'hxx;
            end else begin
                b = rx_queue[rx_qr[5:0]];
                rx_qr = rx_qr + 1;
            end
        end
    endtask

    reg [7:0] ack;
    reg [7:0] fdata [0:255];
    task expect_ack(input [7:0] want, input [255:0] what);
        begin
            recv_byte(ack); nchecks = nchecks + 1;
            if (ack !== want) begin
                $display("FAIL: %0s: ack=%02h want %02h", what, ack, want);
                fail = 1;
            end
        end
    endtask

    // frame: send CMD+LEN+data (data as packed byte array in a reg vector)
    task send_frame(input [7:0] cmd, input integer len);
        integer k;
        begin
            send_byte(cmd);
            send_byte(len[7:0]);
            for (k = 0; k < len; k = k + 1) send_byte(fdata[k]);
        end
    endtask

    // ------------------------------------------------------------------
    // prog loader monitor
    // ------------------------------------------------------------------
    reg [8:0]  seen_addr [0:511];
    reg [31:0] seen_data [0:255];
    integer seen_n = 0;
    integer seen_mark = 0;
    always @(posedge clk) begin
        if (prog_wen) begin
            seen_addr[seen_n] = prog_addr;
            seen_data[seen_n] = prog_din;
            seen_n = seen_n + 1;
        end
    end

    task check(input integer cond, input [255:0] what);
        begin
            nchecks = nchecks + 1;
            if (!cond) begin $display("FAIL: %0s", what); fail = 1; end
        end
    endtask

    // PE-side FIFO helpers
    task pe_push(input [15:0] w);
        begin
            @(negedge clk); tx_data = w; tx_push = 1;
            @(negedge clk); tx_push = 0;
        end
    endtask
    task pe_pull(output reg [15:0] w);
        begin
            w = rx_data;
            @(negedge clk); rx_pull = 1;
            @(negedge clk); rx_pull = 0;
        end
    endtask

    reg [7:0] rb;
    reg [15:0] rw;
    integer i;

    initial begin
        $dumpfile("/tmp/host_tb.vcd"); $dumpvars(0, tb_host);

        // ---- reset ----
        #100; rst_n = 1;
        repeat (10) @(posedge clk);
        check(prog_mode === 1'b1, "prog_mode=1 after reset");
        check(hp_tx === 1'b1, "hp_tx idle high");

        // ---- autobaud sync at T=100 ----
        send_byte(8'h00);  // 0x00 NOP = autobaud sync
        repeat (20) @(posedge clk);

        // ---- 3. RD_STATUS in PROG ----
        fdata[0] = 8'h00;
        send_frame(8'h08, 0);
        expect_ack(8'hA5, "RD_STATUS ack");
        recv_byte(rb); check(rb === 8'h10, "RD_STATUS=0x10 (tx_empty)");
        // [AMD-B] TIMEOUT / CONFIG_ERR bits now live
        timeout_sticky = 1;
        send_frame(8'h08, 0);
        expect_ack(8'hA5, "RD_STATUS timeout ack");
        recv_byte(rb); check(rb === 8'h30, "RD_STATUS=0x30 (timeout_sticky)");
        config_err = 1;
        send_frame(8'h08, 0);
        expect_ack(8'hA5, "RD_STATUS cfgerr ack");
        recv_byte(rb); check(rb === 8'h31, "RD_STATUS=0x31 (config_err)");
        timeout_sticky = 0; config_err = 0;

        // ---- 4. WR_RXFIFO in PROG -> NACK_ERR ----
        fdata[0] = 8'hAA; fdata[1] = 8'hBB;
        send_frame(8'h05, 2);
        expect_ack(8'h5B, "WR_RXFIFO in PROG NACK");

        // ---- 5. LOAD_IMEM 4 words at addr 0 ----
        seen_n = 0;
        // addr=0x0000, DEADBEEF 12345678 00000000 FFFFFFFF
        fdata[0]=8'h00; fdata[1]=8'h00;
        fdata[2]=8'hDE; fdata[3]=8'hAD; fdata[4]=8'hBE; fdata[5]=8'hEF;
        fdata[6]=8'h12; fdata[7]=8'h34; fdata[8]=8'h56; fdata[9]=8'h78;
        fdata[10]=8'h00; fdata[11]=8'h00; fdata[12]=8'h00; fdata[13]=8'h00;
        fdata[14]=8'hFF; fdata[15]=8'hFF; fdata[16]=8'hFF; fdata[17]=8'hFF;
        send_frame(8'h01, 18);
        expect_ack(8'hA5, "LOAD_IMEM ack");
        repeat (5) @(posedge clk);
        check(seen_n === 4, "LOAD_IMEM 4 prog_wen pulses");
        check(seen_addr[0]===8'h00 && seen_data[0]===32'hDEADBEEF, "LOAD word0");
        check(seen_addr[1]===8'h01 && seen_data[1]===32'h12345678, "LOAD word1");
        check(seen_addr[2]===8'h02 && seen_data[2]===32'h00000000, "LOAD word2");
        check(seen_addr[3]===8'h03 && seen_data[3]===32'hFFFFFFFF, "LOAD word3");

        // ---- 6. LOAD_IMEM errors ----
        fdata[0]=8'h00; fdata[1]=8'h00; fdata[2]=8'hFF;
        send_frame(8'h01, 3); expect_ack(8'h5B, "LOAD bad len NACK");
        // [IMEM-512] addr_hi=1 is legal now: addr=256, 1 word -> ACK
        fdata[0]=8'h01; fdata[1]=8'h00;  // addr=256 (upper bank)
        fdata[2]=8'hCA; fdata[3]=8'hFE; fdata[4]=8'hBA; fdata[5]=8'hBE;
        send_frame(8'h01, 6); expect_ack(8'hA5, "LOAD addr=256 ACK (upper)");
        check(seen_n === 5, "LOAD upper: +1 prog_wen pulse");
        check(seen_addr[4]===9'd256 && seen_data[4]===32'hCAFEBABE, "LOAD word @256");
        // [IMEM-512] span boundary 256->512: addr=255, 2 words fits
        fdata[0]=8'h00; fdata[1]=8'hFF;  // addr=255, 2 words -> 257 <= 512
        for (i=2;i<10;i=i+1) fdata[i]=8'h00;
        send_frame(8'h01, 10); expect_ack(8'hA5, "LOAD 255+2 ACK (fits 512)");
        check(seen_n === 7, "LOAD 255+2: +2 prog_wen pulses");
        check(seen_addr[5]===9'd255 && seen_addr[6]===9'd256, "LOAD words @255,256");

        // ---- 7. unsupported / unknown / bad-len ----
        // [AMD-B] VERIFY_IMEM: addr=2, nwords=2 -> ACK + 8 bytes MSB-first.
        // TB stub IMEM returns {A5,00,00,addr}.
        fdata[0]=8'h00; fdata[1]=8'h02; fdata[2]=8'h02;
        send_frame(8'h02, 3); expect_ack(8'hA5, "VERIFY_IMEM ack");
        recv_byte(rb); check(rb===8'hA5,"vrf w2 b3"); recv_byte(rb); check(rb===8'h00,"vrf w2 b2");
        recv_byte(rb); check(rb===8'h00,"vrf w2 b1"); recv_byte(rb); check(rb===8'h02,"vrf w2 b0");
        recv_byte(rb); check(rb===8'hA5,"vrf w3 b3"); recv_byte(rb); check(rb===8'h00,"vrf w3 b2");
        recv_byte(rb); check(rb===8'h00,"vrf w3 b1"); recv_byte(rb); check(rb===8'h03,"vrf w3 b0");
        // nwords=0 -> ACK_OK, no data bytes
        fdata[0]=8'h00; fdata[1]=8'h05; fdata[2]=8'h00;
        send_frame(8'h02, 3); expect_ack(8'hA5, "VERIFY_IMEM nwords=0 ack");
        // [IMEM-512] addr_hi=1 is legal now: addr=256, nwords=1 -> ACK.
        // TB stub word for 256 = 0xA5000100 (bytes A5 00 01 00).
        fdata[0]=8'h01; fdata[1]=8'h00; fdata[2]=8'h01;
        send_frame(8'h02, 3); expect_ack(8'hA5, "VERIFY_IMEM addr=256 ack");
        recv_byte(rb); check(rb===8'hA5,"vrf @256 b3"); recv_byte(rb); check(rb===8'h00,"vrf @256 b2");
        recv_byte(rb); check(rb===8'h01,"vrf @256 b1"); recv_byte(rb); check(rb===8'h00,"vrf @256 b0");
        // [IMEM-512] span boundary moved: addr=255, nwords=2 fits -> ACK.
        // TB stub words: @255 = 0xA50000FF, @256 = 0xA5000100.
        fdata[0]=8'h00; fdata[1]=8'hFF; fdata[2]=8'h02;
        send_frame(8'h02, 3); expect_ack(8'hA5, "VERIFY_IMEM 255+2 ack");
        recv_byte(rb); check(rb===8'hA5,"vrf @255 b3"); recv_byte(rb); check(rb===8'h00,"vrf @255 b2");
        recv_byte(rb); check(rb===8'h00,"vrf @255 b1"); recv_byte(rb); check(rb===8'hFF,"vrf @255 b0");
        recv_byte(rb); check(rb===8'hA5,"vrf @256b b3"); recv_byte(rb); check(rb===8'h00,"vrf @256b b2");
        recv_byte(rb); check(rb===8'h01,"vrf @256b b1"); recv_byte(rb); check(rb===8'h00,"vrf @256b b0");
        // bad LEN -> NACK_ERR
        fdata[0]=8'h00; fdata[1]=8'h00;
        send_frame(8'h02, 2); expect_ack(8'h5B, "VERIFY_IMEM bad LEN NACK");
        // ---- 7b. [IMEM-512] upper-bank LOAD+VERIFY, past-512 NACKs ----
        // LOAD 3 words at base 300 (0x012C)
        seen_mark = seen_n;
        fdata[0]=8'h01; fdata[1]=8'h2C;  // addr=300
        fdata[2]=8'h11; fdata[3]=8'h22; fdata[4]=8'h33; fdata[5]=8'h44;
        fdata[6]=8'h55; fdata[7]=8'h66; fdata[8]=8'h77; fdata[9]=8'h88;
        fdata[10]=8'h99; fdata[11]=8'hAA; fdata[12]=8'hBB; fdata[13]=8'hCC;
        send_frame(8'h01, 14); expect_ack(8'hA5, "LOAD @300 ack (upper bank)");
        check(seen_n === seen_mark + 3, "LOAD @300: 3 prog_wen pulses");
        check(seen_addr[seen_mark]===9'd300 && seen_data[seen_mark]===32'h11223344, "LOAD @300 word0");
        check(seen_addr[seen_mark+1]===9'd301 && seen_data[seen_mark+1]===32'h55667788, "LOAD @301 word1");
        check(seen_addr[seen_mark+2]===9'd302 && seen_data[seen_mark+2]===32'h99AABBCC, "LOAD @302 word2");
        // VERIFY base 300, 3 words (stub words 0xA500012C/2D/2E)
        fdata[0]=8'h01; fdata[1]=8'h2C; fdata[2]=8'h03;
        send_frame(8'h02, 3); expect_ack(8'hA5, "VERIFY @300 ack (upper)");
        recv_byte(rb); check(rb===8'hA5,"vrf @300 b3"); recv_byte(rb); check(rb===8'h00,"vrf @300 b2");
        recv_byte(rb); check(rb===8'h01,"vrf @300 b1"); recv_byte(rb); check(rb===8'h2C,"vrf @300 b0");
        recv_byte(rb); check(rb===8'hA5,"vrf @301 b3"); recv_byte(rb); check(rb===8'h00,"vrf @301 b2");
        recv_byte(rb); check(rb===8'h01,"vrf @301 b1"); recv_byte(rb); check(rb===8'h2D,"vrf @301 b0");
        recv_byte(rb); check(rb===8'hA5,"vrf @302 b3"); recv_byte(rb); check(rb===8'h00,"vrf @302 b2");
        recv_byte(rb); check(rb===8'h01,"vrf @302 b1"); recv_byte(rb); check(rb===8'h2E,"vrf @302 b0");
        // LOAD spanning past 512 (base 510 + 3 words = 513) -> NACK_ERR
        fdata[0]=8'h01; fdata[1]=8'hFE;  // addr=510
        for (i=2;i<14;i=i+1) fdata[i]=8'h00;
        send_frame(8'h01, 14); expect_ack(8'h5B, "LOAD 510+3 past512 NACK");
        // LOAD at base 512 -> NACK_ERR
        fdata[0]=8'h02; fdata[1]=8'h00;  // addr=512
        fdata[2]=8'h00; fdata[3]=8'h00; fdata[4]=8'h00; fdata[5]=8'h00;
        send_frame(8'h01, 6); expect_ack(8'h5B, "LOAD @512 NACK");
        // VERIFY spanning past 512 (base 511 + 2 = 513) -> NACK_ERR
        fdata[0]=8'h01; fdata[1]=8'hFF; fdata[2]=8'h02;  // addr=511
        send_frame(8'h02, 3); expect_ack(8'h5B, "VERIFY 511+2 past512 NACK");
        // VERIFY at base 512 -> NACK_ERR
        fdata[0]=8'h02; fdata[1]=8'h00; fdata[2]=8'h01;  // addr=512
        send_frame(8'h02, 3); expect_ack(8'h5B, "VERIFY @512 NACK");
        fdata[0]=8'h10; fdata[1]=8'h01;
        send_frame(8'h03, 2); expect_ack(8'h5B, "WR_CFG NACK (no cfg iface)");
        fdata[0]=8'h10;
        send_frame(8'h04, 1); expect_ack(8'h5B, "RD_CFG NACK (no cfg iface)");
        fdata[0]=8'hDE; fdata[1]=8'hAD;
        send_frame(8'hF0, 2); expect_ack(8'h5B, "unknown CMD NACK");
        fdata[0]=8'h00;
        send_frame(8'h08, 1); expect_ack(8'h5B, "RD_STATUS bad LEN NACK");

        // ---- 8/9. GO ----
        send_frame(8'h09, 0);
        expect_ack(8'hA5, "GO ack");
        repeat (5) @(posedge clk);
        check(prog_mode === 1'b0, "prog_mode=0 after GO");
        // [AMD-B] GO in RUN: 2-cycle prog_mode pulse (restart), still ACKs
        go_pulse_armed = 1; go_pulse_seen = 0;
        send_frame(8'h09, 0);
        expect_ack(8'hA5, "GO in RUN ack");
        go_pulse_armed = 0;
        check(go_pulse_seen === 1'b1, "GO in RUN: prog_mode pulsed");
        repeat (5) @(posedge clk);
        check(prog_mode === 1'b0, "prog_mode=0 after RUN GO pulse");

        // ---- 10. WR_RXFIFO odd byte count ----
        fdata[0]=8'h41; fdata[1]=8'h42; fdata[2]=8'h43;  // "ABC"
        send_frame(8'h05, 3);
        expect_ack(8'hA5, "WR_RXFIFO ack");
        check(rx_empty === 1'b0, "rx not empty after WR_RXFIFO");
        pe_pull(rw); check(rw === 16'h4142, "RX word0 = 0x4142");
        pe_pull(rw); check(rw === 16'h4300, "RX word1 = 0x4300 (odd pad)");
        check(rx_empty === 1'b1, "rx empty after drain");
        pe_pull(rw); check(rw === 16'h0000, "RX pull on empty -> 0 (never stalls)");

        // ---- 11. WR_RXFIFO all-or-nothing ----
        for (i=0;i<32;i=i+1) fdata[i]=i[7:0];
        send_frame(8'h05, 32);
        expect_ack(8'hA5, "WR_RXFIFO fill 16 words ack");
        fdata[0]=8'hAA; fdata[1]=8'hBB;
        send_frame(8'h05, 2);
        expect_ack(8'h5B, "WR_RXFIFO full -> NACK all-or-nothing");
        for (i=0;i<16;i=i+1) begin
            pe_pull(rw);
            check(rw === (((i*2)<<8) | (i*2+1)), "RX fill word check");
        end
        check(rx_empty === 1'b1, "rx empty after full drain");

        // ---- 12. TX FIFO: push, RD_TXFIFO, full/drop ----
        pe_push(16'h1111); pe_push(16'h2222); pe_push(16'h3333);
        check(tx_full === 1'b0, "tx not full at 3");
        fdata[0]=8'h06;
        send_frame(8'h06, 1);
        expect_ack(8'hA5, "RD_TXFIFO ack");
        recv_byte(rb); check(rb === 8'h06, "RD_TXFIFO ret_count=6");
        recv_byte(rb); check(rb===8'h11, "TX byte0"); recv_byte(rb); check(rb===8'h11, "TX byte1");
        recv_byte(rb); check(rb===8'h22, "TX byte2"); recv_byte(rb); check(rb===8'h22, "TX byte3");
        recv_byte(rb); check(rb===8'h33, "TX byte4"); recv_byte(rb); check(rb===8'h33, "TX byte5");
        // fill to full + overrun drop (never stalls)
        for (i=0;i<16;i=i+1) pe_push(16'h1000+i);
        check(tx_full === 1'b1, "tx_full at 16");
        pe_push(16'hBEEF);  // must drop, no stall
        check(tx_full === 1'b1, "tx still full after overrun push");
        fdata[0]=8'hFF;
        send_frame(8'h06, 1);
        expect_ack(8'hA5, "RD_TXFIFO drain ack");
        recv_byte(rb); check(rb === 8'd32, "ret_count=32");
        recv_byte(rb); check(rb===8'h10, "first drained byte 0x10 (BEEF dropped)");
        for (i=1;i<32;i=i+1) recv_byte(rb);
        // odd ret_count
        pe_push(16'hA55A);
        fdata[0]=8'h01;
        send_frame(8'h06, 1);
        expect_ack(8'hA5, "RD_TXFIFO odd ack");
        recv_byte(rb); check(rb===8'h01, "odd ret_count=1");
        recv_byte(rb); check(rb===8'hA5, "odd byte = hi only");
        // empty read
        fdata[0]=8'h0A;
        send_frame(8'h06, 1);
        expect_ack(8'hA5, "RD_TXFIFO empty ack");
        recv_byte(rb); check(rb===8'h00, "empty ret_count=0");

        // ---- 13. RD_TRACE round trip ----
        obs_ptr = 8'd5;
        fdata[0]=8'h01; fdata[1]=8'h03;  // start=1, count=3
        send_frame(8'h07, 2);
        expect_ack(8'hA5, "RD_TRACE ack");
        recv_byte(rb); check(rb===8'h03, "RD_TRACE ret=3");
        // entry1: ts=0x101 pins=0x01 ; entry2: 0x102/0x02 ; entry3: 0x103/0x03
        recv_byte(rb); check(rb===8'h00,"e1 ts[31:24]"); recv_byte(rb); check(rb===8'h00,"e1 ts[23:16]");
        recv_byte(rb); check(rb===8'h01,"e1 ts[15:8]");  recv_byte(rb); check(rb===8'h01,"e1 ts[7:0]");
        recv_byte(rb); check(rb===8'h01,"e1 pins");
        recv_byte(rb); check(rb===8'h00,"e2 ts[31:24]"); recv_byte(rb); check(rb===8'h00,"e2 ts[23:16]");
        recv_byte(rb); check(rb===8'h01,"e2 ts[15:8]");  recv_byte(rb); check(rb===8'h02,"e2 ts[7:0]");
        recv_byte(rb); check(rb===8'h02,"e2 pins");
        recv_byte(rb); check(rb===8'h00,"e3 ts[31:24]"); recv_byte(rb); check(rb===8'h00,"e3 ts[23:16]");
        recv_byte(rb); check(rb===8'h01,"e3 ts[15:8]");  recv_byte(rb); check(rb===8'h03,"e3 ts[7:0]");
        recv_byte(rb); check(rb===8'h03,"e3 pins");
        recv_byte(rb); check(rb===8'h05,"OBS_PTR=5");
        // count=0 pointer poll
        fdata[0]=8'h00; fdata[1]=8'h00;
        send_frame(8'h07, 2);
        expect_ack(8'hA5, "RD_TRACE poll ack");
        recv_byte(rb); check(rb===8'h00,"poll ret=0");
        recv_byte(rb); check(rb===8'h05,"poll ptr=5");
        // start >= ptr -> clamp
        fdata[0]=8'h09; fdata[1]=8'h04;
        send_frame(8'h07, 2);
        expect_ack(8'hA5, "RD_TRACE clamp ack");
        recv_byte(rb); check(rb===8'h00,"clamp ret=0");
        recv_byte(rb); check(rb===8'h05,"clamp ptr=5");
        // count>16 -> NACK
        fdata[0]=8'h00; fdata[1]=8'h11;
        send_frame(8'h07, 2);
        expect_ack(8'h5B, "RD_TRACE count>16 NACK");
        // start=0 count=16, ptr=5 -> ret=5
        fdata[0]=8'h00; fdata[1]=8'h10;
        send_frame(8'h07, 2);
        expect_ack(8'hA5, "RD_TRACE clamp2 ack");
        recv_byte(rb); check(rb===8'h05,"clamp2 ret=5");
        for (i=0;i<25;i=i+1) recv_byte(rb);
        recv_byte(rb); check(rb===8'h05,"clamp2 ptr=5");
        obs_ptr = 8'd0;

        // ---- 14. event capture ----
        @(negedge clk); evt_code = 4'd4; evt_pulse = 1;
        @(negedge clk); evt_pulse = 0;
        repeat (3) @(posedge clk);
        check(dut.evt_flags[4] === 1'b1, "evt_flags[4] captured");

        // ---- 15. RD_STATUS live bits ----
        pe_running = 1; trace_wm = 1; trace_full = 1;
        send_frame(8'h08, 0);
        expect_ack(8'hA5, "RD_STATUS live ack");
        recv_byte(rb); check(rb===8'h96, "RD_STATUS=0x96 (run,tx_empty,wm,full)");
        pe_running = 0; trace_wm = 0; trace_full = 0;

        // ---- 16. HALT_REQ accepted -> halt_req high (RUN) ----
        send_frame(8'h0A, 0);
        expect_ack(8'hA5, "HALT_REQ ack");
        repeat (3) @(posedge clk);
        check(halt_req === 1'b1, "halt_req=1 after HALT_REQ");
        // [AMD-B] VERIFY_IMEM in RUN -> NACK_ERR
        fdata[0]=8'h00; fdata[1]=8'h00; fdata[2]=8'h01;
        send_frame(8'h02, 3); expect_ack(8'h5B, "VERIFY_IMEM in RUN NACK");
        // [AMD-B] GO in RUN drops halt_req (+ pulse)
        go_pulse_armed = 1; go_pulse_seen = 0;
        send_frame(8'h09, 0);
        expect_ack(8'hA5, "GO drops halt_req ack");
        go_pulse_armed = 0;
        repeat (3) @(posedge clk);
        check(halt_req === 1'b0, "halt_req=0 after GO");
        check(go_pulse_seen === 1'b1, "GO pulse seen (halt_req test)");

        // ---- 17. ena re-entry to PROG ----
        @(negedge clk); ena = 0;
        repeat (5) @(posedge clk);
        check(prog_mode === 1'b1, "ena fall -> prog_mode=1");
        check(halt_req === 1'b0, "halt_req=0 in PROG");
        @(negedge clk); ena = 1;
        repeat (3) @(posedge clk);
        // [AMD-B] HALT_REQ in PROG -> NACK_ERR
        send_frame(8'h0A, 0);
        expect_ack(8'h5B, "HALT_REQ in PROG NACK");
        repeat (3) @(posedge clk);
        check(halt_req === 1'b0, "halt_req stays 0 (PROG NACK)");

        // ---- 18. autobaud at T=64 after reset ----
        rst_n = 0; #100; rst_n = 1;
        repeat (10) @(posedge clk);
        T_host = 64;
        send_byte(8'h00);
        repeat (20) @(posedge clk);
        send_frame(8'h08, 0);
        expect_ack(8'hA5, "RD_STATUS ack at T=64");
        recv_byte(rb); check(rb===8'h10, "RD_STATUS=0x10 at T=64");

        // ---- 19. FIFO occupancy: 15/16/17 pushes (TX direction) ----
        // Fill TX FIFO via PE side (tx_push), check full at 16, stays full at 17
        begin
            integer j;
            // Drain first
            repeat (20) @(posedge clk);
            for (j = 0; j < 15; j = j + 1) begin
                @(negedge clk); tx_data = j; tx_push = 1;
                @(posedge clk); #1; tx_push = 0;
            end
            repeat (2) @(posedge clk);
            check(tx_full === 1'b0, "TX FIFO: not full at 15");
            @(negedge clk); tx_data = 15; tx_push = 1;
            @(posedge clk); #1; tx_push = 0;
            repeat (2) @(posedge clk);
            check(tx_full === 1'b1, "TX FIFO: full at 16");
            @(negedge clk); tx_data = 16; tx_push = 1;
            @(posedge clk); #1; tx_push = 0;
            repeat (2) @(posedge clk);
            check(tx_full === 1'b1, "TX FIFO: stays full at 17th push (no overflow)");
        end

        // ---- 20. LOAD_IMEM: one word, zero words, odd length ----
        // One word (len=6: 2 hdr + 4 data)
        fdata[0]=8'h00; fdata[1]=8'h00; fdata[2]=8'hDE; fdata[3]=8'hAD;
        fdata[4]=8'hBE; fdata[5]=8'hEF;
        send_frame(8'h01, 6);
        expect_ack(8'hA5, "LOAD_IMEM one word ack");
        // Zero words (len=2: header only) - ACKed as no-op (not malformed)
        send_frame(8'h01, 2);
        expect_ack(8'hA5, "LOAD_IMEM zero words ACK (no-op)");
        // Odd length (len=5: malformed, not 2+4*N)
        fdata[0]=8'h00; fdata[1]=8'h00; fdata[2]=8'h11; fdata[3]=8'h22; fdata[4]=8'h33;
        send_frame(8'h01, 5);
        expect_ack(8'h5B, "LOAD_IMEM odd length NACK");

        // ---- 21. VERIFY_IMEM: one word, odd count ----
        fdata[0]=8'h00; fdata[1]=8'h00; fdata[2]=8'h01;
        send_frame(8'h02, 3);
        expect_ack(8'hA5, "VERIFY_IMEM one word ack");
        recv_byte(rb); // data byte 0
        recv_byte(rb); // data byte 1
        recv_byte(rb); // data byte 2
        recv_byte(rb); // data byte 3

        // ---- 22. UART framing error: bad stop bit dropped ----
        begin
            integer k;
            // Send byte with stop bit = 0 (framing error)
            @(negedge clk); hp_rx = 0; repeat (T_host) @(posedge clk); // start
            for (k = 0; k < 8; k = k + 1) begin
                @(negedge clk); hp_rx = 1; repeat (T_host) @(posedge clk);
            end
            @(negedge clk); hp_rx = 0; repeat (T_host) @(posedge clk); // bad stop (0)
            @(negedge clk); hp_rx = 1; repeat (T_host*2) @(posedge clk);
            // No ACK should arrive (framing error dropped)
            // (We verify by sending a good frame after and checking it works)
            send_frame(8'h08, 0);
            expect_ack(8'hA5, "RD_STATUS after framing error (recovered)");
            recv_byte(rb);
        end

        // ---- 23. Break: long low then recovery ----
        send_level(0, T_host*20);  // break: 20 bit-times low
        send_level(1, T_host*2);
        send_frame(8'h08, 0);
        expect_ack(8'hA5, "RD_STATUS after break (recovered)");
        recv_byte(rb);

        // ---- 24. Deep break: long idle (re-arm autobaud) then 131071+ low -> RX_BRK ----
        send_level(1, 70000);   // idle_cnt max -> sync_armed=1
        send_level(0, 131100);  // falling edge -> RX_SYNL, low_cnt max -> RX_BRK
        check(dut.rx_st === 3'd5, "RX_BRK reached after 131071-cycle low");
        send_level(1, 70000);   // release: RX_BRK->RX_IDLE; re-arm autobaud
        check(dut.rx_st === 3'd0, "RX_IDLE after deep break released");
        send_byte(8'h00);       // autobaud re-sync (t_bit was forced to 4096)
        send_frame(8'h08, 0);
        expect_ack(8'hA5, "RD_STATUS after deep break re-sync");
        recv_byte(rb);

        $display("done: %0d checks, %0s", nchecks, fail ? "FAIL" : "PASS");
        $finish;
    end

    // watchdog
    initial begin
        #50000000;
        $display("FAIL: watchdog timeout");
        $finish;
    end

endmodule
