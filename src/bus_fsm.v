// Bus FSM
// This section controls the data and address bus of the CPU to interface with memory
`timescale 1ns/1ps

module bus_fsm (
    input wire CLK,
    input wire RESET_n,

    // CPU handshake signals
    input wire start,
    input wire write,
    input wire [11:0] addr,
    input wire [7:0] wdata,
    output wire done,

    // Physical bus signals
    output wire [3:0] bus_A,
    output wire bus_ALE,
    output wire bus_RD_n,
    output wire bus_WR_n,
    inout wire [7:0] bus_AD
);

    // FSM state encoding
    localparam IDLE = 3'b000;
    localparam T1 = 3'b001;
    localparam T2 = 3'b010;
    localparam T3 = 3'b011;
    localparam T4_r = 3'b100;
    localparam T5_r = 3'b101;
    localparam T4_w = 3'b110;
    localparam T5_w = 3'b111;

    // State register and next state combinational output
    reg [2:0] state = IDLE;
    wire [2:0] next_state;

    // The top four bits of the address always passes through no matter what state we are in
    assign bus_A = addr[11:8];

    // Step the FSM on every clock cycle (Sequential block)
    always @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            state <= IDLE;
            bus_AD = 8'bZ;
            bus_ALE = 1'b0;
            bus_RD_n = 1'b1;
            bus_WR_n = 1'b1;
            done = 1'b0;
        end
        else begin
            state <= next_state;
        end
    end

    // Combinational block
    always @(*) begin
        case (state)
            IDLE: begin
                bus_AD = 8'bZ;
                bus_ALE = 1'b0;
                bus_RD_n = 1'b1;
                bus_WR_n = 1'b1;
                done = 1'b0;
                next_state = start ? T1 : IDLE;
            end
            T1: begin
                bus_AD = addr[7:0];
                bus_ALE = 1'b1;
                bus_RD_n = 1'b1;
                bus_WR_n = 1'b1;
                done = 1'b0;
                next_state = T2;
            end
            T2: begin
                bus_AD = addr[7:0];
                bus_ALE = 1'b0;
                bus_RD_n = 1'b1;
                bus_WR_n = 1'b1;
                done = 1'b0;
                next_state = T3;
            end
            T3: begin
                bus_AD = 8'bZ;
                bus_ALE = 1'b0;
                bus_RD_n = 1'b1;
                bus_WR_n = 1'b1;
                done = 1'b0;
                next_state = write ? T4_w : T4_r;
            end
            T4_w: begin
                bus_AD = wdata;
                bus_ALE = 1'b0;
                bus_RD_n = 1'b1;
                bus_WR_n = 1'b0;
                done = 1'b0;
                next_state = T5_w;
            end
            T5_w: begin
                bus_AD = wdata;
                bus_ALE = 1'b0;
                bus_RD_n = 1'b1;
                bus_WR_n = 1'b1;
                done = 1'b1;
                next_state = IDLE;
            end
            T4_r: begin
                bus_AD = 8'bZ;
                bus_ALE = 1'b0;
                bus_RD_n = 1'b0;
                bus_WR_n = 1'b1;
                done = 1'b0;
                next_state = T5_r;
            end
            T5_r: begin
                bus_AD = 8'bZ;
                bus_ALE = 1'b0;
                bus_RD_n = 1'b0;
                bus_WR_n = 1'b1;
                done = 1'b1;
                next_state = IDLE;
            end
            // Default to IDLE
            default: begin
                bus_AD = 8'bZ;
                bus_ALE = 1'b0;
                bus_RD_n = 1'b1;
                bus_WR_n = 1'b1;
                done = 1'b0;
                next_state = start ? T1 : IDLE;
            end
        endcase
    end

endmodule