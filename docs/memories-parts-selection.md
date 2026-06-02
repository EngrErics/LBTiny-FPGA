Flash Rom
SST39LF010-55-4C-TU
3v-3.6v 55ns access time from CE
normally in stock 468 available
https://www.digikey.com/en/products/detail/microchip-technology/SST39LF010-55-4C-TU/25904104

Considerations: expects the full-width unlock at address 0x5555
I hadn't considered that the chip needs the entire address space for the unlock
Supervisor needs to expand the entire 16bit address width, not much of an issue

SRAM
AS6C6264-55SIN 28-SOP
2.7v-5.5v 55ns access time
normally in stock 1196 available
https://www.digikey.com/en/products/detail/alliance-memory-inc/AS6C6264-55SIN/4234597


Latch
SN74LVC573ADWR 20-SOIC
1.65v-3.6v
normally in stock 7348 available
https://www.digikey.com/en/products/detail/texas-instruments/SN74LVC573ADWR/562967


SN74LVC00 14-SOIC Quad 2-input NAND
1.65v-3.6v 4.1ns
normally in stock 929 available
https://www.digikey.com/en/products/detail/texas-instruments/SN74LVC00ADT/1591657


2 Choices for Bus Switch 20ch SN74CBTLV16210DLR or SN74CBTLV3245A
I'm currently doing the SN74CBTLV3245A
SN74CBTLV3245A LOW-VOLTAGE OCTAL FET BUS SWITCH
https://www.digikey.com/en/products/detail/texas-instruments/SN74CBTLV3245ADW/277190


**DEPRECATED BELOW THIS LINE**
Address Decoding
SN74LVC138AD 16-SOIC SCRATCHING OUT THIS IDEA IN FAVOR OR QUAD NAND
1.65v to 3.6v 5.8ns
normally in stock 
https://www.digikey.com/en/products/detail/texas-instruments/SN74LVC138AD/377423

Address Decoding (See PDF Explanation)
y = nand(A[11],A[10]), z = nand(y,y), ROM CE = z
w = nand(A[9],A[8]), RAM CE = nand(w,z)
We are reusing Z so that we only end up with 4 2-input NAND Gates
Single 74LVC00 Quad 2-input NAND
Worst Case Propation Delay = (3)4.1ns = 12.3ns
chip selects are valid less half way through T1 since latch output follows the input. This gives us 3 full cycles for rom/ram to "wake up"
data to/from rom/ram is 70ns from CE assert.
This is a pretty decent solution for the address decoding. Images on
Erics phone.