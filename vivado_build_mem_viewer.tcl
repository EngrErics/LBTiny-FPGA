# ================================================================
# Vivado batch build for standalone LBTiny memory viewer on Nexys A7
# Called by build_mem_viewer_bitstream.bat
# ================================================================

if {$argc < 1} {
    puts "ERROR: missing FPGA part. Example: vivado -mode batch -source vivado_build_mem_viewer.tcl -tclargs xc7a100tcsg324-1"
    exit 1
}

set part_name [lindex $argv 0]
set proj_name "LBTiny-MemViewer"
set top_name  "lbtiny_mem_viewer_top"
set root_dir  [file normalize "."]
set build_dir [file join $root_dir "build_mem_viewer"]
set src_dir   [file join $root_dir "src"]

file mkdir $build_dir
cd $build_dir

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

add_files -norecurse [file join $src_dir "lbtiny_bus_slave.v"]
add_files -norecurse [file join $src_dir "lbtiny_mem_viewer_top.v"]
set_property top $top_name [current_fileset]

# Add the memory init file.  Vivado 2024.2 does not support the
# used_in_implementation property on file objects, so do not set it.
# Keeping the .mem in sources_1 as a Memory Initialization File is enough
# for $readmemh("rom_init.mem", ...) during synthesis/implementation.
add_files -fileset sources_1 -norecurse [file join $src_dir "rom_init.mem"]
set mem_file [get_files [file join $src_dir "rom_init.mem"]]
set_property file_type {Memory Initialization Files} $mem_file
set_property used_in_synthesis true $mem_file

add_files -fileset constrs_1 -norecurse [file join $src_dir "lbtiny_mem_viewer.xdc"]

update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_progress [get_property PROGRESS [get_runs synth_1]]
set synth_status   [get_property STATUS [get_runs synth_1]]
if {$synth_progress ne "100%" || ![string match "*Complete*" $synth_status]} {
    puts "ERROR: synthesis did not complete successfully"
    puts "synth_1 progress: $synth_progress"
    puts "synth_1 status:   $synth_status"
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set impl_progress [get_property PROGRESS [get_runs impl_1]]
set impl_status   [get_property STATUS [get_runs impl_1]]
if {$impl_progress ne "100%" || ![string match "*Complete*" $impl_status]} {
    puts "ERROR: implementation/bitstream did not complete successfully"
    puts "impl_1 progress: $impl_progress"
    puts "impl_1 status:   $impl_status"
    exit 1
}

set bit_file [file join $build_dir "$proj_name.runs" "impl_1" "$top_name.bit"]
if {![file exists $bit_file]} {
    puts "ERROR: expected bitstream not found: $bit_file"
    exit 1
}

puts "SUCCESS: $bit_file"
exit 0
