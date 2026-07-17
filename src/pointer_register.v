// Program Counter
`timescale 1ns/1ps

module pointer_register(
    input wire [7:0] Acc,
    input wire [7:0] MDR,
    input wire [7:0] IR,
    input wire latch_en,
    input wire backup,
    input wire restore,
    input wire CLK,
    input wire RESET_n,
    output reg [11:0] pr_out
);
    // Data input
    reg [11:0] data;

    // Internal shadow register
    shadow_reg #(W = 12, DEFAULT = 0) pr(
        .data(data),
        .latch_en(latch_en),
        .backup(backup),
        .restore(restore),
        .CLK(CLK),
        .RESET_n(RESET_n),
        .register(pr_out)
    );

    // Combinational block for the data input of the shadow register
    // By default the it always feeds back what is in the register unless an instruction requires otherwise
    always @(Acc, MDR, IR) begin
        case (IR[7:4])
            4'h0: begin
                case (IR[3:0])
                    4'hD: data = {4'b0, Acc}; // Storing the accumulator to the pointer register (ST [pr])
                    4'hF: data = pr_out + {{4{Acc[7]}}, Acc}; // Adding the accumulator to the pointer register (ADDP)
                    default: data = pr_out;
                endcase
            end
            4'h1: data = (IR[3:0] == 4'h7) ? pr_out + {{4{MDR[7]}}, MDR} : pr_out; // Adding immediate value to the pointer register (ADDPI)
            4'hB: data = {IR[3:0], MDR}; // Load address to pointer register (LDP)
            default: data = pr_out;
        endcase
    end
endmodule