//==============================================================================
// lbtiny_mem.v
//------------------------------------------------------------------------------
// Memory subsystem for the LBTiny 8-bit CPU.
//
// Mirrors the external memory hardware on the reference board:
//   - 3 KB ROM   at 0x000-0xBFF  (BRAM, emulates SST39VF010A NOR flash)
//   - 768 B RAM  at 0xC00-0xEFF  (BRAM, emulates AS6C6264 SRAM)
//   - 256 B MMIO at 0xF00-0xFFF  (stub: reads 0x00, writes ignored)
//
// Bus interface:
//   Listens on the 8085/8051-style multiplexed address/data bus driven either
//   by the CPU (normal operation) or by the STM32 supervisor (bus-mastery
//   during RESET_n low, used for flash programming).
//
// Peek interface:
//   A second read-only port exposing BRAM contents directly, independent of
//   the bus. The viewer uses this for live observation without bus transactions.
//   peek_addr selects the address; peek_data is registered one cycle later.
//   MMIO range (0xF00-0xFFF) returns 0x00 via the peek port.
//   The peek port is always active regardless of RESET_n or bus activity.
//
// Target: Xilinx Artix-7 (Nexys A7).
// Bus clock: ~3.846 MHz (100 MHz / 26).
//
// BRAM inference rules (Vivado):
//   - One always @(posedge CLK) block per memory, NO reset on the array.
//   - Independent read and write address ports in the same clocked block.
//   - Synchronous output register on every read port, also reset-free.
//   - (* ram_style = "block" *) forces BRAM; Vivado errors rather than
//     silently falling back to LUTs if inference fails.
//   - The peek ports share the same BRAM array as the bus read port, making
//     each memory a true dual-port BRAM (one write port, two read ports).
//     Vivado infers TDP BRAM automatically from this pattern.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module lbtiny_mem (
    input  wire        CLK,        // Bus clock (~3.846 MHz)
    input  wire        RESET_n,    // Active-low reset (clears control state only)

    // Bus interface (8085/8051-style multiplexed address/data)
    input  wire [3:0]  A,          // A[11:8] upper address nibble
    inout  wire [7:0]  AD,         // Multiplexed address[7:0] / data bus
    input  wire        ALE,        // Address latch enable
    input  wire        RD_n,       // Active-low read strobe
    input  wire        WR_n,       // Active-low write strobe

    // Peek interface (read-only, always live, no bus transaction required)
    input  wire [11:0] peek_addr,  // Address to observe
    output reg  [7:0]  peek_data   // Data at peek_addr, registered one cycle
);

    //--------------------------------------------------------------------------
    // 1. Address latch (mirrors the external 74HC573)
    //--------------------------------------------------------------------------
    // Transparent-while-ALE-high latch: AD[7:0] is captured every cycle ALE
    // is high and held when ALE goes low. Functionally equivalent to 74HC573.

    reg [7:0] ad_low_latched;

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n)
            ad_low_latched <= 8'h00;
        else if (ALE)
            ad_low_latched <= AD;
    end

    wire [11:0] addr = {A, ad_low_latched};

    //--------------------------------------------------------------------------
    // 2. Address decoder
    //--------------------------------------------------------------------------
    wire cs_rom  = (addr <= 12'hBFF);
    wire cs_ram  = (addr >= 12'hC00) && (addr <= 12'hEFF);
    wire cs_mmio = (addr >= 12'hF00);

    //--------------------------------------------------------------------------
    // 3. Write strobe edge detection
    //--------------------------------------------------------------------------
    // Writes commit on the rising edge of WR_n (de-assertion).

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
    // 4. SST39VF010A-style flash command FSM
    //--------------------------------------------------------------------------
    // Program : AA@555, 55@2AA, A0@555, <data>@<addr>
    // Erase   : AA@555, 55@2AA, 80@555, AA@555, 55@2AA, 30@<any ROM addr>
    // Any write outside a valid sequence is silently dropped.

    localparam [3:0]
        S_IDLE    = 4'd0,
        S_UNLOCK1 = 4'd1,
        S_UNLOCK2 = 4'd2,
        S_PROGRAM = 4'd3,
        S_ERASE1  = 4'd4,
        S_ERASE2  = 4'd5,
        S_ERASE3  = 4'd6;

    reg [3:0] flash_state;

    wire cmd_addr_555 = (addr == 12'h555);
    wire cmd_addr_2AA = (addr == 12'h2AA);

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
    // Walks 0x000-0xBFF writing 0xFF, one byte per CLK. Takes 3072 cycles
    // (~800 µs at 3.846 MHz). Kept separate so the BRAM block stays clean.

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
    // Combines erase walker and byte-program streams. Erase wins if both fire
    // simultaneously (the FSM guarantees this cannot happen in practice).

    wire        rom_we    = erasing | rom_program_we;
    wire [11:0] rom_waddr = erasing ? erase_idx       : rom_program_addr;
    wire [7:0]  rom_wdata = erasing ? 8'hFF           : rom_program_data;

    //--------------------------------------------------------------------------
    // 7. ROM BRAM — true dual-port (one write, two read: bus + peek)
    //--------------------------------------------------------------------------
    // Vivado infers TDP BRAM from two independent read addresses in one always
    // block sharing the array with a write port. No reset on any port.

    (* ram_style = "block" *) reg [7:0] rom_mem [0:4095];
    reg [7:0] rom_rdata;       // bus read port output
    reg [7:0] rom_peek_rdata;  // peek read port output

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) rom_mem[i] = 8'hFF;
        $readmemh("rom_init.mem", rom_mem);
    end

    always @(posedge CLK) begin
        if (rom_we)
            rom_mem[rom_waddr] <= rom_wdata;
        rom_rdata      <= rom_mem[addr];
        rom_peek_rdata <= rom_mem[peek_addr];
    end

    //--------------------------------------------------------------------------
    // 8. RAM BRAM — true dual-port (one write, two read: bus + peek)
    //--------------------------------------------------------------------------
    // 768 bytes at 0xC00-0xEFF, allocated as 1024 entries for BRAM inference.

    (* ram_style = "block" *) reg [7:0] ram_mem [0:1023];
    reg [7:0] ram_rdata;       // bus read port output
    reg [7:0] ram_peek_rdata;  // peek read port output

    wire [9:0] ram_offset      = addr[9:0];
    wire [9:0] ram_peek_offset = peek_addr[9:0];

    integer j;
    initial begin
        for (j = 0; j < 1024; j = j + 1) ram_mem[j] = 8'h00;
    end

    always @(posedge CLK) begin
        if (cs_ram && write_pulse)
            ram_mem[ram_offset] <= write_data;
        ram_rdata      <= ram_mem[ram_offset];
        ram_peek_rdata <= ram_mem[ram_peek_offset];
    end

    //--------------------------------------------------------------------------
    // 9. MMIO stub
    //--------------------------------------------------------------------------
    wire [7:0] mmio_rdata = 8'h00;

    //--------------------------------------------------------------------------
    // 10. Bus read data mux
    //--------------------------------------------------------------------------
    // Chip selects are registered one cycle to align with the synchronous BRAM
    // read output register.

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
    // 11. Bus tristate drive
    //--------------------------------------------------------------------------
    wire drive_en = (RD_n == 1'b0) && (cs_rom_q || cs_ram_q || cs_mmio_q);
    assign AD = drive_en ? rdata : 8'bz;

    //--------------------------------------------------------------------------
    // 12. Peek output mux
    //--------------------------------------------------------------------------
    // Registered one cycle after peek_addr is presented, matching BRAM latency.
    // peek_addr decode is combinational; the mux result is registered here so
    // the output is always from a single flip-flop with no long combinational
    // path after the BRAM output register.

    reg peek_cs_rom_q, peek_cs_ram_q;

    always @(posedge CLK) begin
        peek_cs_rom_q <= (peek_addr <= 12'hBFF);
        peek_cs_ram_q <= (peek_addr >= 12'hC00) && (peek_addr <= 12'hEFF);
    end

    always @(posedge CLK) begin
        if      (peek_cs_rom_q) peek_data <= rom_peek_rdata;
        else if (peek_cs_ram_q) peek_data <= ram_peek_rdata;
        else                    peek_data <= 8'h00;
    end

endmodule

`default_nettype wire
