// Reusable Register w/ shadow register Module
`timescale 1ns/1ps

module shadow_reg #(parameter W = 8, DEFAULT = 0) (
    input wire [W-1:0] data,
    input wire latch_en,
    input wire backup,
    input wire restore,
    input wire CLK,
    input wire RESET_n,
    output reg [W-1:0] register
);

    reg [W-1:0] shadow;

    always @(posedge CLK or negedge RESET_n) begin

        // On reset, the register defaults to specific value
        if (!RESET_n) begin
            shadow <= DEFAULT;
            register <= DEFAULT;
        end

        if (latch_en) begin
            register <= data; // Always latch data to the output register
            if(backup) begin
                shadow <= data; // Only latch to shadow register if we are backing up data
            end
            else begin
                shadow <= shadow;
            end
        end
        else if (!latch_en && !backup && restore) begin
            register <= shadow; // Restore data from the shadow register
        end
        else begin
            register <= register;
            shadow <= shadow;
        end

    end

endmodule