// tb_top.v -- top-level integration bench (Worker D, NOT for synthesis).
// Instantiates tt_um_pemu + both PDK SRAM macros (functional models).
// Drives the host UART (autobaud + commands) and checks full-chip behavior.
//
// Pad model: uio_in = (uio_oe & uio_out) | TB drive; an output-driven pad
// reads back on the input path (physical TT pad behavior), so the PE's
// driven pins reach the observer's pin sampler.
//
// Phase A: HALT_REQ on an infinite loop (halt_test.hex).
// Phase B: top_smoke (top_smoke.hex): LOAD/VERIFY/WR_RXFIFO/GO, pin echo,
//          TX echo, RD_TRACE entries, RD_STATUS.
//
// UART bit period T=100 core clocks. First byte after reset/idle must be
// 0x00 (autobaud sync, consumed as NOP).
//
// SRAM models: the DUT instantiates the real PDK macro module names;
// compile test/sram_sim.v (functional models, no $stop/specify) INSTEAD of
// the PDK Verilog. Do NOT re-instantiate the macros at TB level -- the DUT
// already contains u_imem/u_tmem (double instantiation double-drives the
// dout nets).
//
// Compile (from repo root):
//   iverilog -g2012 -o /tmp/tb_top test/tb_top.v test/sram_sim.v \
//     src/tt_um_pemu.v src/tt_um_pemu_pe.v src/tt_um_pemu_observer.v \
//     src/tt_um_pemu_host.v
`default_nettype none
`timescale 1ns / 1ps

module tb_top;

    localparam T = 100;  // UART bit period in core clocks

    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg ena = 1;

    reg [7:0] ui_in = 8'hFF;   // ui_in[0] = host RX, idle high
    wire [7:0] uo_out;
    wire [7:0] uio_out, uio_oe;
    wire [7:0] uio_in;

    // Pad model: driven outputs loop back; undriven float low (TB drives 0)
    assign uio_in = (uio_oe & uio_out);

    integer fail = 0, nchecks = 0;
    task check(input integer cond, input [255:0] what);
        begin
            nchecks = nchecks + 1;
            if (!cond) begin $display("FAIL: %0s", what); fail = 1; end
        end
    endtask

    tt_um_pemu dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    // ---------------- UART tasks ----------------
    // TX bits are driven on negedge clk (half-cycle setup margin) so the
    // host's autobaud measures exactly T clocks/bit (no posedge race).
    task send_level(input v, input integer nclks);
        begin
            @(negedge clk); ui_in[0] = v;
            repeat (nclks) @(posedge clk);
        end
    endtask

    task uart_tx(input [7:0] b);
        integer i;
        begin
            send_level(0, T);                                  // start
            for (i = 0; i < 8; i = i + 1) send_level(b[i], T); // data LSB-first
            send_level(1, T);                                  // stop
        end
    endtask

    // Always-on host RX monitor: catches every DUT byte even if the DUT
    // starts transmitting while uart_tx is still holding its last stop bit
    // (the host answers fast; a wait-for-edge-then-sample uart_rx starts
    // counting ~45 clocks late and samples every byte near bit edges).
    // Bytes are queued in arrival order; uart_rx pops.
    reg [7:0] rx_queue [0:255];
    integer rx_qw = 0, rx_qr = 0;
    always begin
        reg [7:0] bmon;
        integer kmon;
        @(negedge uo_out[0]);
        #(T * 20 * 1.5);   // to bit0 center (20 ns/clock at this timescale)
        for (kmon = 0; kmon < 8; kmon = kmon + 1) begin
            bmon[kmon] = uo_out[0];
            #(T * 20);
        end
        // NOTE: no trailing stop-bit wait; re-arm must precede the next
        // start bit. Framing is checked at the byte level (ACK/status).
        rx_queue[rx_qw[7:0]] = bmon;
        rx_qw = rx_qw + 1;
    end

    task uart_rx(output reg [7:0] b);
        integer to;
        begin
            to = 0;
            while (rx_qw == rx_qr && to < 30000) begin #1000; to = to + 1; end
            if (rx_qw == rx_qr) begin
                $display("FAIL: uart_rx timeout waiting for DUT byte");
                nchecks = nchecks + 1; fail = 1; b = 8'hxx;
            end else begin
                b = rx_queue[rx_qr[7:0]];
                rx_qr = rx_qr + 1;
            end
        end
    endtask

    task expect_ack;
        reg [7:0] b;
        begin
            uart_rx(b);
            check(b === 8'hA5, "expect ACK_OK");
        end
    endtask

    reg [31:0] img [0:63];
    reg [7:0]  rbyte;
    integer i, to;

    // pin echo monitor: records uio_out sequence
    reg [7:0] pin_hist [0:15];
    integer pin_n = 0;

    initial begin
        $dumpfile("/tmp/tb_top.vcd"); $dumpvars(0, tb_top);

        // ================= Phase A: HALT_REQ =================
        $readmemh("test/hex/halt_test.hex", img);
        rst_n = 0; repeat (20) @(posedge clk); rst_n = 1;
        repeat (10) @(posedge clk);
        uart_tx(8'h00);                              // autobaud sync
        // LOAD_IMEM: 1 word
        uart_tx(8'h01); uart_tx(8'h06); uart_tx(8'h00); uart_tx(8'h00);
        uart_tx(img[0][31:24]); uart_tx(img[0][23:16]);
        uart_tx(img[0][15:8]);  uart_tx(img[0][7:0]);
        expect_ack();
        $display("  info: Phase A LOAD_IMEM done");
        // GO
        uart_tx(8'h09); uart_tx(8'h00);
        expect_ack();
        repeat (200) @(posedge clk);                  // PE spinning in jmp loop
        // RD_STATUS: expect running
        uart_tx(8'h08); uart_tx(8'h00);
        uart_rx(rbyte); check(rbyte === 8'hA5, "A: RD_STATUS ack");
        uart_rx(rbyte);
        check(rbyte === 8'h90, "A: RD_STATUS running (0x90)");
        // HALT_REQ
        uart_tx(8'h0A); uart_tx(8'h00);
        expect_ack();
        repeat (50) @(posedge clk);
        check(dut.u_host.halt_req_r === 1'b1, "A: halt_req asserted");
        uart_tx(8'h08); uart_tx(8'h00);
        uart_rx(rbyte); check(rbyte === 8'hA5, "A: RD_STATUS ack2");
        uart_rx(rbyte);
        check(rbyte === 8'h50, "A: RD_STATUS halted (0x50)");
        check(rbyte[6] === 1'b1, "A: pe_halted=1");
        // GO clears halt_req, PE restarts
        uart_tx(8'h09); uart_tx(8'h00);
        expect_ack();
        check(dut.u_host.halt_req_r === 1'b0, "A: GO drops halt_req");
        repeat (100) @(posedge clk);
        uart_tx(8'h08); uart_tx(8'h00);
        uart_rx(rbyte); check(rbyte === 8'hA5, "A: RD_STATUS ack3");
        uart_rx(rbyte);
        check(rbyte === 8'h90, "A: RD_STATUS running again (0x90)");
        $display("  info: Phase A HALT_REQ done");

        // ================= Phase B: top_smoke =================
        $readmemh("test/hex/top_smoke.hex", img);
        rst_n = 0; repeat (20) @(posedge clk); rst_n = 1;
        repeat (10) @(posedge clk);
        uart_tx(8'h00);                              // autobaud sync
        // LOAD_IMEM: 33 words
        uart_tx(8'h01); uart_tx(8'h86); uart_tx(8'h00); uart_tx(8'h00);
        for (i = 0; i < 33; i = i + 1) begin
            uart_tx(img[i][31:24]); uart_tx(img[i][23:16]);
            uart_tx(img[i][15:8]); uart_tx(img[i][7:0]);
        end
        expect_ack();
        $display("  info: Phase B LOAD_IMEM done");
        // VERIFY_IMEM readback
        uart_tx(8'h02); uart_tx(8'h03); uart_tx(8'h00); uart_tx(8'h00); uart_tx(8'd33);
        uart_rx(rbyte); check(rbyte === 8'hA5, "B: VERIFY ack");
        for (i = 0; i < 33; i = i + 1) begin
            reg [31:0] w;
            uart_rx(rbyte); w[31:24] = rbyte;
            uart_rx(rbyte); w[23:16] = rbyte;
            uart_rx(rbyte); w[15:8]  = rbyte;
            uart_rx(rbyte); w[7:0]   = rbyte;
            check(w === img[i], "B: VERIFY word");
        end
        $display("  info: Phase B VERIFY_IMEM done");
        // Resync: VERIFY's 133-byte response idles the RX line >65k clocks,
        // re-arming autobaud (sync_armed). The next byte is consumed as the
        // 0x00 sync (not a command) and t_bit is re-measured. Send 0x00,
        // wait for it to retire, then GO.
        repeat (3000) @(posedge clk);
        uart_tx(8'h00);
        repeat (2000) @(posedge clk);
        // GO first (enter RUN), then WR_RXFIFO: WR_RXFIFO is RUN-only per
        // ISA (PROG -> NACK_ERR). Firmware spins on RXNE before each PULL,
        // so the PE waits for the TB's data (no fill-vs-pull race).
        pin_n = 0;
        fork
            begin
                uart_tx(8'h09); uart_tx(8'h00);
                expect_ack();
                // WR_RXFIFO: 7 words {1,1,1,3, 1,2,3}
                uart_tx(8'h05); uart_tx(8'h0E);
                uart_tx(8'h00); uart_tx(8'h01);
                uart_tx(8'h00); uart_tx(8'h01);
                uart_tx(8'h00); uart_tx(8'h01);
                uart_tx(8'h00); uart_tx(8'h03);
                uart_tx(8'h00); uart_tx(8'h01);
                uart_tx(8'h00); uart_tx(8'h02);
                uart_tx(8'h00); uart_tx(8'h03);
                expect_ack();
                $display("  info: Phase B WR_RXFIFO done");
            end
            begin
                reg [7:0] last; last = 8'hxx;
                to = 0;
                while (dut.u_pe.pe_halted !== 1'b1 && to < 20000) begin
                    @(negedge clk);
                    if (uio_out !== last && pin_n < 16) begin
                        pin_hist[pin_n] = uio_out; pin_n = pin_n + 1; last = uio_out;
                    end
                    to = to + 1;
                end
            end
        join
        check(dut.u_pe.pe_halted === 1'b1, "B: PE halted");
        $display("  info: pin history (%0d):", pin_n);
        for (i = 0; i < pin_n; i = i + 1) $display("    pin_hist[%0d] = 0x%02h", i, pin_hist[i]);
        // expect 0x01, 0x02, 0x03 in the history (in order)
        begin
            integer s0, s1, s2, k;
            s0 = -1; s1 = -1; s2 = -1;
            for (k = 0; k < pin_n; k = k + 1) begin
                if (s0 < 0 && pin_hist[k] === 8'h01) s0 = k;
                else if (s0 >= 0 && s1 < 0 && pin_hist[k] === 8'h02) s1 = k;
                else if (s1 >= 0 && s2 < 0 && pin_hist[k] === 8'h03) s2 = k;
            end
            check(s0 >= 0 && s1 > s0 && s2 > s1, "B: pin echo 01->02->03");
        end
        // RD_STATUS: halted, TX not empty, no errors -> 0x40
        uart_tx(8'h08); uart_tx(8'h00);
        uart_rx(rbyte); check(rbyte === 8'hA5, "B: RD_STATUS ack");
        uart_rx(rbyte);
        check(rbyte === 8'h40, "B: RD_STATUS halted (0x40)");
        // RD_TXFIFO: expect 3 words {0001,0002,0003}
        uart_tx(8'h06); uart_tx(8'h01); uart_tx(8'hFF);
        uart_rx(rbyte); check(rbyte === 8'hA5, "B: RD_TXFIFO ack");
        uart_rx(rbyte); check(rbyte === 8'h06, "B: RD_TXFIFO count=6");
        uart_rx(rbyte); check(rbyte === 8'h00, "B: TX w0 hi");
        uart_rx(rbyte); check(rbyte === 8'h01, "B: TX w0 lo=0x01");
        uart_rx(rbyte); check(rbyte === 8'h00, "B: TX w1 hi");
        uart_rx(rbyte); check(rbyte === 8'h01 + 8'h01, "B: TX w1 lo=0x02");
        uart_rx(rbyte); check(rbyte === 8'h00, "B: TX w2 hi");
        uart_rx(rbyte); check(rbyte === 8'h03, "B: TX w2 lo=0x03");
        // RD_TRACE: expect 2 entries, pins 0x01 and 0x03
        uart_tx(8'h07); uart_tx(8'h02); uart_tx(8'h00); uart_tx(8'h02);
        uart_rx(rbyte); check(rbyte === 8'hA5, "B: RD_TRACE ack");
        uart_rx(rbyte); check(rbyte === 8'h02, "B: RD_TRACE count=2");
        begin
            reg [31:0] ts0, ts1;
            reg [7:0] p0, p1;
            uart_rx(rbyte); ts0[31:24] = rbyte;
            uart_rx(rbyte); ts0[23:16] = rbyte;
            uart_rx(rbyte); ts0[15:8]  = rbyte;
            uart_rx(rbyte); ts0[7:0]   = rbyte;
            uart_rx(p0);
            uart_rx(rbyte); ts1[31:24] = rbyte;
            uart_rx(rbyte); ts1[23:16] = rbyte;
            uart_rx(rbyte); ts1[15:8]  = rbyte;
            uart_rx(rbyte); ts1[7:0]   = rbyte;
            uart_rx(p1);
            uart_rx(rbyte); check(rbyte === 8'h02, "B: RD_TRACE ptr=2");
            check(p0 === 8'h01, "B: trace entry0 pins=0x01");
            check(p1 === 8'h03, "B: trace entry1 pins=0x03");
            check(ts1 > ts0, "B: trace ts increasing");
            $display("  info: trace ts0=%0d ts1=%0d", ts0, ts1);
        end

        $display("done: %0d checks, %0s", nchecks, fail ? "FAIL" : "PASS");
        $finish;
    end

    initial begin
        #2000000000;
        $display("FAIL: watchdog timeout");
        $finish;
    end
endmodule
`default_nettype wire
