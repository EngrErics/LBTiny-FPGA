//==============================================================================
// lbtiny_top.v
//------------------------------------------------------------------------------
// Production top-level for LBTiny on the Digilent Nexys A7.
//
// Integrates:
//   lbtiny_cpu    — 8-bit CPU (placeholder until real implementation)
//   lbtiny_mem    — memory subsystem (ROM, RAM, MMIO, peek ports)
//   lbtiny_viewer — live observation and mutation (BTNC/BTNU) via peek port
//
// Reset logic:
//   cpu_reset_n = stm32_reset_n & ~sw15_synced
//   Any source can hold the CPU in reset. The CPU only runs when all release.
//   SW15 up   -> CPU halted, viewer mutation (BTNC/BTNU) enabled.
//   SW15 down -> CPU running, viewer observation live, mutation blocked.
//   STM32 asserting RESET_n (Pmod JA pin 10 low) -> CPU halted, STM32 owns bus.
//
// Pmod assignments:
//   JA (control + upper address, all inputs from STM32 when active):
//     pin 1  -> A[8]    (JA_AB[1])
//     pin 2  -> A[9]    (JA_AB[2])
//     pin 3  -> A[10]   (JA_AB[3])
//     pin 4  -> A[11]   (JA_AB[4])
//     pin 7  -> ALE     (JA_CTL[7])
//     pin 8  -> RD_n    (JA_CTL[8])
//     pin 9  -> WR_n    (JA_CTL[9])
//     pin 10 -> RESET_n (JA_CTL[10]) — STM32 drives low to take the bus
//
//   JB (multiplexed address/data, bidirectional):
//     pins 1-4   -> AD[0..3]
//     pins 7-10  -> AD[4..7]
//
// Bus ownership:
//   When cpu_reset_n is high (CPU running):
//     CPU drives A, AD, ALE, RD_n, WR_n. Pmod JA/JB are inputs from outside
//     but are not expected to be driven (STM32 must tri-state when not active).
//   When cpu_reset_n is low (CPU halted):
//     STM32 (via Pmod) or viewer FSM (via SW15) drives the bus.
//     It is the operator's responsibility not to use both simultaneously.
//
// LED[15] is overridden here to show cpu_reset_n (CPU halted indicator),
// which is more useful in the production context than viewer_busy alone.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module lbtiny_top (
    input  wire        CLK100MHZ,

    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNU,

    output wire [15:0] LED,

    output wire        CA,
    output wire        CB,
    output wire        CC,
    output wire        CD,
    output wire        CE,
    output wire        CF,
    output wire        CG,
    output wire        DP,
    output wire [7:0]  AN,

    // Pmod JA — upper address + bus control (STM32 drives when active)
    input  wire [4:1]  JA_AB,     // A[8..11]
    input  wire [10:7] JA_CTL,    // ALE, RD_n, WR_n, RESET_n

    // Pmod JB — multiplexed address/data (bidirectional)
    inout  wire [4:1]  JB_AD_LO,  // AD[0..3]
    inout  wire [10:7] JB_AD_HI   // AD[4..7]
);

    //--------------------------------------------------------------------------
    // Clock divider: 100 MHz -> ~3.846 MHz bus clock (divide by 26)
    //--------------------------------------------------------------------------
    reg [4:0] clk_div_cnt;
    reg       clk_bus;

    initial begin clk_div_cnt = 5'd0; clk_bus = 1'b0; end

    always @(posedge CLK100MHZ) begin
        if (clk_div_cnt == 5'd12) begin
            clk_div_cnt <= 5'd0;
            clk_bus     <= ~clk_bus;
        end else begin
            clk_div_cnt <= clk_div_cnt + 5'd1;
        end
    end

    //--------------------------------------------------------------------------
    // SW15 synchronizer (2-FF into clk_bus domain)
    //--------------------------------------------------------------------------
    reg sw15_q1, sw15_q2;
    initial begin sw15_q1 = 1'b0; sw15_q2 = 1'b0; end

    always @(posedge clk_bus) begin
        sw15_q1 <= SW[15];
        sw15_q2 <= sw15_q1;
    end

    //--------------------------------------------------------------------------
    // Power-on memory reset
    //--------------------------------------------------------------------------
    // lbtiny_mem's RESET_n only clears its internal control state (address
    // latch, flash command FSM, write-strobe edge detector). It does NOT
    // clear BRAM contents. We assert it for a few cycles after power-on to
    // make sure the flash FSM starts in S_IDLE, then leave it high forever.
    //
    // Critically, mem_reset_n must NOT track cpu_reset_n: when the viewer
    // (SW15 up) or the STM32 (Pmod RESET_n low) takes the bus, the CPU is
    // held in reset but the memory must remain operational so the new master
    // can read and write through it.
    reg        mem_reset_n;
    reg [5:0]  mem_reset_count;
    initial begin mem_reset_n = 1'b0; mem_reset_count = 6'd0; end

    always @(posedge clk_bus) begin
        if (!mem_reset_n) begin
            mem_reset_count <= mem_reset_count + 6'd1;
            if (mem_reset_count == 6'd40)
                mem_reset_n <= 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // Combined CPU reset logic
    // stm32_reset_n: Pmod JA pin 10, active low (STM32 pulls low to take bus)
    // sw15_q2:       SW15 up = halt CPU (active high)
    // cpu_reset_n:   low when either source requests halt
    //
    // This drives the CPU's reset (so it tristates) and the bus mux's
    // "cpu_halted" select. It does NOT drive the memory reset — see above.
    //--------------------------------------------------------------------------
    wire stm32_reset_n = JA_CTL[10];
    wire cpu_reset_n   = stm32_reset_n & ~sw15_q2;
    wire cpu_halted    = ~cpu_reset_n;

    //--------------------------------------------------------------------------
    // CPU bus signals
    //--------------------------------------------------------------------------
    wire [3:0] cpu_A;
    wire [7:0] cpu_AD;
    wire       cpu_ALE;
    wire       cpu_RD_n;
    wire       cpu_WR_n;

    //--------------------------------------------------------------------------
    // Viewer bus master signals
    //--------------------------------------------------------------------------
    wire [3:0] viewer_bus_A;
    wire       viewer_bus_ALE;
    wire       viewer_bus_RD_n;
    wire       viewer_bus_WR_n;
    wire [7:0] viewer_ad_out;
    wire       viewer_ad_oe;

    //--------------------------------------------------------------------------
    // STM32 Pmod bus signals (inputs from JA when STM32 owns the bus)
    //--------------------------------------------------------------------------
    // stm32_reset_n=0  =>  STM32 has pulled RESET_n low and is bus master.
    // JA_AB[4:1] carry A[11:8]; JA_CTL[7:9] carry ALE / RD_n / WR_n.
    wire stm32_owns  = ~stm32_reset_n;

    wire [3:0] stm32_A    = {JA_AB[4],  JA_AB[3],  JA_AB[2],  JA_AB[1]};
    wire       stm32_ALE  = JA_CTL[7];
    wire       stm32_RD_n = JA_CTL[8];
    wire       stm32_WR_n = JA_CTL[9];

    //--------------------------------------------------------------------------
    // Bus mux — three-way:
    //   STM32 owns  (stm32_reset_n=0) : Pmod JA drives lbtiny_mem
    //   SW15 halt   (sw15_q2=1)       : viewer FSM drives lbtiny_mem
    //   CPU running (cpu_reset_n=1)   : CPU drives lbtiny_mem
    //
    // STM32 takes priority over viewer when both halt sources are active
    // (operator error, but we fail safe rather than fight over the bus).
    //--------------------------------------------------------------------------
    wire [3:0] mem_A    = stm32_owns ? stm32_A        :
                          cpu_halted ? viewer_bus_A    : cpu_A;
    wire       mem_ALE  = stm32_owns ? stm32_ALE       :
                          cpu_halted ? viewer_bus_ALE  : cpu_ALE;
    wire       mem_RD_n = stm32_owns ? stm32_RD_n      :
                          cpu_halted ? viewer_bus_RD_n : cpu_RD_n;
    wire       mem_WR_n = stm32_owns ? stm32_WR_n      :
                          cpu_halted ? viewer_bus_WR_n : cpu_WR_n;

    // AD bus drive mux:
    //   STM32 owns  -> release ad_bus from the FPGA side (STM32 drives JB
    //                  externally on writes; lbtiny_mem drives back on reads)
    //   viewer owns -> viewer_ad_out when viewer_ad_oe asserted, else Z
    //   CPU runs    -> CPU drives AD (cpu_AD is an inout driven by u_cpu)
    wire [7:0] mem_ad_out = cpu_halted ? viewer_ad_out : cpu_AD;
    wire       mem_ad_oe  = stm32_owns ? 1'b0          :
                            cpu_halted ? viewer_ad_oe   : 1'b1;

    //--------------------------------------------------------------------------
    // Memory AD wire — shared by lbtiny_mem, viewer/CPU, and Pmod JB.
    // When mem_ad_oe=1 the FPGA side drives (viewer write or CPU).
    // When mem_ad_oe=0 the FPGA side releases; either the STM32 drives JB
    // from outside (write phase) or lbtiny_mem's own tristate responds
    // (read data phase, same regardless of which master issued the read).
    //--------------------------------------------------------------------------
    wire [7:0] ad_bus;
    assign ad_bus = mem_ad_oe ? mem_ad_out : 8'hzz;

    //--------------------------------------------------------------------------
    // Peek wires
    //--------------------------------------------------------------------------
    wire [11:0] peek_addr;
    wire [7:0]  peek_data;

    //--------------------------------------------------------------------------
    // Memory subsystem
    //--------------------------------------------------------------------------
    lbtiny_mem u_mem (
        .CLK      (clk_bus),
        .RESET_n  (mem_reset_n),
        .A        (mem_A),
        .AD       (ad_bus),
        .ALE      (mem_ALE),
        .RD_n     (mem_RD_n),
        .WR_n     (mem_WR_n),
        .peek_addr(peek_addr),
        .peek_data(peek_data)
    );

    //--------------------------------------------------------------------------
    // CPU
    //--------------------------------------------------------------------------
    lbtiny_cpu u_cpu (
        .CLK     (clk_bus),
        .RESET_n (cpu_reset_n),
        .A       (cpu_A),
        .AD      (cpu_AD),
        .ALE     (cpu_ALE),
        .RD_n    (cpu_RD_n),
        .WR_n    (cpu_WR_n),
        .INT     (1'b0)        // No interrupt source yet
    );

    //--------------------------------------------------------------------------
    // Viewer subsystem
    //--------------------------------------------------------------------------
    wire [15:0] viewer_LED;
    wire        viewer_busy;
    wire        fill_busy;

    lbtiny_viewer u_viewer (
        .CLK100MHZ  (CLK100MHZ),
        .clk_bus    (clk_bus),
        .cpu_halted (cpu_halted),
        .SW         (SW),
        .BTNC       (BTNC),
        .BTNU       (BTNU),
        .peek_addr  (peek_addr),
        .peek_data  (peek_data),
        .bus_A      (viewer_bus_A),
        .bus_ALE    (viewer_bus_ALE),
        .bus_RD_n   (viewer_bus_RD_n),
        .bus_WR_n   (viewer_bus_WR_n),
        .ad_in      (ad_bus),
        .ad_out     (viewer_ad_out),
        .ad_oe      (viewer_ad_oe),
        .LED        (viewer_LED),
        .CA         (CA),
        .CB         (CB),
        .CC         (CC),
        .CD         (CD),
        .CE         (CE),
        .CF         (CF),
        .CG         (CG),
        .DP         (DP),
        .AN         (AN),
        .viewer_busy(viewer_busy),
        .fill_busy  (fill_busy)
    );

    //--------------------------------------------------------------------------
    // LED assignments
    // viewer_LED[14:0] pass through from viewer (addr, region, fill_busy).
    // LED[15] overridden: shows cpu_halted (CPU in reset indicator).
    // When SW15 is up or STM32 holds reset, LED[15] lights — a clear reminder
    // that the CPU is not running.
    //--------------------------------------------------------------------------
    assign LED[14:0] = viewer_LED[14:0];
    assign LED[15]   = cpu_halted;

    //--------------------------------------------------------------------------
    // Pmod JA/JB — live connection to lbtiny_mem via ad_bus
    //--------------------------------------------------------------------------
    // JA pins (A[11:8], ALE, RD_n, WR_n, RESET_n) are pure inputs to the
    // FPGA; they are consumed by the bus mux above and by the reset logic.
    // No assign needed — the wires stm32_A/ALE/RD_n/WR_n already reference
    // JA_AB and JA_CTL directly.  Suppress the unused-input lint warning for
    // the one bit already consumed (JA_CTL[10] = stm32_reset_n).
    //
    // JB pins (AD[7:0]) are bidirectional.  They are tied directly to ad_bus
    // so that:
    //   - lbtiny_mem can drive read data out through JB to the STM32
    //   - the STM32 can drive write data in through JB to lbtiny_mem
    //   - the viewer and CPU use ad_bus internally (same net)
    //
    // Bit mapping (matches XDC and firmware):
    //   JB pin 1  (JB_AD_LO[1]) = AD[0]    JB pin 7  (JB_AD_HI[7])  = AD[4]
    //   JB pin 2  (JB_AD_LO[2]) = AD[1]    JB pin 8  (JB_AD_HI[8])  = AD[5]
    //   JB pin 3  (JB_AD_LO[3]) = AD[2]    JB pin 9  (JB_AD_HI[9])  = AD[6]
    //   JB pin 4  (JB_AD_LO[4]) = AD[3]    JB pin 10 (JB_AD_HI[10]) = AD[7]

    // Connect JB to ad_bus.  Each inout pin is tied directly to the matching
    // ad_bus bit.  Vivado infers one IOB tristate per bit:
    //   - driven   when lbtiny_mem asserts drive_en (read response)
    //   - driven   when viewer/CPU asserts mem_ad_oe (viewer write or CPU cycle)
    //   - floating when STM32 owns the bus (mem_ad_oe=0, drive_en=0), so the
    //              STM32's GPIO output reaches lbtiny_mem unimpeded
    assign JB_AD_LO[1] = ad_bus[0];
    assign JB_AD_LO[2] = ad_bus[1];
    assign JB_AD_LO[3] = ad_bus[2];
    assign JB_AD_LO[4] = ad_bus[3];
    assign JB_AD_HI[7]  = ad_bus[4];
    assign JB_AD_HI[8]  = ad_bus[5];
    assign JB_AD_HI[9]  = ad_bus[6];
    assign JB_AD_HI[10] = ad_bus[7];

endmodule

`default_nettype wire
