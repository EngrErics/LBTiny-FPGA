## =========================================================================
## lbtiny.xdc
##  Nexys A7-100T constraints for the LBTiny bus slave bring-up build.
##  Target part: xc7a100tcsg324-1 (Nexys A7-100T). Also works on -50T.
## =========================================================================

## -------------------------------------------------------------------------
## Clock: 100 MHz on-board oscillator
## -------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { CLK100MHZ }]

## -------------------------------------------------------------------------
## 16 user LEDs (LED[15:0])
##   LED[11:0]  = latched address
##   LED[12]    = cs_rom
##   LED[13]    = cs_ram
##   LED[14]    = cs_mmio
##   LED[15]    = drive_en
## -------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { LED[0] }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { LED[1] }]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { LED[2] }]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { LED[3] }]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { LED[4] }]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports { LED[5] }]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports { LED[6] }]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports { LED[7] }]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports { LED[8] }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { LED[9] }]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { LED[10] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { LED[11] }]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { LED[12] }]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { LED[13] }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { LED[14] }]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports { LED[15] }]

## -------------------------------------------------------------------------
## Pmod JA - upper address + bus control (CPU/supervisor outputs, FPGA inputs)
##   JA[1..4]  -> A[8..11]      (JA_AB[1..4])
##   JA[7..10] -> ALE, RD_n, WR_n, RESET_n  (JA_CTL[7..10])
## Pull strategy:
##   The bring-up wiring uses external pulls on a breadboard:
##     - 10k pull-DOWN on ALE       (Pmod JA pin 7 -> GND)
##     - 10k pull-UP   on RD_n      (Pmod JA pin 8 -> 3V3)
##     - 10k pull-UP   on WR_n      (Pmod JA pin 9 -> 3V3)
##     - 10k pull-UP   on RESET_n   (Pmod JA pin 10 -> 3V3)
##   Internal PULLUP/PULLDOWN below is left commented out; rely on external.
##   On the reference board these become the same resistor network plus the
##   74LVC245 buffer between supervisor and bus.
## -------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { JA_AB[1] }]   ;# JA1  - A[8]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { JA_AB[2] }]   ;# JA2  - A[9]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports { JA_AB[3] }]   ;# JA3  - A[10]
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports { JA_AB[4] }]   ;# JA4  - A[11]
set_property -dict { PACKAGE_PIN D17 IOSTANDARD LVCMOS33 } [get_ports { JA_CTL[7] }]  ;# JA7  - ALE
set_property -dict { PACKAGE_PIN E17 IOSTANDARD LVCMOS33 } [get_ports { JA_CTL[8] }]  ;# JA8  - RD_n
set_property -dict { PACKAGE_PIN F18 IOSTANDARD LVCMOS33 } [get_ports { JA_CTL[9] }]  ;# JA9  - WR_n
set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports { JA_CTL[10] }] ;# JA10 - RESET_n

## -------------------------------------------------------------------------
## Pmod JB - multiplexed address/data (bidirectional)
##   JB[1..4]  -> AD[0..3]      (JB_AD_LO[1..4])
##   JB[7..10] -> AD[4..7]      (JB_AD_HI[7..10])
## No internal pulls - the bus is actively driven by either CPU/supervisor
## (address phase) or the slave (read data phase).
## -------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN D14 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_LO[1] }] ;# JB1  - AD[0]
set_property -dict { PACKAGE_PIN F16 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_LO[2] }] ;# JB2  - AD[1]
set_property -dict { PACKAGE_PIN G16 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_LO[3] }] ;# JB3  - AD[2]
set_property -dict { PACKAGE_PIN H14 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_LO[4] }] ;# JB4  - AD[3]
set_property -dict { PACKAGE_PIN E16 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_HI[7] }] ;# JB7  - AD[4]
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_HI[8] }] ;# JB8  - AD[5]
set_property -dict { PACKAGE_PIN G13 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_HI[9] }] ;# JB9  - AD[6]
set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports { JB_AD_HI[10] }];# JB10 - AD[7]

## -------------------------------------------------------------------------
## Pmod JXADC - INT (supervisor -> CPU); used in the reference board only.
## We declare it as an input so the constraint file is complete, but the
## current bring-up firmware never drives it.
## -------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN A13 IOSTANDARD LVCMOS33 } [get_ports { JXADC_INT }]   ;# JXADC1 - INT

## -------------------------------------------------------------------------
## Configuration / bitstream options
## -------------------------------------------------------------------------
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## -------------------------------------------------------------------------
## Timing-related notes (no additional constraints needed)
## -------------------------------------------------------------------------
## The 4 MHz internal clock is derived combinationally inside the design from
## CLK100MHZ. Vivado will infer it as a generated clock automatically. Since
## all bus signals come from outside the FPGA at hand-paced (microsecond-scale)
## timing, no external input/output delay constraints are required for the
## current bring-up. They will be added when the reference board imposes real
## propagation budgets.
