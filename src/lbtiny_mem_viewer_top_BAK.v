//==============================================================================
// lbtiny_mem_viewer_top.v
//------------------------------------------------------------------------------
// Nexys A7 standalone memory viewer/programmer for lbtiny_bus_slave.
//
// This is a separate debug top.  It does not use the external Pmod bus.
// Instead it instantiates the normal lbtiny_bus_slave and drives its 8085-style
// multiplexed bus from an internal bus-master FSM.
//
// User interface:
//   SW[11:0] selects the address to view.
//   Left  seven-seg group shows the selected 12-bit address as hex.
//   Right seven-seg group shows the byte read from memory as hex.
//   BTNC fills ROM/RAM with addr[7:0] using the real bus protocol.
//   BTNU reinitializes: ROM erase command sequence + RAM filled with 0xFF.
//
//   LED[11:0]  = viewed_addr
//   LED[12]    = viewed_addr is in ROM range
//   LED[13]    = viewed_addr is in RAM range
//   LED[14]    = viewer is busy doing a fill (BTNC) operation
//   LED[15]    = viewer is busy doing any operation (init, fill, etc.)
//
// Memory map behavior remains the same as lbtiny_bus_slave:
//   0x000-0xBFF : ROM / flash model; programmed using AA,55,A0,<data>
//   0xC00-0xEFF : RAM; written directly
//   0xF00-0xFFF : MMIO stub; reads as 0x00 and writes ignored
//
// 2026-05-16 revision:
//   - LED[14] is now a dedicated "fill in progress" diagnostic light.
//   - Both buttons go through a counter-based debouncer that also rejects a
//     button while the *other* button is held, eliminating mechanical
//     cross-talk between adjacent BTNC and BTNU on the Nexys A7.
//   - Switch synchronizer trimmed from 16 to 12 bits to match how it is
//     consumed (cosmetic, removes a synthesis warning).
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module lbtiny_mem_viewer_top (
    input  wire        CLK100MHZ,

    input  wire [15:0] SW,
    input  wire        BTNC,      // fill memory with addr[7:0]
    input  wire        BTNU,      // reinitialize to blank pattern

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
    // Clock divider: 100 MHz -> approximately 3.846 MHz bus clock.
    //--------------------------------------------------------------------------
    reg [4:0] clk_div_cnt = 5'd0;
    reg       clk_bus     = 1'b0;

    always @(posedge CLK100MHZ) begin
        if (clk_div_cnt == 5'd12) begin
            clk_div_cnt <= 5'd0;
            clk_bus     <= ~clk_bus;
        end else begin
            clk_div_cnt <= clk_div_cnt + 5'd1;
        end
    end

    //--------------------------------------------------------------------------
    // Synchronize switches into the bus-clock domain. Only the low 12 bits are
    // actually used as the selected address, so trim to that width to avoid
    // the "unconnected register bits" synthesis warning.
    //--------------------------------------------------------------------------
    reg [11:0] sw_q1 = 12'h000, sw_q2 = 12'h000;

    always @(posedge clk_bus) begin
        sw_q1 <= SW[11:0];
        sw_q2 <= sw_q1;
    end

    //--------------------------------------------------------------------------
    // Button debouncing.
    //
    // Two-stage metastability synchronizer + counter debouncer. The button is
    // considered "stable" when it has held the same value for DEBOUNCE_TICKS
    // bus clocks (~4 ms at 3.846 MHz). The rising-edge pulse is one bus clock
    // wide and fires only after the button has stabilized in the high state.
    //
    // We also gate each button's rise pulse with the *other* button's level,
    // so a press of BTNC that mechanically jiggles BTNU (and vice versa) is
    // not interpreted as a real press of the second button.
    //--------------------------------------------------------------------------
    localparam [15:0] DEBOUNCE_TICKS = 16'd16000;  // ~4.2 ms at 3.846 MHz

    reg btnc_s1 = 1'b0, btnc_s2 = 1'b0;
    reg btnu_s1 = 1'b0, btnu_s2 = 1'b0;

    always @(posedge clk_bus) begin
        btnc_s1 <= BTNC;
        btnc_s2 <= btnc_s1;
        btnu_s1 <= BTNU;
        btnu_s2 <= btnu_s1;
    end

    reg [15:0] btnc_cnt = 16'd0;
    reg        btnc_stable = 1'b0;       // debounced level
    reg        btnc_stable_q = 1'b0;     // one-cycle-delayed level

    reg [15:0] btnu_cnt = 16'd0;
    reg        btnu_stable = 1'b0;
    reg        btnu_stable_q = 1'b0;

    always @(posedge clk_bus) begin
        // BTNC debouncer
        if (btnc_s2 == btnc_stable) begin
            btnc_cnt <= 16'd0;
        end else if (btnc_cnt == DEBOUNCE_TICKS) begin
            btnc_stable <= btnc_s2;
            btnc_cnt    <= 16'd0;
        end else begin
            btnc_cnt <= btnc_cnt + 16'd1;
        end
        btnc_stable_q <= btnc_stable;

        // BTNU debouncer
        if (btnu_s2 == btnu_stable) begin
            btnu_cnt <= 16'd0;
        end else if (btnu_cnt == DEBOUNCE_TICKS) begin
            btnu_stable <= btnu_s2;
            btnu_cnt    <= 16'd0;
        end else begin
            btnu_cnt <= btnu_cnt + 16'd1;
        end
        btnu_stable_q <= btnu_stable;
    end

    // Rising-edge pulses, cross-masked so a held BTNU blocks BTNC and vice
    // versa. This prevents adjacent-button cross-talk from triggering an
    // unintended re-init right after a fill (or vice versa).
    wire btnc_rise = btnc_stable & ~btnc_stable_q & ~btnu_stable;
    wire btnu_rise = btnu_stable & ~btnu_stable_q & ~btnc_stable;

    //--------------------------------------------------------------------------
    // Internal 8085-style bus wires between master FSM and lbtiny_bus_slave.
    //--------------------------------------------------------------------------
    wire [7:0] ad_bus;
    wire [7:0] ad_from_slave_or_z = ad_bus;

    wire [3:0] bus_A;
    wire       bus_ALE;
    wire       bus_RD_n;
    wire       bus_WR_n;
    reg        bus_RESET_n = 1'b0;

    wire [7:0] master_ad_out;
    wire       master_ad_oe;

    assign ad_bus = master_ad_oe ? master_ad_out : 8'hzz;

    lbtiny_bus_slave u_slave (
        .CLK     (clk_bus),
        .RESET_n (bus_RESET_n),
        .A       (bus_A),
        .AD      (ad_bus),
        .ALE     (bus_ALE),
        .RD_n    (bus_RD_n),
        .WR_n    (bus_WR_n)
    );

    //--------------------------------------------------------------------------
    // One-transaction bus master.
    //--------------------------------------------------------------------------
    reg        txn_start = 1'b0;
    reg        txn_write = 1'b0;
    reg [11:0] txn_addr  = 12'h000;
    reg [7:0]  txn_wdata = 8'h00;
    wire       txn_busy;
    wire       txn_done;
    wire [7:0] txn_rdata;

    lbtiny_bus_master_txn u_txn (
        .CLK        (clk_bus),
        .RESET_n    (bus_RESET_n),
        .start      (txn_start),
        .write      (txn_write),
        .addr       (txn_addr),
        .wdata      (txn_wdata),
        .busy       (txn_busy),
        .done       (txn_done),
        .rdata      (txn_rdata),

        .bus_A      (bus_A),
        .bus_ALE    (bus_ALE),
        .bus_RD_n   (bus_RD_n),
        .bus_WR_n   (bus_WR_n),
        .ad_in      (ad_from_slave_or_z),
        .ad_out     (master_ad_out),
        .ad_oe      (master_ad_oe)
    );

    //--------------------------------------------------------------------------
    // High-level controller: init, fill, and repeated read/view cycles.
    //--------------------------------------------------------------------------
    localparam [5:0]
        S_RESET_HOLD       = 6'd0,
        S_INIT_ERASE_NEXT  = 6'd1,
        S_INIT_ERASE_ADV   = 6'd2,
        S_INIT_ERASE_WAIT  = 6'd3,
        S_INIT_RAM_NEXT    = 6'd4,
        S_INIT_RAM_ADV     = 6'd5,
        S_IDLE             = 6'd6,
        S_READ_ISSUE       = 6'd7,
        S_FILL_NEXT        = 6'd8,
        S_FILL_ADV         = 6'd9,
        S_ISSUE            = 6'd10,
        S_WAIT             = 6'd11;

    reg [5:0] state        = S_RESET_HOLD;
    reg [5:0] return_state = S_IDLE;

    reg [7:0]  reset_count = 8'd0;
    reg [12:0] wait_count  = 13'd0;
    reg [11:0] fill_addr   = 12'h000;
    reg [2:0]  step        = 3'd0;
    reg        viewer_busy = 1'b1;
    reg        fill_busy   = 1'b0;     // dedicated diagnostic: BTNC fill in progress

    reg [11:0] viewed_addr = 12'h000;
    reg [7:0]  viewed_data = 8'hFF;

    wire [11:0] selected_addr = sw_q2;

    // Transaction operation registers used by S_ISSUE/S_WAIT.
    reg        op_write = 1'b0;
    reg [11:0] op_addr  = 12'h000;
    reg [7:0]  op_data  = 8'h00;

    always @(posedge clk_bus) begin
        txn_start <= 1'b0;

        case (state)
            //------------------------------------------------------------------
            S_RESET_HOLD: begin
                viewer_busy <= 1'b1;
                fill_busy   <= 1'b0;
                bus_RESET_n <= 1'b0;
                reset_count <= reset_count + 8'd1;
                if (reset_count == 8'd40) begin
                    bus_RESET_n <= 1'b1;
                    step        <= 3'd0;
                    state       <= S_INIT_ERASE_NEXT;
                end
            end

            //------------------------------------------------------------------
            // On power-up or BTNU: issue the real flash erase command sequence.
            //------------------------------------------------------------------
            S_INIT_ERASE_NEXT: begin
                viewer_busy <= 1'b1;
                op_write <= 1'b1;
                return_state <= S_INIT_ERASE_ADV;
                case (step)
                    3'd0: begin op_addr <= 12'h555; op_data <= 8'hAA; state <= S_ISSUE; end
                    3'd1: begin op_addr <= 12'h2AA; op_data <= 8'h55; state <= S_ISSUE; end
                    3'd2: begin op_addr <= 12'h555; op_data <= 8'h80; state <= S_ISSUE; end
                    3'd3: begin op_addr <= 12'h555; op_data <= 8'hAA; state <= S_ISSUE; end
                    3'd4: begin op_addr <= 12'h2AA; op_data <= 8'h55; state <= S_ISSUE; end
                    3'd5: begin op_addr <= 12'h000; op_data <= 8'h30; state <= S_ISSUE; end
                    default: begin
                        wait_count <= 13'd0;
                        state      <= S_INIT_ERASE_WAIT;
                    end
                endcase
            end

            S_INIT_ERASE_ADV: begin
                step  <= step + 3'd1;
                state <= S_INIT_ERASE_NEXT;
            end

            S_INIT_ERASE_WAIT: begin
                // The slave erase walker takes 3072 bus clocks for 0x000-0xBFF.
                wait_count <= wait_count + 13'd1;
                if (wait_count == 13'd3300) begin
                    fill_addr <= 12'hC00;
                    state     <= S_INIT_RAM_NEXT;
                end
            end

            //------------------------------------------------------------------
            // Fill RAM with FF so the whole readable memory range looks blank.
            //------------------------------------------------------------------
            S_INIT_RAM_NEXT: begin
                viewer_busy <= 1'b1;
                if (fill_addr <= 12'hEFF) begin
                    op_write     <= 1'b1;
                    op_addr      <= fill_addr;
                    op_data      <= 8'hFF;
                    return_state <= S_INIT_RAM_ADV;
                    state        <= S_ISSUE;
                end else begin
                    viewer_busy <= 1'b0;
                    state       <= S_IDLE;
                end
            end

            S_INIT_RAM_ADV: begin
                fill_addr <= fill_addr + 12'd1;
                state     <= S_INIT_RAM_NEXT;
            end

            //------------------------------------------------------------------
            // Idle/viewer loop. Button presses preempt the next viewer read.
            //------------------------------------------------------------------
            S_IDLE: begin
                viewer_busy <= 1'b0;
                fill_busy   <= 1'b0;
                if (btnc_rise) begin
                    viewer_busy <= 1'b1;
                    fill_busy   <= 1'b1;
                    fill_addr   <= 12'h000;
                    step        <= 3'd0;
                    state       <= S_FILL_NEXT;
                end else if (btnu_rise) begin
                    viewer_busy <= 1'b1;
                    step        <= 3'd0;
                    state       <= S_INIT_ERASE_NEXT;
                end else begin
                    op_write     <= 1'b0;
                    op_addr      <= selected_addr;
                    op_data      <= 8'h00;
                    return_state <= S_IDLE;
                    state        <= S_READ_ISSUE;
                end
            end

            S_READ_ISSUE: begin
                state <= S_ISSUE;
            end

            //------------------------------------------------------------------
            // Fill ROM/RAM with repeating 00..FF using real bus protocol.
            //------------------------------------------------------------------
            S_FILL_NEXT: begin
                viewer_busy <= 1'b1;
                fill_busy   <= 1'b1;

                if (fill_addr <= 12'hBFF) begin
                    // ROM programming sequence: AA@555, 55@2AA, A0@555, D@addr
                    op_write     <= 1'b1;
                    return_state <= S_FILL_ADV;
                    case (step)
                        3'd0: begin op_addr <= 12'h555; op_data <= 8'hAA;          state <= S_ISSUE; end
                        3'd1: begin op_addr <= 12'h2AA; op_data <= 8'h55;          state <= S_ISSUE; end
                        3'd2: begin op_addr <= 12'h555; op_data <= 8'hA0;          state <= S_ISSUE; end
                        default: begin op_addr <= fill_addr; op_data <= fill_addr[7:0]; state <= S_ISSUE; end
                    endcase
                end else if (fill_addr <= 12'hEFF) begin
                    // RAM writes directly.
                    op_write     <= 1'b1;
                    op_addr      <= fill_addr;
                    op_data      <= fill_addr[7:0];
                    return_state <= S_FILL_ADV;
                    state        <= S_ISSUE;
                end else begin
                    viewer_busy <= 1'b0;
                    fill_busy   <= 1'b0;
                    state       <= S_IDLE;
                end
            end

            S_FILL_ADV: begin
                if (fill_addr <= 12'hBFF) begin
                    if (step == 3'd3) begin
                        step      <= 3'd0;
                        fill_addr <= fill_addr + 12'd1;
                    end else begin
                        step <= step + 3'd1;
                    end
                end else begin
                    fill_addr <= fill_addr + 12'd1;
                end
                state <= S_FILL_NEXT;
            end

            //------------------------------------------------------------------
            // Shared transaction issue/wait states.
            //------------------------------------------------------------------
            S_ISSUE: begin
                if (!txn_busy) begin
                    txn_write <= op_write;
                    txn_addr  <= op_addr;
                    txn_wdata <= op_data;
                    txn_start <= 1'b1;
                    state     <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (txn_done) begin
                    if (!op_write) begin
                        viewed_addr <= op_addr;
                        viewed_data <= txn_rdata;
                    end
                    state <= return_state;
                end
            end

            default: state <= S_RESET_HOLD;
        endcase
    end

    //--------------------------------------------------------------------------
    // LEDs: address decode and status.
    //--------------------------------------------------------------------------
    assign LED[11:0] = viewed_addr;
    assign LED[12]   = (viewed_addr <= 12'hBFF);                              // ROM
    assign LED[13]   = (viewed_addr >= 12'hC00) && (viewed_addr <= 12'hEFF);  // RAM
    assign LED[14]   = fill_busy;     // Diagnostic: BTNC fill in progress
    assign LED[15]   = viewer_busy;   // Any init/fill/transaction in progress

    //--------------------------------------------------------------------------
    // Seven-segment display: "_ABC__DE" where ABC=address, DE=data.
    //--------------------------------------------------------------------------
    wire [6:0] seg;
    assign {CA, CB, CC, CD, CE, CF, CG} = seg;

    lbtiny_hex7seg_mux u_7seg (
        .CLK100MHZ (CLK100MHZ),
        .addr      (viewed_addr),
        .data      (viewed_data),
        .seg       (seg),
        .dp        (DP),
        .an        (AN)
    );

endmodule

//==============================================================================
// Single bus transaction generator.
//==============================================================================
module lbtiny_bus_master_txn (
    input  wire       CLK,
    input  wire       RESET_n,

    input  wire       start,
    input  wire       write,
    input  wire [11:0] addr,
    input  wire [7:0] wdata,
    output reg        busy,
    output reg        done,
    output reg [7:0]  rdata,

    output reg [3:0]  bus_A,
    output reg        bus_ALE,
    output reg        bus_RD_n,
    output reg        bus_WR_n,
    input  wire [7:0] ad_in,
    output reg [7:0]  ad_out,
    output reg        ad_oe
);

    localparam [3:0]
        T_IDLE   = 4'd0,
        T_ADDR   = 4'd1,
        T_HOLD   = 4'd2,
        T_WDATA  = 4'd3,
        T_WLOW   = 4'd4,
        T_WHIGH  = 4'd5,
        T_RTURN  = 4'd6,
        T_RLOW   = 4'd7,
        T_RHIGH  = 4'd8,
        T_DONE   = 4'd9;

    reg [3:0]  tstate;
    reg [3:0]  count;
    reg        lat_write;
    reg [11:0] lat_addr;
    reg [7:0]  lat_wdata;

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            tstate    <= T_IDLE;
            count     <= 4'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            rdata     <= 8'h00;
            bus_A     <= 4'h0;
            bus_ALE   <= 1'b0;
            bus_RD_n  <= 1'b1;
            bus_WR_n  <= 1'b1;
            ad_out    <= 8'h00;
            ad_oe     <= 1'b0;
            lat_write <= 1'b0;
            lat_addr  <= 12'h000;
            lat_wdata <= 8'h00;
        end else begin
            done <= 1'b0;

            case (tstate)
                T_IDLE: begin
                    busy     <= 1'b0;
                    bus_ALE  <= 1'b0;
                    bus_RD_n <= 1'b1;
                    bus_WR_n <= 1'b1;
                    ad_oe    <= 1'b0;

                    if (start) begin
                        lat_write <= write;
                        lat_addr  <= addr;
                        lat_wdata <= wdata;
                        busy      <= 1'b1;
                        count     <= 4'd0;
                        tstate    <= T_ADDR;
                    end
                end

                T_ADDR: begin
                    busy     <= 1'b1;
                    bus_A    <= lat_addr[11:8];
                    ad_out   <= lat_addr[7:0];
                    ad_oe    <= 1'b1;
                    bus_ALE  <= 1'b1;
                    bus_RD_n <= 1'b1;
                    bus_WR_n <= 1'b1;
                    count    <= count + 4'd1;
                    if (count == 4'd2) begin
                        count  <= 4'd0;
                        tstate <= T_HOLD;
                    end
                end

                T_HOLD: begin
                    bus_ALE <= 1'b0;
                    ad_out  <= lat_addr[7:0];
                    ad_oe   <= 1'b1;
                    count   <= count + 4'd1;
                    if (count == 4'd1) begin
                        count  <= 4'd0;
                        tstate <= lat_write ? T_WDATA : T_RTURN;
                    end
                end

                T_WDATA: begin
                    ad_out <= lat_wdata;
                    ad_oe  <= 1'b1;
                    count  <= count + 4'd1;
                    if (count == 4'd1) begin
                        count  <= 4'd0;
                        tstate <= T_WLOW;
                    end
                end

                T_WLOW: begin
                    bus_WR_n <= 1'b0;
                    ad_out   <= lat_wdata;
                    ad_oe    <= 1'b1;
                    count    <= count + 4'd1;
                    if (count == 4'd2) begin
                        count  <= 4'd0;
                        tstate <= T_WHIGH;
                    end
                end

                T_WHIGH: begin
                    bus_WR_n <= 1'b1;
                    ad_out   <= lat_wdata;
                    ad_oe    <= 1'b1;
                    count    <= count + 4'd1;
                    if (count == 4'd2) begin
                        count  <= 4'd0;
                        tstate <= T_DONE;
                    end
                end

                T_RTURN: begin
                    ad_oe    <= 1'b0;
                    bus_RD_n <= 1'b1;
                    count    <= count + 4'd1;
                    if (count == 4'd1) begin
                        count  <= 4'd0;
                        tstate <= T_RLOW;
                    end
                end

                T_RLOW: begin
                    ad_oe    <= 1'b0;
                    bus_RD_n <= 1'b0;
                    count    <= count + 4'd1;
                    if (count == 4'd5) begin
                        rdata  <= ad_in;
                        count  <= 4'd0;
                        tstate <= T_RHIGH;
                    end
                end

                T_RHIGH: begin
                    bus_RD_n <= 1'b1;
                    count    <= count + 4'd1;
                    if (count == 4'd1) begin
                        count  <= 4'd0;
                        tstate <= T_DONE;
                    end
                end

                T_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    ad_oe <= 1'b0;
                    tstate <= T_IDLE;
                end

                default: tstate <= T_IDLE;
            endcase
        end
    end

endmodule

//==============================================================================
// 8-digit active-low Nexys A7 hex display mux.
//==============================================================================
module lbtiny_hex7seg_mux (
    input  wire        CLK100MHZ,
    input  wire [11:0] addr,
    input  wire [7:0]  data,
    output reg  [6:0]  seg,
    output wire        dp,
    output reg  [7:0]  an
);

    reg [16:0] scan = 17'd0;
    always @(posedge CLK100MHZ) begin
        scan <= scan + 17'd1;
    end

    wire [2:0] digit = scan[16:14];

    reg [3:0] nibble;
    reg       blank;

    always @(*) begin
        blank  = 1'b0;
        nibble = 4'h0;
        an     = 8'hFF;

        case (digit)
            3'd0: begin an = 8'b1111_1110; nibble = data[3:0];  end
            3'd1: begin an = 8'b1111_1101; nibble = data[7:4];  end
            3'd2: begin an = 8'b1111_1011; blank  = 1'b1;      end
            3'd3: begin an = 8'b1111_0111; blank  = 1'b1;      end
            3'd4: begin an = 8'b1110_1111; nibble = addr[3:0];  end
            3'd5: begin an = 8'b1101_1111; nibble = addr[7:4];  end
            3'd6: begin an = 8'b1011_1111; nibble = addr[11:8]; end
            default: begin an = 8'b0111_1111; blank = 1'b1;     end
        endcase

        if (blank) begin
            seg = 7'b1111111;
        end else begin
            case (nibble)
                4'h0: seg = 7'b0000001;
                4'h1: seg = 7'b1001111;
                4'h2: seg = 7'b0010010;
                4'h3: seg = 7'b0000110;
                4'h4: seg = 7'b1001100;
                4'h5: seg = 7'b0100100;
                4'h6: seg = 7'b0100000;
                4'h7: seg = 7'b0001111;
                4'h8: seg = 7'b0000000;
                4'h9: seg = 7'b0000100;
                4'hA: seg = 7'b0001000;
                4'hB: seg = 7'b1100000;
                4'hC: seg = 7'b0110001;
                4'hD: seg = 7'b1000010;
                4'hE: seg = 7'b0110000;
                default: seg = 7'b0111000;
            endcase
        end
    end

    assign dp = 1'b1;

endmodule

`default_nettype wire
