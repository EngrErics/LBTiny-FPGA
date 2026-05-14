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
    // The real 74HC573 is a transparent latch: while ALE is high the output
    // follows AD[7:0], and on the falling edge of ALE the value is held.
    // We approximate this synchronously by detecting the high-to-low transition
    // of ALE on rising CLK edges and capturing AD[7:0] at that moment. Because
    // CLK (4 MHz) is faster than the bus cycle (one full bus cycle is several
    // CLK periods in the CPU's T1..T4 sequence), the captured byte is the
    // address byte that was present just before ALE fell -- which is exactly
    // what the hardware latch would have held.
    //
    // We also keep an "ALE transparent" path so that during the address phase
    // (ALE high) the working address tracks AD[7:0] directly. This more
    // faithfully models the 74HC573 and avoids any one-clock skew issues when
    // the supervisor drives the bus with very short ALE pulses.

    reg [7:0] ad_low_latched;  // Held value after ALE falls (the "latch")

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            ad_low_latched <= 8'h00;
        end else begin
            // While ALE is high, follow AD[7:0] (transparent latch behavior).
            // When ALE goes low, ad_low_latched simply stops updating and
            // holds whatever value was last seen -- exactly like a 74HC573.
            if (ALE) begin
                ad_low_latched <= AD;
            end
        end
    end

    // Full 12-bit address visible to the rest of the slave.
    wire [11:0] addr = {A, ad_low_latched};

    //--------------------------------------------------------------------------
    // 2. Address decoder
    //--------------------------------------------------------------------------
    // ROM : 0x000 - 0xBFF  (3072 bytes)
    // RAM : 0xC00 - 0xEFF  (768 bytes)
    // MMIO: 0xF00 - 0xFFF  (256 bytes)
    // Exactly one chip select is active at a time.

    wire cs_rom  = (addr <= 12'hBFF);
    wire cs_ram  = (addr >= 12'hC00) && (addr <= 12'hEFF);
    wire cs_mmio = (addr >= 12'hF00);

    //--------------------------------------------------------------------------
    // 3. Strobe edge detection
    //--------------------------------------------------------------------------
    // We commit writes on the rising edge of WR_n (i.e. when the supervisor or
    // CPU deasserts WR_n, marking the end of the data phase). This is the
    // standard convention for an 8085-style bus and gives stable address+data
    // when the write fires.
    //
    // Reads are level-sensitive: we drive AD[7:0] whenever RD_n is low and the
    // address falls in our range.

    reg wr_n_q;
    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) wr_n_q <= 1'b1;
        else          wr_n_q <= WR_n;
    end

    wire wr_rising = (wr_n_q == 1'b0) && (WR_n == 1'b1);
    // Address phase has ended (ALE is low) and we are in the data phase.
    wire data_phase = ~ALE;

    // One-cycle write pulse, qualified by data phase so we don't accidentally
    // latch garbage if WR_n toggles during an address phase.
    wire write_pulse = wr_rising & data_phase;

    // The byte being written is whatever is on AD[7:0] at the moment WR_n
    // rises. AD[7:0] is the data bus during the data phase.
    wire [7:0] write_data = AD;

    //--------------------------------------------------------------------------
    // 4. SST39VF010A-style flash command state machine
    //--------------------------------------------------------------------------
    // The supervisor must send the standard AMD/SST unlock sequence before any
    // program or erase can succeed. Bare writes outside a valid command
    // sequence are silently dropped, just like the real part.
    //
    // Program (write one byte):
    //   1. Write 0xAA to 0x555
    //   2. Write 0x55 to 0x2AA
    //   3. Write 0xA0 to 0x555
    //   4. Write <data> to <target address>     <-- this is the real write
    //
    // Sector erase (we treat "sector" as the entire 3 KB ROM for simplicity,
    // since the real SST39VF010A's 4 KB sector is larger than our whole ROM):
    //   1. Write 0xAA to 0x555
    //   2. Write 0x55 to 0x2AA
    //   3. Write 0x80 to 0x555
    //   4. Write 0xAA to 0x555
    //   5. Write 0x55 to 0x2AA
    //   6. Write 0x30 to any address inside the sector  -> fills ROM with 0xFF
    //
    // We do NOT model status-register polling or DQ7/DQ6 toggling. The
    // supervisor uses fixed delays.

    localparam [3:0]
        S_IDLE     = 4'd0,
        S_UNLOCK1  = 4'd1,  // Got 0xAA @ 0x555
        S_UNLOCK2  = 4'd2,  // Got 0x55 @ 0x2AA
        S_PROGRAM  = 4'd3,  // Got 0xA0 @ 0x555 -> next write is the data byte
        S_ERASE1   = 4'd4,  // Got 0x80 @ 0x555 (after first unlock pair)
        S_ERASE2   = 4'd5,  // Got 0xAA @ 0x555 (second unlock, in erase path)
        S_ERASE3   = 4'd6;  // Got 0x55 @ 0x2AA (second unlock, in erase path)

    reg [3:0] flash_state;

    // Convenience: writes the supervisor performs hit the *ROM* address space.
    // The command/address matching uses the low 12 bits of the latched address.
    wire cmd_addr_555 = (addr == 12'h555);
    wire cmd_addr_2AA = (addr == 12'h2AA);

    // These flags tell the ROM BRAM "this cycle is a legitimate program or
    // erase action; perform the write/fill."
    reg        rom_program_we;     // 1-cycle pulse: program one byte
    reg [11:0] rom_program_addr;
    reg [7:0]  rom_program_data;
    reg        rom_erase_start;    // 1-cycle pulse: begin sector erase

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            flash_state      <= S_IDLE;
            rom_program_we   <= 1'b0;
            rom_program_addr <= 12'h000;
            rom_program_data <= 8'h00;
            rom_erase_start  <= 1'b0;
        end else begin
            // Defaults: pulses deassert every cycle.
            rom_program_we  <= 1'b0;
            rom_erase_start <= 1'b0;

            if (write_pulse) begin
                case (flash_state)
                    //------------------------------------------------------
                    S_IDLE: begin
                        if (cs_rom && cmd_addr_555 && write_data == 8'hAA)
                            flash_state <= S_UNLOCK1;
                        // Any other write while idle is dropped.
                    end

                    //------------------------------------------------------
                    S_UNLOCK1: begin
                        if (cs_rom && cmd_addr_2AA && write_data == 8'h55)
                            flash_state <= S_UNLOCK2;
                        else
                            flash_state <= S_IDLE;   // Bad sequence: abort
                    end

                    //------------------------------------------------------
                    S_UNLOCK2: begin
                        if (cs_rom && cmd_addr_555 && write_data == 8'hA0)
                            flash_state <= S_PROGRAM;
                        else if (cs_rom && cmd_addr_555 && write_data == 8'h80)
                            flash_state <= S_ERASE1;
                        else
                            flash_state <= S_IDLE;   // Bad sequence: abort
                    end

                    //------------------------------------------------------
                    S_PROGRAM: begin
                        // The fourth write: actually program the byte.
                        // Only writes inside the ROM range are honored.
                        if (cs_rom) begin
                            rom_program_we   <= 1'b1;
                            rom_program_addr <= addr;
                            rom_program_data <= write_data;
                        end
                        flash_state <= S_IDLE;
                    end

                    //------------------------------------------------------
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
                        // Sixth write: 0x30 anywhere in ROM range triggers
                        // the (single, whole-ROM) sector erase.
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
    // 5. ROM BRAM (mirrors SST39VF010A)
    //--------------------------------------------------------------------------
    // 3072 x 8. We round up to 4096 x 8 so the synthesizer infers one BRAM36.
    // Inferred as simple dual port:
    //   - Write port: driven by the flash command state machine (program/erase)
    //   - Read port : driven by the bus during normal reads
    // Initialized to 0xFF (blank flash) via $readmemh from rom_init.mem.

    reg [7:0] rom_mem [0:4095];
    reg [7:0] rom_rdata;

    // Erase support: we use a small counter to walk the ROM and fill with
    // 0xFF when an erase command completes. The supervisor's fixed-timing
    // wait is more than enough to cover the 3072 clocks needed at 4 MHz
    // (~0.77 ms vs the real chip's tens of ms).
    reg        erasing;
    reg [11:0] erase_idx;

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) rom_mem[i] = 8'hFF;
        $readmemh("rom_init.mem", rom_mem);
    end

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            erasing   <= 1'b0;
            erase_idx <= 12'h000;
            rom_rdata <= 8'hFF;
        end else begin
            // ----- Read port (port B) -----
            // Synchronous read so the BRAM block-RAM read path is inferred.
            rom_rdata <= rom_mem[addr];

            // ----- Write port (port A) -----
            // Program and erase share the write port. The state machine never
            // pulses rom_program_we while erasing (program requires going
            // through the unlock sequence, and the erase counter takes only
            // ~3 K clocks, far less than a supervisor inter-write delay), so
            // we don't need an explicit mutex here. If both ever fired in the
            // same cycle the erase would win.
            if (erasing) begin
                rom_mem[erase_idx] <= 8'hFF;
                if (erase_idx == 12'hBFF) begin
                    erasing <= 1'b0;   // Done with the 3 KB ROM region
                end
                erase_idx <= erase_idx + 12'd1;
            end else if (rom_program_we) begin
                rom_mem[rom_program_addr] <= rom_program_data;
            end

            // Kick off a new erase pass on the start pulse.
            if (rom_erase_start) begin
                erasing   <= 1'b1;
                erase_idx <= 12'h000;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 6. RAM BRAM (mirrors AS6C6264 SRAM)
    //--------------------------------------------------------------------------
    // 768 bytes at 0xC00..0xEFF. We allocate 1024 entries (next power of two)
    // so the BRAM infers cleanly. The RAM offset is addr - 0xC00, i.e.
    // addr[9:0] effectively, but with a guard so we never alias into MMIO.

    reg [7:0] ram_mem [0:1023];
    reg [7:0] ram_rdata;

    // addr[11:0] in C00..EFF -> addr - 0xC00 in 0..0x2FF. Low 10 bits is the
    // BRAM index. Casting through a wire keeps the width explicit.
    wire [11:0] ram_offset_full = addr - 12'hC00;
    wire [9:0]  ram_offset      = ram_offset_full[9:0];

    integer j;
    initial begin
        for (j = 0; j < 1024; j = j + 1) ram_mem[j] = 8'h00;
    end

    always @(posedge CLK) begin
        // Synchronous read for BRAM inference.
        ram_rdata <= ram_mem[ram_offset];

        // Synchronous write on the rising edge of WR_n, qualified by chip
        // select. Standard SRAM behavior -- no command sequence.
        if (cs_ram && write_pulse) begin
            ram_mem[ram_offset] <= write_data;
        end
    end

    //--------------------------------------------------------------------------
    // 7. MMIO stub
    //--------------------------------------------------------------------------
    // Reads return 0x00, writes are silently dropped. No storage.
    wire [7:0] mmio_rdata = 8'h00;

    //--------------------------------------------------------------------------
    // 8. Read data mux
    //--------------------------------------------------------------------------
    // Both rom_rdata and ram_rdata are registered (synchronous BRAM read), so
    // we need to remember which CS was active when the read was issued. We
    // register the chip selects alongside the BRAM reads so the mux output
    // lines up with the data.

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
    // 9. Bus tristate control
    //--------------------------------------------------------------------------
    // Drive AD[7:0] only when:
    //   - RD_n is asserted (low), AND
    //   - the address is in one of our regions.
    // Everything else: high-Z, so the supervisor / CPU / other peripherals can
    // drive the bus. This combinational assign infers an IOB tristate.

    wire drive_en = (RD_n == 1'b0) && (cs_rom_q || cs_ram_q || cs_mmio_q);
    assign AD = drive_en ? rdata : 8'bz;

endmodule

`default_nettype wire