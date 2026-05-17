//==============================================================================
// lbtiny_cpu.v
//------------------------------------------------------------------------------
// LBTiny 8-bit CPU.
//
// This file is the placeholder until the real CPU implementation is complete.
// The port interface is final and must not change when the real CPU replaces
// this file. lbtiny_top.v depends on exactly these ports.
//
// Bus behavior of this placeholder:
//   All bus outputs are held idle: ALE=0, RD_n=1, WR_n=1, A=0, AD=Z.
//   The memory subsystem will not see any bus activity from this module.
//   This is a valid bus-idle state and will not interfere with other masters
//   (e.g. the STM32 supervisor or the viewer's mutation FSM) operating while
//   RESET_n is held low by SW15 or the STM32.
//
// Replace this file with the real CPU implementation when ready. No other
// files need to change.
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module lbtiny_cpu (
    input  wire       CLK,       // Bus clock (~3.846 MHz)
    input  wire       RESET_n,   // Active-low reset (held low by top when halted)

    // 8085/8051-style multiplexed address/data bus
    output wire [3:0] A,         // A[11:8] upper address nibble
    inout  wire [7:0] AD,        // Multiplexed address[7:0] / data bus
    output wire       ALE,       // Address latch enable
    output wire       RD_n,      // Active-low read strobe
    output wire       WR_n,      // Active-low write strobe

    // Interrupt
    input  wire       INT        // General-purpose interrupt input (active high)
);

    // Placeholder: hold bus idle, tri-state AD.
    assign A    = 4'h0;
    assign ALE  = 1'b0;
    assign RD_n = 1'b1;
    assign WR_n = 1'b1;
    assign AD   = 8'bz;

    // INT acknowledged here to avoid "undriven input" warnings.
    // The real CPU will use this signal.
    wire int_unused = INT;

endmodule

`default_nettype wire
