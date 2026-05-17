//==============================================================================
// lbtiny_bringup_top.v
//------------------------------------------------------------------------------
// Nexys A7 standalone bringup top for the LBTiny memory subsystem.
//
// This top exists to verify lbtiny_mem in isolation before CPU integration.
// There is no CPU here. The viewer's mutation FSM (BTNC/BTNU) is always
// enabled (cpu_halted tied high) so both observation and mutation are always
// available without any switch configuration.
//
// Use this build to:
//   - Confirm BRAM inference succeeds (check Vivado synthesis report).
//   - Verify flash command sequences (BTNU erase, BTNC fill, read back).
//   - Confirm peek port shows correct live data on 7-seg and LEDs.
//
// User interface (same as before refactor):
//   SW[11:0]  Address to observe (live, no bus transaction).
//   BTNC      Fill ROM+RAM with addr[7:0] using real bus protocol.
//   BTNU      Reinitialize: ROM chip-erase + RAM fill 0xFF.
//   LED[11:0] Viewed address.
//   LED[12]   Viewed address is in ROM range.
//   LED[13]   Viewed address is in RAM range.
//   LED[14]   Fill operation (BTNC) in progress.
//   LED[15]   Any init/fill operation in progress.
//   7-seg     Left group: address. Right group: data.
//
// SW[15:12] are unused in this build (no constraints needed for them).
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module lbtiny_bringup_top (
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
    output wire [7:0]  AN
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
    // Reset: viewer FSM holds memory in reset for 40 bus clocks on power-on,
    // then releases it and begins the init erase sequence.
    // In the bringup top there is no external RESET_n input; reset is driven
    // purely by the viewer's power-on init state.
    //--------------------------------------------------------------------------
    reg        mem_reset_n;
    reg [5:0]  reset_count;

    initial begin mem_reset_n = 1'b0; reset_count = 6'd0; end

    always @(posedge clk_bus) begin
        if (!mem_reset_n) begin
            reset_count <= reset_count + 6'd1;
            if (reset_count == 6'd40)
                mem_reset_n <= 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // Internal bus wires between viewer and memory
    //--------------------------------------------------------------------------
    wire [11:0] peek_addr;
    wire [7:0]  peek_data;

    wire [3:0]  bus_A;
    wire        bus_ALE;
    wire        bus_RD_n;
    wire        bus_WR_n;

    wire [7:0]  master_ad_out;
    wire        master_ad_oe;
    wire [7:0]  ad_bus;

    // Internal tristate: viewer drives when master_ad_oe=1, else releases.
    // Vivado synthesizes internal tristates as muxes on Artix-7.
    assign ad_bus = master_ad_oe ? master_ad_out : 8'hzz;

    //--------------------------------------------------------------------------
    // Memory subsystem
    //--------------------------------------------------------------------------
    lbtiny_mem u_mem (
        .CLK      (clk_bus),
        .RESET_n  (mem_reset_n),
        .A        (bus_A),
        .AD       (ad_bus),
        .ALE      (bus_ALE),
        .RD_n     (bus_RD_n),
        .WR_n     (bus_WR_n),
        .peek_addr(peek_addr),
        .peek_data(peek_data)
    );

    //--------------------------------------------------------------------------
    // Viewer subsystem
    // cpu_halted tied high: mutation (BTNC/BTNU) always available.
    //--------------------------------------------------------------------------
    lbtiny_viewer u_viewer (
        .CLK100MHZ  (CLK100MHZ),
        .clk_bus    (clk_bus),
        .cpu_halted (1'b1),
        .SW         (SW),
        .BTNC       (BTNC),
        .BTNU       (BTNU),
        .peek_addr  (peek_addr),
        .peek_data  (peek_data),
        .bus_A      (bus_A),
        .bus_ALE    (bus_ALE),
        .bus_RD_n   (bus_RD_n),
        .bus_WR_n   (bus_WR_n),
        .ad_in      (ad_bus),
        .ad_out     (master_ad_out),
        .ad_oe      (master_ad_oe),
        .LED        (LED),
        .CA         (CA),
        .CB         (CB),
        .CC         (CC),
        .CD         (CD),
        .CE         (CE),
        .CF         (CF),
        .CG         (CG),
        .DP         (DP),
        .AN         (AN),
        .viewer_busy(),
        .fill_busy  ()
    );

endmodule

`default_nettype wire
