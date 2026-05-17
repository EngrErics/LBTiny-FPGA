# ================================================================
# Vivado batch hardware programming for LBTiny / Nexys A7
#
# Usage:
#   vivado -mode batch -source program_bitstream.tcl -tclargs path/to/lbtiny_top.bit
#
# This programs the FPGA SRAM over JTAG. It does not program QSPI flash.
# ================================================================

if {$argc < 1} {
    puts "ERROR: missing bitstream path."
    puts "Example: vivado -mode batch -source program_bitstream.tcl -tclargs build/LBTiny/LBTiny.runs/impl_1/lbtiny_top.bit"
    exit 1
}

set bit_file [file normalize [lindex $argv 0]]

proc fail {msg} {
    puts "ERROR: $msg"
    catch {close_hw_manager}
    exit 1
}

if {![file exists $bit_file]} {
    fail "bitstream not found: $bit_file"
}

puts "Bitstream: $bit_file"
puts "Opening Vivado Hardware Manager..."

if {[catch {open_hw_manager} result]} {
    fail "open_hw_manager failed: $result"
}

# Connect to the local hw_server. Vivado normally starts it automatically if needed.
if {[catch {connect_hw_server -url localhost:3121} result]} {
    fail "connect_hw_server failed: $result"
}

set targets [get_hw_targets]
if {[llength $targets] == 0} {
    fail "no hardware targets found. Check that the Nexys A7 is powered on and connected by USB-JTAG."
}

puts "Hardware targets found:"
foreach t $targets {
    puts "  $t"
}

set target [lindex $targets 0]
puts "Using hardware target: $target"
current_hw_target $target

if {[catch {open_hw_target} result]} {
    fail "open_hw_target failed: $result"
}

set devices [get_hw_devices]
if {[llength $devices] == 0} {
    fail "no hardware devices found in the JTAG chain."
}

puts "Hardware devices found:"
foreach d $devices {
    set name ""
    set part ""
    catch {set name [get_property NAME $d]}
    catch {set part [get_property PART $d]}
    puts "  $d  NAME=$name  PART=$part"
}

# Prefer the Artix-7 FPGA on Nexys A7. If no match is found, use the first device.
set selected_device ""
foreach d $devices {
    set name_lc [string tolower $d]
    catch {set name_lc [string tolower [get_property NAME $d]]}
    set part_lc ""
    catch {set part_lc [string tolower [get_property PART $d]]}

    if {[string match "*xc7a100t*" $name_lc] || [string match "*xc7a100t*" $part_lc] || \
        [string match "*xc7a50t*"  $name_lc] || [string match "*xc7a50t*"  $part_lc]} {
        set selected_device $d
        break
    }
}

if {$selected_device eq ""} {
    set selected_device [lindex $devices 0]
}

puts "Using device: $selected_device"
current_hw_device $selected_device
catch {refresh_hw_device $selected_device}

puts "Programming FPGA..."
set_property PROGRAM.FILE $bit_file $selected_device

if {[catch {program_hw_devices $selected_device} result]} {
    fail "program_hw_devices failed: $result"
}

catch {refresh_hw_device $selected_device}
puts "SUCCESS: programmed $selected_device with $bit_file"

catch {close_hw_manager}
exit 0
