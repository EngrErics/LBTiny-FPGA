# ================================================================
# Vivado batch hardware programming for LBTiny / Nexys A7
#
# Usage:
#   vivado -mode batch -source program_bitstream.tcl -tclargs path/to/lbtiny_top.bit
#   vivado -mode batch -source program_bitstream.tcl -tclargs path/to/lbtiny_top.mcs persistent
#
# Modes:
#   default     -> program the FPGA SRAM over JTAG (volatile, lost on power cycle).
#   persistent  -> program the on-board Spansion S25FL128S QSPI flash with an
#                  .mcs file produced by `build_bitstream.bat persistent`.
#                  After flashing, set JP1 to QSPI and power-cycle the board;
#                  the design will reload automatically.
# ================================================================

if {$argc < 1} {
    puts "ERROR: missing programming file path."
    puts "Examples:"
    puts "  vivado -mode batch -source program_bitstream.tcl -tclargs build/LBTiny/LBTiny.runs/impl_1/lbtiny_top.bit"
    puts "  vivado -mode batch -source program_bitstream.tcl -tclargs build/LBTiny/LBTiny.runs/impl_1/lbtiny_top.mcs persistent"
    exit 1
}

set prog_file  [file normalize [lindex $argv 0]]
set persistent 0
if {$argc >= 2 && [string equal -nocase [lindex $argv 1] "persistent"]} {
    set persistent 1
}
# Also infer persistent mode from the file extension, so users do not have
# to remember the flag when they pass an .mcs directly.
if {[string equal -nocase [file extension $prog_file] ".mcs"]} {
    set persistent 1
}

proc fail {msg} {
    puts "ERROR: $msg"
    catch {close_hw_manager}
    exit 1
}

if {![file exists $prog_file]} {
    fail "programming file not found: $prog_file"
}

if {$persistent} {
    puts "Mode: persistent (QSPI flash)"
} else {
    puts "Mode: JTAG (volatile FPGA SRAM)"
}
puts "Programming file: $prog_file"
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

if {!$persistent} {
    # ---- JTAG: volatile SRAM programming ----
    puts "Programming FPGA over JTAG (volatile, will be lost on power cycle)..."
    set_property PROGRAM.FILE $prog_file $selected_device

    if {[catch {program_hw_devices $selected_device} result]} {
        fail "program_hw_devices failed: $result"
    }

    catch {refresh_hw_device $selected_device}
    puts "SUCCESS: programmed $selected_device with $prog_file"
} else {
    # ---- QSPI flash: persistent programming ----
    # The Nexys A7 carries a Spansion S25FL128S 128 Mib (16 MiB) Quad-SPI
    # flash. The Vivado configuration memory part identifier is
    # s25fl128sxxxxxx0-spi-x1_x2_x4.
    set flash_part "s25fl128sxxxxxx0-spi-x1_x2_x4"
    puts "Programming on-board QSPI flash ($flash_part)..."
    puts "This typically takes 30-90 seconds. Do not unplug the board."

    # Remove any stale cfgmem attached to the device from a previous run.
    set existing_cfgmem [get_property PROGRAM.HW_CFGMEM $selected_device]
    if {$existing_cfgmem ne ""} {
        catch {delete_hw_cfgmem $existing_cfgmem}
    }

    set mem_dev [lindex [get_cfgmem_parts $flash_part] 0]
    if {$mem_dev eq ""} {
        fail "could not find Vivado cfgmem part '$flash_part'. Check Vivado install."
    }

    if {[catch {
        set hw_cfgmem [create_hw_cfgmem -hw_device $selected_device -mem_dev $mem_dev]
    } result]} {
        fail "create_hw_cfgmem failed: $result"
    }

    set_property PROGRAM.FILES               [list $prog_file] $hw_cfgmem
    set_property PROGRAM.ADDRESS_RANGE       {use_file}        $hw_cfgmem
    set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none}    $hw_cfgmem
    set_property PROGRAM.BLANK_CHECK         0                 $hw_cfgmem
    set_property PROGRAM.ERASE               1                 $hw_cfgmem
    set_property PROGRAM.CFG_PROGRAM         1                 $hw_cfgmem
    set_property PROGRAM.VERIFY              1                 $hw_cfgmem
    set_property PROGRAM.CHECKSUM            0                 $hw_cfgmem

    catch {refresh_hw_device $selected_device}

    if {[catch {program_hw_cfgmem -hw_cfgmem $hw_cfgmem} result]} {
        fail "program_hw_cfgmem failed: $result"
    }

    catch {refresh_hw_device $selected_device}
    puts "SUCCESS: programmed QSPI flash with $prog_file"
    puts ""
    puts "Next steps:"
    puts "  1. Set the Nexys A7 mode jumper (JP1) to the QSPI position."
    puts "  2. Press the red PROG button, or power-cycle the board."
    puts "  3. The FPGA should now load this design at every power-on."
}

catch {close_hw_manager}
exit 0
