//==============================================================================
// lbtiny_viewer.v
//------------------------------------------------------------------------------
// Memory viewer subsystem for LBTiny FPGA development.
//
// Provides two independent capabilities:
//
//   OBSERVATION (always live, never touches the bus):
//     SW[11:0] selects an address. peek_addr is driven continuously from the
//     synchronized switch value. peek_data from lbtiny_mem updates one cycle
//     later and is displayed on the 7-seg and LEDs in real time, whether the
//     CPU is running or held in reset.
//
//   MUTATION (bus master, only when SW15/cpu_reset_n asserted):
//     BTNC fills ROM (0x000-0xBFF) and RAM (0xC00-0xEFF) with addr[7:0].
//       ROM uses the real flash unlock+program sequence (4 bus writes/byte).
//       RAM writes directly (1 bus write/byte).
//     BTNU reinitializes: ROM chip-erase sequence + RAM filled with 0xFF.
//     Both buttons are ignored while cpu_halted is low (CPU running). This
//     prevents the viewer's bus master from fighting the CPU on shared wires.
//
// Instantiated by both lbtiny_top and lbtiny_bringup_top. In the bringup
// top, cpu_halted is driven permanently high so mutation is always available.
// In the production top, cpu_halted comes from the combined reset logic.
//
// Port summary:
//   CLK100MHZ  — 100 MHz system clock (for 7-seg scan counter only)
//   clk_bus    — bus clock (~3.846 MHz), all FSM/debounce/sync logic
//   cpu_halted — high when CPU is in reset; gates mutation operations
//   SW         — SW[11:0] address select, SW[15] unused here (handled in top)
//   BTNC       — fill memory with addr[7:0]
//   BTNU       — reinitialize (erase ROM + fill RAM 0xFF)
//   peek_addr  — drives lbtiny_mem's peek port (combinational from sw_q2)
//   peek_data  — registered data back from lbtiny_mem's peek port
//   bus_*      — bus master outputs to lbtiny_mem bus interface
//   ad_in      — AD bus read back (from lbtiny_mem)
//   ad_out     — AD bus drive value
//   ad_oe      — AD bus output enable
//   LED[15:0]  — status and address/region indicators
//   CA-CG, DP  — 7-seg segments (active low)
//   AN[7:0]    — 7-seg anodes (active low)
//   viewer_busy — high during any init/fill operation
//   fill_busy   — high specifically during BTNC fill
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module lbtiny_viewer (
    input  wire        CLK100MHZ,
    input  wire        clk_bus,
    input  wire        cpu_halted,   // 1 = CPU in reset, mutation allowed

    input  wire [15:0] SW,
    input  wire        BTNC,
    input  wire        BTNU,

    // Peek interface (connects to lbtiny_mem peek ports)
    output wire [11:0] peek_addr,
    input  wire [7:0]  peek_data,

    // Bus master interface (connects to lbtiny_mem bus interface)
    // Driven directly by lbtiny_bus_master submodule outputs — must be wire.
    output wire [3:0]  bus_A,
    output wire        bus_ALE,
    output wire        bus_RD_n,
    output wire        bus_WR_n,
    input  wire [7:0]  ad_in,
    output wire [7:0]  ad_out,
    output wire        ad_oe,

    // Display
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

    // Status outputs (for top-level LED override if needed)
    output reg         viewer_busy,
    output reg         fill_busy
);

    //--------------------------------------------------------------------------
    // Switch synchronizer (SW[11:0] -> clk_bus domain)
    //--------------------------------------------------------------------------
    reg [11:0] sw_q1, sw_q2;

    always @(posedge clk_bus) begin
        sw_q1 <= SW[11:0];
        sw_q2 <= sw_q1;
    end

    // Peek address is always the current synchronized switch value.
    // The top level just routes peek_data back from lbtiny_mem.
    assign peek_addr = sw_q2;

    //--------------------------------------------------------------------------
    // Button debouncing
    //--------------------------------------------------------------------------
    // Two-stage metastability synchronizer + counter debouncer.
    // DEBOUNCE_TICKS bus clocks must elapse with a stable input before
    // btnX_stable updates (~4.2 ms at 3.846 MHz).
    // Cross-masking: a press of BTNC is ignored while BTNU is held and
    // vice versa, eliminating mechanical cross-talk on the Nexys A7.

    localparam [15:0] DEBOUNCE_TICKS = 16'd16000;

    reg btnc_s1, btnc_s2;
    reg btnu_s1, btnu_s2;

    always @(posedge clk_bus) begin
        btnc_s1 <= BTNC; btnc_s2 <= btnc_s1;
        btnu_s1 <= BTNU; btnu_s2 <= btnu_s1;
    end

    reg [15:0] btnc_cnt, btnu_cnt;
    reg        btnc_stable, btnc_stable_q;
    reg        btnu_stable, btnu_stable_q;

    initial begin
        btnc_cnt = 16'd0; btnu_cnt = 16'd0;
        btnc_stable = 1'b0; btnc_stable_q = 1'b0;
        btnu_stable = 1'b0; btnu_stable_q = 1'b0;
        sw_q1 = 12'h000; sw_q2 = 12'h000;
    end

    always @(posedge clk_bus) begin
        // BTNC
        if (btnc_s2 == btnc_stable)
            btnc_cnt <= 16'd0;
        else if (btnc_cnt == DEBOUNCE_TICKS) begin
            btnc_stable <= btnc_s2;
            btnc_cnt    <= 16'd0;
        end else
            btnc_cnt <= btnc_cnt + 16'd1;
        btnc_stable_q <= btnc_stable;

        // BTNU
        if (btnu_s2 == btnu_stable)
            btnu_cnt <= 16'd0;
        else if (btnu_cnt == DEBOUNCE_TICKS) begin
            btnu_stable <= btnu_s2;
            btnu_cnt    <= 16'd0;
        end else
            btnu_cnt <= btnu_cnt + 16'd1;
        btnu_stable_q <= btnu_stable;
    end

    wire btnc_edge = btnc_stable & ~btnc_stable_q & ~btnu_stable;
    wire btnu_edge = btnu_stable & ~btnu_stable_q & ~btnc_stable;

    //--------------------------------------------------------------------------
    // Controller FSM — localparam and state declared here so the btnc_req/
    // btnu_req always block below can legally reference state and S_IDLE.
    //--------------------------------------------------------------------------
    localparam [4:0]
        S_INIT_ERASE_NEXT = 5'd0,
        S_INIT_ERASE_ADV  = 5'd1,
        S_INIT_ERASE_WAIT = 5'd2,
        S_INIT_RAM_NEXT   = 5'd3,
        S_INIT_RAM_ADV    = 5'd4,
        S_IDLE            = 5'd5,
        S_FILL_NEXT       = 5'd6,
        S_FILL_ADV        = 5'd7,
        S_ISSUE           = 5'd8,
        S_WAIT            = 5'd9;

    reg [4:0]  state, return_state;

    // Sticky request flags: set on debounced rising edge, cleared by FSM in
    // S_IDLE. Mutation requests are only latched when cpu_halted is high.
    reg btnc_req, btnu_req;

    initial begin btnc_req = 1'b0; btnu_req = 1'b0; end

    always @(posedge clk_bus) begin
        if (btnc_edge && cpu_halted) btnc_req <= 1'b1;
        else if (btnc_req && state == S_IDLE) btnc_req <= 1'b0;

        if (btnu_edge && cpu_halted) btnu_req <= 1'b1;
        else if (btnu_req && state == S_IDLE) btnu_req <= 1'b0;
    end

    reg [12:0] wait_count;
    reg [11:0] fill_addr;
    reg [2:0]  step;

    // Viewed address and data: observation comes from peek port, so
    // viewed_addr just tracks the switch value and viewed_data is peek_data.
    reg [11:0] viewed_addr;
    reg [7:0]  viewed_data;

    // Transaction registers
    reg        op_write;
    reg [11:0] op_addr;
    reg [7:0]  op_data;

    // Bus master handshake signals
    reg        txn_start;
    wire       txn_busy;
    wire       txn_done;
    wire [7:0] txn_rdata;

    initial begin
        state        = S_INIT_ERASE_NEXT;
        return_state = S_IDLE;
        wait_count   = 13'd0;
        fill_addr    = 12'h000;
        step         = 3'd0;
        viewer_busy  = 1'b1;
        fill_busy    = 1'b0;
        viewed_addr  = 12'h000;
        viewed_data  = 8'hFF;
        op_write     = 1'b0;
        op_addr      = 12'h000;
        op_data      = 8'h00;
        txn_start    = 1'b0;
    end

    // Update viewed_addr and viewed_data from peek port every cycle in idle.
    // viewed_addr follows sw_q2 directly; viewed_data follows peek_data which
    // is already registered inside lbtiny_mem (one cycle latency).
    always @(posedge clk_bus) begin
        viewed_addr <= sw_q2;
        viewed_data <= peek_data;
    end

    always @(posedge clk_bus) begin
        txn_start <= 1'b0;

        case (state)

            //------------------------------------------------------------------
            // Power-on: erase ROM then fill RAM with 0xFF.
            // BTNU also re-enters here to reinitialize.
            //------------------------------------------------------------------
            S_INIT_ERASE_NEXT: begin
                viewer_busy  <= 1'b1;
                fill_busy    <= 1'b0;
                op_write     <= 1'b1;
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
                wait_count <= wait_count + 13'd1;
                if (wait_count == 13'd3300) begin
                    fill_addr <= 12'hC00;
                    state     <= S_INIT_RAM_NEXT;
                end
            end

            S_INIT_RAM_NEXT: begin
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
            // Idle: serve button requests; observation is always live via peek.
            //------------------------------------------------------------------
            S_IDLE: begin
                viewer_busy <= 1'b0;
                fill_busy   <= 1'b0;
                if (btnc_req) begin
                    viewer_busy <= 1'b1;
                    fill_busy   <= 1'b1;
                    fill_addr   <= 12'h000;
                    step        <= 3'd0;
                    state       <= S_FILL_NEXT;
                end else if (btnu_req) begin
                    viewer_busy <= 1'b1;
                    step        <= 3'd0;
                    state       <= S_INIT_ERASE_NEXT;
                end
                // No polling read needed: observation comes from peek port.
            end

            //------------------------------------------------------------------
            // BTNC fill: write addr[7:0] to every address 0x000-0xEFF.
            // ROM needs 4 bus writes per byte (flash unlock+program sequence).
            // RAM needs 1 bus write per byte.
            //------------------------------------------------------------------
            S_FILL_NEXT: begin
                viewer_busy  <= 1'b1;
                fill_busy    <= 1'b1;
                op_write     <= 1'b1;
                return_state <= S_FILL_ADV;

                if (fill_addr <= 12'hBFF) begin
                    case (step)
                        3'd0: begin op_addr <= 12'h555; op_data <= 8'hAA;              state <= S_ISSUE; end
                        3'd1: begin op_addr <= 12'h2AA; op_data <= 8'h55;              state <= S_ISSUE; end
                        3'd2: begin op_addr <= 12'h555; op_data <= 8'hA0;              state <= S_ISSUE; end
                        default: begin op_addr <= fill_addr; op_data <= fill_addr[7:0]; state <= S_ISSUE; end
                    endcase
                end else if (fill_addr <= 12'hEFF) begin
                    op_addr <= fill_addr;
                    op_data <= fill_addr[7:0];
                    state   <= S_ISSUE;
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
            // Shared issue/wait states for all bus transactions.
            //------------------------------------------------------------------
            S_ISSUE: begin
                if (!txn_busy) begin
                    txn_start <= 1'b1;
                    state     <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (txn_done)
                    state <= return_state;
            end

            default: state <= S_INIT_ERASE_NEXT;
        endcase
    end

    //--------------------------------------------------------------------------
    // Bus master transaction engine
    //--------------------------------------------------------------------------
    lbtiny_bus_master u_master (
        .CLK      (clk_bus),
        .start    (txn_start),
        .write    (op_write),
        .addr     (op_addr),
        .wdata    (op_data),
        .busy     (txn_busy),
        .done     (txn_done),
        .rdata    (txn_rdata),
        .bus_A    (bus_A),
        .bus_ALE  (bus_ALE),
        .bus_RD_n (bus_RD_n),
        .bus_WR_n (bus_WR_n),
        .ad_in    (ad_in),
        .ad_out   (ad_out),
        .ad_oe    (ad_oe)
    );

    //--------------------------------------------------------------------------
    // LED assignments
    //--------------------------------------------------------------------------
    // LED[11:0]  = viewed address (follows switches live)
    // LED[12]    = viewed address is in ROM range
    // LED[13]    = viewed address is in RAM range
    // LED[14]    = fill_busy  (BTNC operation in progress)
    // LED[15]    = viewer_busy (any init/fill in progress)

    assign LED[11:0] = viewed_addr;
    assign LED[12]   = (viewed_addr <= 12'hBFF);
    assign LED[13]   = (viewed_addr >= 12'hC00) && (viewed_addr <= 12'hEFF);
    assign LED[14]   = fill_busy;
    assign LED[15]   = viewer_busy;

    //--------------------------------------------------------------------------
    // 7-segment display
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
// lbtiny_bus_master
//------------------------------------------------------------------------------
// Single-transaction 8085-style bus master. Executes one complete read or
// write transaction per invocation. Extracted from the original viewer so both
// the bringup top and the production top share the same implementation.
//
// Handshake:
//   Assert start for one cycle to begin. busy goes high immediately and stays
//   high until done pulses for one cycle. For read transactions, rdata is valid
//   when done pulses. start is ignored while busy is high.
//
// Transaction lengths at 3.846 MHz:
//   Write: 13 cycles (~3.4 µs)
//   Read : 15 cycles (~3.9 µs)
//==============================================================================
module lbtiny_bus_master (
    input  wire        CLK,
    input  wire        start,
    input  wire        write,
    input  wire [11:0] addr,
    input  wire [7:0]  wdata,
    output reg         busy,
    output reg         done,
    output reg  [7:0]  rdata,

    output reg  [3:0]  bus_A,
    output reg         bus_ALE,
    output reg         bus_RD_n,
    output reg         bus_WR_n,
    input  wire [7:0]  ad_in,
    output reg  [7:0]  ad_out,
    output reg         ad_oe
);

    localparam [3:0]
        T_IDLE  = 4'd0,
        T_ADDR  = 4'd1,
        T_HOLD  = 4'd2,
        T_WDATA = 4'd3,
        T_WLOW  = 4'd4,
        T_WHIGH = 4'd5,
        T_RTURN = 4'd6,
        T_RLOW  = 4'd7,
        T_RHIGH = 4'd8,
        T_DONE  = 4'd9;

    reg [3:0]  tstate;
    reg [3:0]  count;
    reg        lat_write;
    reg [11:0] lat_addr;
    reg [7:0]  lat_wdata;

    initial begin
        tstate    = T_IDLE;
        count     = 4'd0;
        busy      = 1'b0;
        done      = 1'b0;
        rdata     = 8'h00;
        bus_A     = 4'h0;
        bus_ALE   = 1'b0;
        bus_RD_n  = 1'b1;
        bus_WR_n  = 1'b1;
        ad_out    = 8'h00;
        ad_oe     = 1'b0;
        lat_write = 1'b0;
        lat_addr  = 12'h000;
        lat_wdata = 8'h00;
    end

    always @(posedge CLK) begin
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
                busy   <= 1'b0;
                done   <= 1'b1;
                ad_oe  <= 1'b0;
                tstate <= T_IDLE;
            end

            default: tstate <= T_IDLE;
        endcase
    end

endmodule

//==============================================================================
// lbtiny_hex7seg_mux
//------------------------------------------------------------------------------
// 8-digit active-low 7-segment display multiplexer for the Nexys A7.
// Scan rate: 100 MHz / 2^17 ≈ 763 Hz per digit.
// Display layout: _AAA__DD  (address digits 6-4, data digits 1-0, rest blank)
//==============================================================================
module lbtiny_hex7seg_mux (
    input  wire        CLK100MHZ,
    input  wire [11:0] addr,
    input  wire [7:0]  data,
    output reg  [6:0]  seg,
    output wire        dp,
    output reg  [7:0]  an
);

    reg [16:0] scan;
    initial scan = 17'd0;

    always @(posedge CLK100MHZ)
        scan <= scan + 17'd1;

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
            3'd2: begin an = 8'b1111_1011; blank  = 1'b1;       end
            3'd3: begin an = 8'b1111_0111; blank  = 1'b1;       end
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
