`timescale 1ns/1ps
`default_nettype none

module lbtiny_bus_slave_tb;

    reg        CLK;
    reg        RESET_n;
    reg  [3:0] A;
    wire [7:0] AD;
    reg        ALE;
    reg        RD_n;
    reg        WR_n;

    reg  [7:0] tb_ad_out;
    reg        tb_ad_oe;

    // Testbench drives AD only during address/write phases.
    assign AD = tb_ad_oe ? tb_ad_out : 8'bzzzz_zzzz;

    lbtiny_bus_slave dut (
        .CLK     (CLK),
        .RESET_n (RESET_n),
        .A       (A),
        .AD      (AD),
        .ALE     (ALE),
        .RD_n    (RD_n),
        .WR_n    (WR_n)
    );

    // 4 MHz clock: 250 ns period.
    initial begin
        CLK = 1'b0;
    end

    always #125 CLK = ~CLK;

    task idle_bus;
        begin
            A         = 4'h0;
            ALE       = 1'b0;
            RD_n      = 1'b1;
            WR_n      = 1'b1;
            tb_ad_out = 8'h00;
            tb_ad_oe  = 1'b0;
        end
    endtask

    task apply_reset;
        begin
            RESET_n = 1'b0;
            idle_bus();

            repeat (5) @(posedge CLK);

            RESET_n = 1'b1;

            repeat (3) @(posedge CLK);
        end
    endtask

    task latch_addr;
        input [11:0] addr;
        begin
            @(negedge CLK);

            RD_n      = 1'b1;
            WR_n      = 1'b1;
            ALE       = 1'b1;
            A         = addr[11:8];
            tb_ad_out = addr[7:0];
            tb_ad_oe  = 1'b1;

            // Hold ALE high through at least one rising CLK so the DUT's
            // transparent-latch model captures AD[7:0].
            repeat (2) @(posedge CLK);

            @(negedge CLK);
            ALE = 1'b0;

            @(posedge CLK);
        end
    endtask

    task bus_write;
        input [11:0] addr;
        input [7:0]  data;
        begin
            latch_addr(addr);

            @(negedge CLK);

            tb_ad_out = data;
            tb_ad_oe  = 1'b1;
            RD_n      = 1'b1;
            WR_n      = 1'b0;

            // Keep WR_n low long enough for wr_n_q to sample it.
            repeat (2) @(posedge CLK);

            @(negedge CLK);
            WR_n = 1'b1;

            // The DUT commits the write on this rising CLK edge.
            @(posedge CLK);

            @(negedge CLK);
            tb_ad_oe = 1'b0;

            repeat (1) @(posedge CLK);
        end
    endtask

    task bus_read;
        input  [11:0] addr;
        output [7:0]  data;
        begin
            latch_addr(addr);

            @(negedge CLK);

            // Release AD so the slave can drive it.
            tb_ad_oe = 1'b0;
            RD_n     = 1'b0;
            WR_n     = 1'b1;

            // ROM/RAM reads are synchronous in the DUT, so wait for data.
            repeat (2) @(posedge CLK);

            #1 data = AD;

            @(negedge CLK);
            RD_n = 1'b1;

            repeat (1) @(posedge CLK);
        end
    endtask

    task flash_program;
        input [11:0] addr;
        input [7:0]  data;
        begin
            bus_write(12'h555, 8'hAA);
            bus_write(12'h2AA, 8'h55);
            bus_write(12'h555, 8'hA0);
            bus_write(addr,    data);
        end
    endtask

    task flash_erase;
        begin
            bus_write(12'h555, 8'hAA);
            bus_write(12'h2AA, 8'h55);
            bus_write(12'h555, 8'h80);
            bus_write(12'h555, 8'hAA);
            bus_write(12'h2AA, 8'h55);
            bus_write(12'h000, 8'h30);
        end
    endtask

    task check_byte;
        input [7:0] got;
        input [7:0] expected;
        input [8*80-1:0] msg;
        begin
            if (got !== expected) begin
                $display("FAIL: %0s: got 0x%02h, expected 0x%02h",
                         msg, got, expected);
                $finish;
            end else begin
                $display("PASS: %0s: 0x%02h", msg, got);
            end
        end
    endtask

    reg [7:0] rd;

    initial begin
        $dumpfile("lbtiny_bus_slave_tb.vcd");
        $dumpvars(0, lbtiny_bus_slave_tb);

        apply_reset();

        // ROM should start erased, assuming rom_init.mem contains FF bytes.
        bus_read(12'h010, rd);
        check_byte(rd, 8'hFF, "ROM starts erased at 0x010");

        // Bare ROM write should be ignored.
        bus_write(12'h010, 8'h12);
        bus_read(12'h010, rd);
        check_byte(rd, 8'hFF, "bare ROM write is ignored");

        // Proper SST-style unlock/program sequence should write one ROM byte.
        flash_program(12'h010, 8'h42);
        bus_read(12'h010, rd);
        check_byte(rd, 8'h42, "flash unlock/program writes byte");

        // Begin a program command, reset before the data write, then verify
        // that the partial command sequence was cleared.
        bus_write(12'h555, 8'hAA);
        bus_write(12'h2AA, 8'h55);
        bus_write(12'h555, 8'hA0);

        apply_reset();

        bus_write(12'h020, 8'h66);
        bus_read(12'h020, rd);
        check_byte(rd, 8'hFF, "RESET_n clears partial flash command");

        // RAM should allow plain writes.
        bus_write(12'hC20, 8'hA5);
        bus_read(12'hC20, rd);
        check_byte(rd, 8'hA5, "RAM write/read at 0xC20");

        // MMIO stub should read zero and ignore writes.
        bus_write(12'hF10, 8'h77);
        bus_read(12'hF10, rd);
        check_byte(rd, 8'h00, "MMIO reads zero and drops writes");

        // Erase the ROM and wait longer than the 3072-cycle erase pass.
        flash_erase();

        repeat (3200) @(posedge CLK);

        bus_read(12'h010, rd);
        check_byte(rd, 8'hFF, "flash erase returns programmed byte to 0xFF");

        $display("");
        $display("All lbtiny_bus_slave tests passed.");
        $finish;
    end

endmodule

`default_nettype wire