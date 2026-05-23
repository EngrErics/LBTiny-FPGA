# ================================================================
# Vivado batch hardware programming for LBTiny / Nexys A7
#
# Usage:
#   vivado -mode batch -source program_bitstream.tcl -tclargs <bitfile>
#   vivado -mode batch -source program_bitstream.tcl -tclargs <bitfile> -persist
#
# Default mode: program the FPGA SRAM over JTAG (volatile, lost on power cycle).
# -persist:     run write_cfgmem on the .bit to produce a .mcs, then program
#               that .mcs into the on-board Spansion S25FL128S QSPI flash
#               (16 MiB). After flashing, set the JP1 mode jumper to QSPI and
#               power-cycle the board; the design will reload automatically.
# ================================================================

if {$argc < 1} {
    puts "ERROR: missing bitstream path."
    puts "  vivado ... -tclargs path/to/lbtiny_top.bit"
    puts "  vivado ... -tclargs path/to/lbtiny_top.bit -persist"
    exit 1
}

set bit_file [file normalize [lindex $argv 0]]
set persist  0
for {set i 1} {$i < $argc} {incr i} {
    if {[string equal -nocase [lindex $argv $i] "-persist"]} { set persist 1 }
}

proc fail {msg} {
    puts "ERROR: $msg"
    catch {close_hw_manager}
    exit 1
}

if {![file exists $bit_file]} { fail "bitstream not found: $bit_file" }

if {$persist} {
    puts "\[program\] mode=QSPI-flash (persistent)"
} else {
    puts "\[program\] mode=JTAG (volatile)"
}
puts "\[program\] bit:  $bit_file"

# ----------------------------------------------------------------
# If persisting, generate the .mcs next to the .bit before opening
# the hardware. This step does not need a JTAG connection.
# ----------------------------------------------------------------
set mcs_file ""
if {$persist} {
    set bit_dir  [file dirname $bit_file]
    set bit_root [file rootname [file tail $bit_file]]
    set mcs_file [file join $bit_dir "$bit_root.mcs"]
    puts "\[program\] mcs:  $mcs_file  (regenerating)"
    if {[catch {
        write_cfgmem -force -format mcs -interface spix4 -size 16 \
            -loadbit "up 0x0 $bit_file" -file $mcs_file
    } result]} {
        fail "write_cfgmem failed: $result"
    }
    if {![file exists $mcs_file]} { fail "mcs not produced: $mcs_file" }
}

# ----------------------------------------------------------------
# Open hardware manager and find the Artix-7 on the JTAG chain.
# ----------------------------------------------------------------
if {[catch {open_hw_manager} result]}                          { fail "open_hw_manager: $result" }
if {[catch {connect_hw_server -url localhost:3121} result]}    { fail "connect_hw_server: $result" }

set targets [get_hw_targets]
if {[llength $targets] == 0} {
    fail "no JTAG targets. Is the Nexys A7 powered on and the USB-JTAG cable connected?"
}
current_hw_target [lindex $targets 0]
if {[catch {open_hw_target} result]} { fail "open_hw_target: $result" }

set devices [get_hw_devices]
if {[llength $devices] == 0} { fail "no devices on the JTAG chain." }

# Prefer the Artix-7 FPGA. Fall back to the first device.
set selected_device ""
foreach d $devices {
    set part_lc ""
    catch {set part_lc [string tolower [get_property PART $d]]}
    if {[string match "*xc7a100t*" $part_lc] || [string match "*xc7a50t*" $part_lc]} {
        set selected_device $d
        break
    }
}
if {$selected_device eq ""} { set selected_device [lindex $devices 0] }

set sel_part "?"
catch {set sel_part [get_property PART $selected_device]}
puts "\[program\] device: $selected_device  ($sel_part)"

current_hw_device $selected_device
catch {refresh_hw_device $selected_device}

# ----------------------------------------------------------------
# Program: either JTAG SRAM or QSPI flash.
# ----------------------------------------------------------------
if {!$persist} {
    puts "\[program\] writing FPGA SRAM..."
    set_property PROGRAM.FILE $bit_file $selected_device
    if {[catch {program_hw_devices $selected_device} result]} {
        fail "program_hw_devices: $result"
    }
    catch {refresh_hw_device $selected_device}
    puts "\[program\] done. (volatile - design will be lost on power-cycle)"
} else {
    # Nexys A7 on-board flash: Spansion S25FL128S, 128 Mib / 16 MiB, x4 QSPI.
    set flash_part "s25fl128sxxxxxx0-spi-x1_x2_x4"
    puts "\[program\] writing QSPI flash ($flash_part), ~30-90s..."

    # Drop any stale cfgmem from a prior run in the same Vivado session.
    set existing [get_property PROGRAM.HW_CFGMEM $selected_device]
    if {$existing ne ""} { catch {delete_hw_cfgmem $existing} }

    set mem_dev [lindex [get_cfgmem_parts $flash_part] 0]
    if {$mem_dev eq ""} { fail "Vivado does not know cfgmem part '$flash_part'." }

    set hw_cfgmem [create_hw_cfgmem -hw_device $selected_device -mem_dev $mem_dev]
    set_property PROGRAM.FILES                  [list $mcs_file] $hw_cfgmem
    set_property PROGRAM.ADDRESS_RANGE          {use_file}       $hw_cfgmem
    set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none}      $hw_cfgmem
    set_property PROGRAM.BLANK_CHECK            0                $hw_cfgmem
    set_property PROGRAM.ERASE                  1                $hw_cfgmem
    set_property PROGRAM.CFG_PROGRAM            1                $hw_cfgmem
    set_property PROGRAM.VERIFY                 1                $hw_cfgmem
    set_property PROGRAM.CHECKSUM               0                $hw_cfgmem

    catch {refresh_hw_device $selected_device}
    if {[catch {program_hw_cfgmem -hw_cfgmem $hw_cfgmem} result]} {
        fail "program_hw_cfgmem: $result"
    }
    catch {refresh_hw_device $selected_device}

    puts "\[program\] done. Set JP1 to QSPI and power-cycle (or press PROG)."
}

catch {close_hw_manager}
exit 0
