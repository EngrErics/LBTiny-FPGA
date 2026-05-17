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
    // Combined reset logic
    // stm32_reset_n: Pmod JA pin 10, active low (STM32 pulls low to take bus)
    // sw15_q2:       SW15 up = halt CPU (active high)
    // cpu_reset_n:   low when either source requests halt
    //--------------------------------------------------------------------------
    wire stm32_reset_n = JA_CTL[10];
    wire cpu_reset_n   = stm32_reset_n & ~sw15_q2;
    wire cpu_halted    = ~cpu_reset_n;

    //--------------------------------------------------------------------------
    // CPU bus signals
    // cpu_AD is not declared separately — the CPU's AD inout connects directly
    // to ad_bus so the CPU drives and reads the shared bus natively.
    //--------------------------------------------------------------------------
    wire [3:0] cpu_A;
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
    // Bus mux: viewer drives when cpu_halted, CPU drives when running.
    // The STM32 drives the Pmod pins externally when it takes the bus
    // (also during cpu_halted). SW15 and STM32 must not be used simultaneously
    // — this is a procedural constraint, not enforced in hardware.
    //--------------------------------------------------------------------------
    wire [3:0] mem_A   = cpu_halted ? viewer_bus_A   : cpu_A;
    wire       mem_ALE = cpu_halted ? viewer_bus_ALE  : cpu_ALE;
    wire       mem_RD_n = cpu_halted ? viewer_bus_RD_n : cpu_RD_n;
    wire       mem_WR_n = cpu_halted ? viewer_bus_WR_n : cpu_WR_n;

    // AD bus: viewer drives when cpu_halted and viewer_ad_oe asserted.
    // When CPU is running, the CPU drives AD directly through its inout port
    // connected to ad_bus — mem_ad_oe must be 0 so the mux does not contend.
    wire [7:0] mem_ad_out = viewer_ad_out;
    wire       mem_ad_oe  = cpu_halted & viewer_ad_oe;

    //--------------------------------------------------------------------------
    // Memory AD wire
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
        .RESET_n  (cpu_reset_n),
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
        .AD      (ad_bus),
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
    // Pmod JA/JB: exposed for STM32 supervisor bus access.
    // When the STM32 takes the bus (cpu_reset_n low, driven externally),
    // it drives JA_AB, JA_CTL[7:9], and JB_AD bidirectionally.
    // These ports are declared as inputs/inout in the module boundary;
    // the STM32 is the external driver. The CPU is held in reset during this.
    //--------------------------------------------------------------------------
    // JA pins are input-only from FPGA perspective (STM32 drives them).
    // JB pins are bidirectional but are only driven by the STM32 externally;
    // they are left undriven here (the memory's internal AD bus is separate).
    // These ports exist purely to satisfy the XDC pin constraints and reserve
    // the physical pins for the reference board harness.

    // Suppress unused-input warnings for Pmod ports not yet connected to logic.
    wire [3:0]  ja_ab_unused  = JA_AB;
    wire [10:7] ja_ctl_unused = JA_CTL;   // [10] consumed above as stm32_reset_n

    // JB bidirectional pins are reserved for the reference board.
    // In this FPGA-only build, external bus access from the STM32 goes through
    // Pmod JB but the internal logic uses ad_bus instead. Connecting them
    // requires a physical wire harness on the board; leave as stubs for now.
    assign JB_AD_LO = 4'bz;
    assign JB_AD_HI = 4'bz;

endmodule

`default_nettype wire
