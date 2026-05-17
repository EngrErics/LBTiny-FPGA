//==============================================================================
// lbtiny_bus_slave.v
//------------------------------------------------------------------------------
// Bus slave subsystem for the LBTiny 8-bit CPU.
//
// Mirrors the external memory hardware on the reference board:
//   - 3 KB ROM   at 0x000-0xBFF  (BRAM, emulates SST39VF010A NOR flash)
//   - 768 B SRAM at 0xC00-0xEFF  (BRAM, emulates AS6C6264 SRAM)
//   - 256 B MMIO at 0xF00-0xFFF  (stub: reads 0x00, writes ignored)
//
// Listens on the 8085/8051-style multiplexed address/data bus driven either
// by the CPU (normal operation) or by the STM32 supervisor (bus-mastery during
// RESET_n low, used for flash programming).
//
// Target: Xilinx Artix-7 (Nexys A7), 4 MHz CLK input.
//
// 2026-05-16 revision:
//   The ROM and RAM arrays are now described with a Xilinx-friendly simple
//   dual-port BRAM inference template:
//     - One always block per memory, no reset on the memory itself.
//     - Read port and write port use independent address signals but live in
//       the same clocked block.
//     - Synchronous output register on the read port, also reset-free.
//   The flash command state machine is in a separate always block (with a
//   reset) that produces the write-port enable/address/data combinationally
//   from its registered state. This pattern is recognized by Vivado as
//   RAM_STYLE = block, while still being functionally identical to the prior
//   version. The flash command protocol (AA/55/A0 program, AA/55/80/AA/55/30
//   erase) is unchanged.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module lbtiny_bus_slave (
    input  wire       CLK,       // 4 MHz system clock
    input  wire       RESET_n,   // Active-low reset (from supervisor or CPU)
    input  wire [3:0] A,         // A[11:8] upper address nibble
    inout  wire [7:0] AD,        // Multiplexed address[7:0] / data bus
    input  wire       ALE,       // Address latch enable
    input  wire       RD_n,      // Active-low read strobe
    input  wire       WR_n       // Active-low write strobe
);

    //--------------------------------------------------------------------------
    // 1. Address latch (mirrors the external 74HC573)
    //--------------------------------------------------------------------------
    // Transparent-while-ALE-high latch: AD[7:0] is captured every cycle ALE is
    // high, and held when ALE goes low. Functionally equivalent to a 74HC573.

    reg [7:0] ad_low_latched;

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            ad_low_latched <= 8'h00;
        end else begin
            if (ALE) begin
                ad_low_latched <= AD;
            end
        end
    end

    wire [11:0] addr = {A, ad_low_latched};

    //--------------------------------------------------------------------------
    // 2. Address decoder
    //--------------------------------------------------------------------------
    wire cs_rom  = (addr <= 12'hBFF);
    wire cs_ram  = (addr >= 12'hC00) && (addr <= 12'hEFF);
    wire cs_mmio = (addr >= 12'hF00);

    //--------------------------------------------------------------------------
    // 3. Strobe edge detection
    //--------------------------------------------------------------------------
    // Writes commit on the rising edge of WR_n. Reads are level-sensitive and
    // drive AD[7:0] whenever RD_n is low and the address is in our range.

    reg wr_n_q;
    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) wr_n_q <= 1'b1;
        else          wr_n_q <= WR_n;
    end

    wire wr_rising   = (wr_n_q == 1'b0) && (WR_n == 1'b1);
    wire data_phase  = ~ALE;
    wire write_pulse = wr_rising & data_phase;
    wire [7:0] write_data = AD;

    //--------------------------------------------------------------------------
    // 4. SST39VF010A-style flash command state machine
    //--------------------------------------------------------------------------
    // Program: AA@555, 55@2AA, A0@555, <data>@<addr>
    // Erase  : AA@555, 55@2AA, 80@555, AA@555, 55@2AA, 30@<any addr in sector>
    // Bare writes outside a valid sequence are silently dropped.

    localparam [3:0]
        S_IDLE     = 4'd0,
        S_UNLOCK1  = 4'd1,
        S_UNLOCK2  = 4'd2,
        S_PROGRAM  = 4'd3,
        S_ERASE1   = 4'd4,
        S_ERASE2   = 4'd5,
        S_ERASE3   = 4'd6;

    reg [3:0] flash_state;

    wire cmd_addr_555 = (addr == 12'h555);
    wire cmd_addr_2AA = (addr == 12'h2AA);

    // Registered outputs that drive the ROM write port from the program path.
    reg        rom_program_we;
    reg [11:0] rom_program_addr;
    reg [7:0]  rom_program_data;
    reg        rom_erase_start;

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            flash_state      <= S_IDLE;
            rom_program_we   <= 1'b0;
            rom_program_addr <= 12'h000;
            rom_program_data <= 8'h00;
            rom_erase_start  <= 1'b0;
        end else begin
            rom_program_we  <= 1'b0;
            rom_erase_start <= 1'b0;

            if (write_pulse) begin
                case (flash_state)
                    S_IDLE: begin
                        if (cs_rom && cmd_addr_555 && write_data == 8'hAA)
                            flash_state <= S_UNLOCK1;
                    end

                    S_UNLOCK1: begin
                        if (cs_rom && cmd_addr_2AA && write_data == 8'h55)
                            flash_state <= S_UNLOCK2;
                        else
                            flash_state <= S_IDLE;
                    end

                    S_UNLOCK2: begin
                        if (cs_rom && cmd_addr_555 && write_data == 8'hA0)
                            flash_state <= S_PROGRAM;
                        else if (cs_rom && cmd_addr_555 && write_data == 8'h80)
                            flash_state <= S_ERASE1;
                        else
                            flash_state <= S_IDLE;
                    end

                    S_PROGRAM: begin
                        // Fourth write: program the byte. Only addresses inside
                        // the ROM range are honored.
                        if (cs_rom) begin
                            rom_program_we   <= 1'b1;
                            rom_program_addr <= addr;
                            rom_program_data <= write_data;
                        end
                        flash_state <= S_IDLE;
                    end

                    S_ERASE1: begin
                        if (cs_rom && cmd_addr_555 && write_data == 8'hAA)
                            flash_state <= S_ERASE2;
                        else
                            flash_state <= S_IDLE;
                    end

                    S_ERASE2: begin
                        if (cs_rom && cmd_addr_2AA && write_data == 8'h55)
                            flash_state <= S_ERASE3;
                        else
                            flash_state <= S_IDLE;
                    end

                    S_ERASE3: begin
                        if (cs_rom && write_data == 8'h30)
                            rom_erase_start <= 1'b1;
                        flash_state <= S_IDLE;
                    end

                    default: flash_state <= S_IDLE;
                endcase
            end
        end
    end

    //--------------------------------------------------------------------------
    // 5. ROM erase walker
    //--------------------------------------------------------------------------
    // Walks the ROM region writing 0xFF. Kept in its own always block so the
    // BRAM block-RAM template below stays clean (no reset, single write port).

    reg        erasing;
    reg [11:0] erase_idx;

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            erasing   <= 1'b0;
            erase_idx <= 12'h000;
        end else begin
            if (rom_erase_start) begin
                erasing   <= 1'b1;
                erase_idx <= 12'h000;
            end else if (erasing) begin
                if (erase_idx == 12'hBFF)
                    erasing <= 1'b0;
                erase_idx <= erase_idx + 12'd1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 6. ROM write-port mux
    //--------------------------------------------------------------------------
    // Combine the erase and program write streams into one set of port signals
    // that the BRAM block can consume directly. If both fire on the same cycle
    // (the FSM guarantees they don't), erase wins.

    wire        rom_we    = erasing | rom_program_we;
    wire [11:0] rom_waddr = erasing ? erase_idx : rom_program_addr;
    wire [7:0]  rom_wdata = erasing ? 8'hFF     : rom_program_data;

    //--------------------------------------------------------------------------
    // 7. ROM BRAM (mirrors SST39VF010A)
    //--------------------------------------------------------------------------
    // Simple dual-port template recognized by Vivado as RAM_STYLE = block:
    //   - One clocked always block, no reset.
    //   - Independent read/write addresses.
    //   - Synchronous output register rom_rdata, also reset-free.
    //   - Initial contents from $readmemh (becomes the BRAM INIT_xx attrs).

    (* ram_style = "block" *) reg [7:0] rom_mem [0:4095];
    reg [7:0] rom_rdata;

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) rom_mem[i] = 8'hFF;
        $readmemh("rom_init.mem", rom_mem);
    end

    always @(posedge CLK) begin
        if (rom_we)
            rom_mem[rom_waddr] <= rom_wdata;
        rom_rdata <= rom_mem[addr];
    end

    //--------------------------------------------------------------------------
    // 8. RAM BRAM (mirrors AS6C6264 SRAM)
    //--------------------------------------------------------------------------
    // 768 bytes at 0xC00..0xEFF. Allocated as 1024 entries (next power of two)
    // for clean BRAM inference.

    (* ram_style = "block" *) reg [7:0] ram_mem [0:1023];
    reg [7:0] ram_rdata;

    wire [11:0] ram_offset_full = addr - 12'hC00;
    wire [9:0]  ram_offset      = ram_offset_full[9:0];

    integer j;
    initial begin
        for (j = 0; j < 1024; j = j + 1) ram_mem[j] = 8'h00;
    end

    always @(posedge CLK) begin
        if (cs_ram && write_pulse)
            ram_mem[ram_offset] <= write_data;
        ram_rdata <= ram_mem[ram_offset];
    end

    //--------------------------------------------------------------------------
    // 9. MMIO stub
    //--------------------------------------------------------------------------
    wire [7:0] mmio_rdata = 8'h00;

    //--------------------------------------------------------------------------
    // 10. Read data mux
    //--------------------------------------------------------------------------
    // Both rom_rdata and ram_rdata are registered (synchronous BRAM read), so
    // we register the chip selects to keep the mux output aligned.

    reg cs_rom_q, cs_ram_q, cs_mmio_q;
    always @(posedge CLK) begin
        cs_rom_q  <= cs_rom;
        cs_ram_q  <= cs_ram;
        cs_mmio_q <= cs_mmio;
    end

    reg [7:0] rdata;
    always @(*) begin
        if      (cs_rom_q)  rdata = rom_rdata;
        else if (cs_ram_q)  rdata = ram_rdata;
        else if (cs_mmio_q) rdata = mmio_rdata;
        else                rdata = 8'h00;
    end

    //--------------------------------------------------------------------------
    // 11. Bus tristate control
    //--------------------------------------------------------------------------
    wire drive_en = (RD_n == 1'b0) && (cs_rom_q || cs_ram_q || cs_mmio_q);
    assign AD = drive_en ? rdata : 8'bz;

endmodule

`default_nettype wire
