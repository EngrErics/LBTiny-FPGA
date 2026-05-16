# ================================================================
# Vivado batch build for LBTiny-MemBus on Digilent Nexys A7
# Called by build_bitstream.bat
# ================================================================

if {$argc < 1} {
    puts "ERROR: missing FPGA part. Example: vivado -mode batch -source vivado_build.tcl -tclargs xc7a100tcsg324-1"
    exit 1
}

set part_name [lindex $argv 0]
set proj_name "LBTiny-MemBus"
set top_name  "lbtiny_top"
set root_dir  [file normalize "."]
set build_dir [file join $root_dir "build"]
set src_dir   [file join $root_dir "src"]

file mkdir $build_dir
cd $build_dir

# Start clean each time. Remove this block if you want incremental builds.
if {[file exists [file join $build_dir $proj_name.xpr]]} {
    close_project -quiet
    file delete -force [file join $build_dir $proj_name.cache]
    file delete -force [file join $build_dir $proj_name.hw]
    file delete -force [file join $build_dir $proj_name.ip_user_files]
    file delete -force [file join $build_dir $proj_name.runs]
    file delete -force [file join $build_dir $proj_name.sim]
    file delete -force [file join $build_dir $proj_name.srcs]
    file delete -force [file join $build_dir $proj_name.xpr]
}

create_project $proj_name $build_dir -part $part_name
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# Source files
add_files -norecurse [file join $src_dir "lbtiny_bus_slave.v"]
add_files -norecurse [file join $src_dir "lbtiny_top.v"]
set_property top $top_name [current_fileset]

# Memory init used by $readmemh in synthesis/simulation.
add_files -fileset sources_1 -norecurse [file join $src_dir "rom_init.mem"]
set_property file_type {Memory Initialization Files} [get_files [file join $src_dir "rom_init.mem"]]
set_property used_in_synthesis true [get_files [file join $src_dir "rom_init.mem"]]
set_property used_in_implementation true [get_files [file join $src_dir "rom_init.mem"]]

# Constraints
add_files -fileset constrs_1 -norecurse [file join $src_dir "lbtiny.xdc"]

update_compile_order -fileset sources_1

# Build
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%" || [get_property STATUS [get_runs synth_1]] !~ "*Complete*"} {
    puts "ERROR: synthesis did not complete successfully"
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%" || [get_property STATUS [get_runs impl_1]] !~ "*Complete*"} {
    puts "ERROR: implementation/bitstream did not complete successfully"
    exit 1
}

set bit_file [file join $build_dir "$proj_name.runs" "impl_1" "$top_name.bit"]
if {![file exists $bit_file]} {
    puts "ERROR: expected bitstream not found: $bit_file"
    exit 1
}

puts "SUCCESS: $bit_file"
exit 0
