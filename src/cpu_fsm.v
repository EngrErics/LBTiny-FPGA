// CPU FSM
// This is the finite state machine that controls the microinstructions of the CPU

`timescale 1ns/1ps
module cpu_fsm(
    input wire CLK,
    input wire RESET_n,

    // Bus handshake
    input wire done,
    output wire start,
    output wire write,
    output wire [11:0] addr,
    output wire [7:0] wdata,

    /* Register controls */
    // Accumulator
    input wire [7:0] Acc,
    output wire acc_le,
    output wire acc_backup,
    output wire acc_restore,

    // MDR
    input wire [7:0] MDR,
    output wire mdr_le,
    output wire mdr_backup,
    output wire mdr_restore,

    // Instruction register
    input wire [7:0] IR,
    output wire ir_le,
    output wire ir_backup,
    output wire ir_restore,

    // Program counter
    input wire [11:0] pc,
    output wire pc_le,
    output wire pc_backup,
    output wire pc_restore,

    // Pointer register
    output wire pr_le,
    output wire pr_backup,
    output wire pr_restore,

    // Stack pointer
    output wire sp_le,
    output wire sp_backup,
    output wire sp_restore,

    /* Flags */
    input wire int_trigger
);
    // States
    localparam START = 4'b0000,
    FETCH_1 = 4'b0001,
    FETCH_2 = 4'b0010,
    EXECUTE_START = 4'b0011,
    ADDR_DATA_FETCH = 4'0100;

    // Internal ISR flag
    reg in_isr = 1'b0;

    // Internal state register
    reg [3:0] state = START;
    wire [3:0] next_state;

    always @(posedge CLK or negedge RESET_n) begin
        if(!RESET_n) begin
            state <= START;
            // TODO: Write all of the default values for the inputs (all 0s)
        end
        else begin
            state <= next_state;
        end
    end

    always @(*) begin
        case (state)
            START: next_state = FETCH_1;
            FETCH_1: begin
                // First fetch to get the instruction/top address
                ir_le = 1'b1;
                ir_backup = in_isr ? 1'b0 : 1'b1;
                addr = pc; // Might need to be in the previous state
                if(done)
                    next_state = (IR[7:4] == 4'b0000) ? EXECUTE_START : FETCH_2; // If the instruction fetched is a sub op, immediately execute
                else
                    next_state = FETCH_1;
            end
            FETCH_2: begin
                // Second fetch to get the data/bottom address
                mdr_le = 1'b1;
                mdr_backup = in_isr ? 1'b0 : 1'b1;
                addr = pc + 1;
                if(done)
                    next_state = EXECUTE_START; // Start executing the immediate/address instruction
                else
                    next_state = FETCH_2;
            end
            EXECUTE_START: begin
                // Execution phase
                if(IR[7:4] == 4'b0000) begin
                    // Implied ops
                end
                else if (IR[7:4] == 4'b0001) begin
                    // Immediate ops
                end
                else begin
                    // Address ops
                end
            end
            ADDR_DATA_FETCH: begin
                // Fetching data from address for address instructions
                mdr_le = 1'b1;
                mdr_backup = in_isr ? 1'b0 : 1'b1;
                if(done)
                    next_state = ; // Execute the address instruction
                else
                    next_state = DATA_FETCH;
            end
            default: next_state = START;
        endcase
    end

endmodule