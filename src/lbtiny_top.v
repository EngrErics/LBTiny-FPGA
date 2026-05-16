//==============================================================================
// lbtiny_top.v
//------------------------------------------------------------------------------
// Top-level wrapper for the LBTiny bus slave on the Digilent Nexys A7.
//
// Generates the 4 MHz CPU/bus clock from the on-board 100 MHz oscillator,
// instantiates lbtiny_bus_slave, exposes the multiplexed bus on Pmod JA + JB
// (with RESET_n and INT on JXADC), and drives the 16 board LEDs with debug
// state useful during bring-up.
//
// Pmod assignments (see lbtiny.xdc for FPGA package pins):
//
//   JA  (control + upper address):
//     pin  1  -> A[8]
//     pin  2  -> A[9]
//     pin  3  -> A[10]
//     pin  4  -> A[11]
//     pin  7  -> ALE
//     pin  8  -> RD_n
//     pin  9  -> WR_n
//     pin 10  -> RESET_n
//
//   JB  (multiplexed address/data, bidirectional):
//     pin  1  -> AD[0]
//     pin  2  -> AD[1]
//     pin  3  -> AD[2]
//     pin  4  -> AD[3]
//     pin  7  -> AD[4]
//     pin  8  -> AD[5]
//     pin  9  -> AD[6]
//     pin 10  -> AD[7]
//
//   JXADC (slow / single-direction signals on the analog-input Pmod;
//          its anti-alias filter pads aren't populated so 4 MHz LVCMOS33
//          single-ended is fine):
//     pin  1  -> INT      (supervisor -> CPU; unused during memory bring-up)
//     pin  7  -> (spare)
//
// LED layout (rightmost = LED[0]):
//   LED[11:0]  = latched 12-bit address
//   LED[12]    = cs_rom
//   LED[13]    = cs_ram
//   LED[14]    = cs_mmio
//   LED[15]    = drive_en (lit while the slave is driving AD on a read)
//==============================================================================

`default_nettype none

module lbtiny_top (
    // 100 MHz on-board oscillator
    input  wire        CLK100MHZ,

    // 16 user LEDs
    output wire [15:0] LED,

    // Pmod JA - upper address + bus control (all inputs from supervisor/CPU)
    input  wire [4:1]  JA_AB,     // JA[1..4]  -> A[8..11]
    input  wire [10:7] JA_CTL,    // JA[7..10] -> ALE, RD_n, WR_n, RESET_n

    // Pmod JB - multiplexed address/data (bidirectional)
    inout  wire [4:1]  JB_AD_LO,  // JB[1..4]  -> AD[0..3]
    inout  wire [10:7] JB_AD_HI,  // JB[7..10] -> AD[4..7]

    // Pmod JXADC - low-rate single-direction signals
    input  wire        JXADC_INT  // JXADC[1]  -> INT  (input to FPGA, from supervisor)
);

    //--------------------------------------------------------------------------
    // Clock divider: 100 MHz -> 4 MHz
    //--------------------------------------------------------------------------
    // Simple integer divide. 100 / 4 = 25, so toggle every 12.5 CLK100MHZ
    // cycles. A symmetric 4 MHz needs a divide-by-25 with a half-period of
    // 12.5, which we approximate by toggling every 12 or 13 cycles in turn
    // (giving 50% duty cycle averaged). For our purposes any approximately
    // 4 MHz clock is fine -- the bus slave doesn't care about exact frequency
    // and the supervisor uses fixed delays.
    //
    // Cleanest approach: toggle at half the divide count, accept ~3.85 MHz
    // (divide by 26 -> toggle every 13). The bus slave's only timing
    // requirement is that CLK is much faster than the ALE/strobe widths the
    // supervisor produces (>= 1 us); 3.85 MHz easily satisfies that.

    reg [4:0] clk_div_cnt = 5'd0;
    reg       clk_4mhz    = 1'b0;

    always @(posedge CLK100MHZ) begin
        if (clk_div_cnt == 5'd12) begin
            clk_div_cnt <= 5'd0;
            clk_4mhz    <= ~clk_4mhz;
        end else begin
            clk_div_cnt <= clk_div_cnt + 5'd1;
        end
    end

    //--------------------------------------------------------------------------
    // Repack Pmod inputs into the lbtiny_bus_slave's native signal shapes
    //--------------------------------------------------------------------------
    // The Pmod ranges JA_AB[4:1] and JA_CTL[10:7] decode as follows.
    // The XDC binds each individual Pmod pin to one of these vector slots.

    wire [3:0] A;     // A[3:0] in this module corresponds to A[11:8] on the CPU
    wire       ALE;
    wire       RD_n;
    wire       WR_n;
    wire       RESET_n;

    assign A[0] = JA_AB[1];   // JA pin 1  -> A[8]
    assign A[1] = JA_AB[2];   // JA pin 2  -> A[9]
    assign A[2] = JA_AB[3];   // JA pin 3  -> A[10]
    assign A[3] = JA_AB[4];   // JA pin 4  -> A[11]

    assign ALE     = JA_CTL[7];   // JA pin 7
    assign RD_n    = JA_CTL[8];   // JA pin 8
    assign WR_n    = JA_CTL[9];   // JA pin 9
    assign RESET_n = JA_CTL[10];  // JA pin 10

    // INT is supervisor -> CPU; we don't have a CPU here yet so we just
    // ignore it during bring-up but keep the pin reserved for the constraint
    // file. Tie a no-op to silence "input not used" if the synthesizer warns.
    wire int_in_unused = JXADC_INT;  // kept for completeness
    /* verilator lint_off UNUSED */
    /* verilator lint_on  UNUSED */

    //--------------------------------------------------------------------------
    // Bidirectional AD bus wiring
    //--------------------------------------------------------------------------
    // The slave exposes AD as a single 8-bit inout vector. The Nexys A7
    // routes JB's eight data pins as eight independent inout pins. For
    // inout-to-inout connectivity in Verilog we pass a concatenation of the
    // individual Pmod pins directly into the slave's port -- each AD[i]
    // becomes the same net as the matching JB pin, and Vivado infers a
    // single IOB tristate buffer per pin. No intermediate wire is needed.
    //
    // Bit ordering:
    //   AD[0] -> JB pin 1     AD[4] -> JB pin 7
    //   AD[1] -> JB pin 2     AD[5] -> JB pin 8
    //   AD[2] -> JB pin 3     AD[6] -> JB pin 9
    //   AD[3] -> JB pin 4     AD[7] -> JB pin 10

    //--------------------------------------------------------------------------
    // Bus slave instantiation
    //--------------------------------------------------------------------------
    lbtiny_bus_slave u_slave (
        .CLK    (clk_4mhz),
        .RESET_n(RESET_n),
        .A      (A),
        .AD     ({JB_AD_HI[10], JB_AD_HI[9], JB_AD_HI[8], JB_AD_HI[7],
                  JB_AD_LO[4],  JB_AD_LO[3], JB_AD_LO[2], JB_AD_LO[1]}),
        .ALE    (ALE),
        .RD_n   (RD_n),
        .WR_n   (WR_n)
    );

    //--------------------------------------------------------------------------
    // Debug shadow: replicate the slave's address latch so we can drive LEDs
    //--------------------------------------------------------------------------
    // We can't peek inside the slave from here without adding debug ports,
    // so we mirror its transparent-latch behaviour on the same input
    // signals. This costs ~12 flops; the LED outputs match the slave.

    // Read-only observation of the AD bus for the debug latch (no driver).
    wire [7:0] AD_observe = {JB_AD_HI[10], JB_AD_HI[9], JB_AD_HI[8], JB_AD_HI[7],
                             JB_AD_LO[4],  JB_AD_LO[3], JB_AD_LO[2], JB_AD_LO[1]};

    reg [7:0] dbg_ad_low = 8'h00;
    always @(posedge clk_4mhz or negedge RESET_n) begin
        if (!RESET_n)      dbg_ad_low <= 8'h00;
        else if (ALE)      dbg_ad_low <= AD_observe;
    end
    wire [11:0] dbg_addr = {A, dbg_ad_low};

    wire dbg_cs_rom  = (dbg_addr <= 12'hBFF);
    wire dbg_cs_ram  = (dbg_addr >= 12'hC00) && (dbg_addr <= 12'hEFF);
    wire dbg_cs_mmio = (dbg_addr >= 12'hF00);
    wire dbg_drive_en = (RD_n == 1'b0) && (dbg_cs_rom || dbg_cs_ram || dbg_cs_mmio);

    //--------------------------------------------------------------------------
    // LED drive
    //--------------------------------------------------------------------------
    // LED[11:0]  = latched address (most recent bus cycle target)
    // LED[12]    = cs_rom
    // LED[13]    = cs_ram
    // LED[14]    = cs_mmio
    // LED[15]    = drive_en  (lit when slave is driving AD on a read)

    assign LED[11:0] = dbg_addr;
    assign LED[12]   = dbg_cs_rom;
    assign LED[13]   = dbg_cs_ram;
    assign LED[14]   = dbg_cs_mmio;
    assign LED[15]   = dbg_drive_en;

endmodule

`default_nettype wire