# ================================================================
# Vivado batch build for LBTiny on Digilent Nexys A7
# Called by build_bitstream.bat
#
# Usage:
#   vivado -mode batch -source vivado_build.tcl -tclargs xc7a100tcsg324-1 [bringup|top]
#
# Second argument selects the build target (default: bringup).
#   bringup  -> lbtiny_bringup_top + lbtiny_bringup.xdc  (no CPU, safe first build)
#   top      -> lbtiny_top + lbtiny.xdc                  (integrated with CPU)
# ================================================================

if {$argc < 1} {
    puts "ERROR: missing FPGA part. Example: vivado -mode batch -source vivado_build.tcl -tclargs xc7a100tcsg324-1 bringup"
    exit 1
}

set part_name  [lindex $argv 0]
set target     [expr {$argc > 1 ? [lindex $argv 1] : "bringup"}]
set root_dir   [file normalize "."]
set src_dir    [file join $root_dir "src"]

# Shared source files (both tops need these)
set shared_rtl [list \
    [file join $src_dir "lbtiny_mem.v"] \
    [file join $src_dir "lbtiny_viewer.v"] \
]

# Target-specific files and settings
if {$target eq "bringup"} {
    set proj_name "LBTiny-Bringup"
    set top_name  "lbtiny_bringup_top"
    set top_rtl   [file join $src_dir "lbtiny_bringup_top.v"]
    set xdc_file  [file join $src_dir "lbtiny_bringup.xdc"]
} elseif {$target eq "top"} {
    set proj_name "LBTiny-Top"
    set top_name  "lbtiny_top"
    set top_rtl   [list \
        [file join $src_dir "lbtiny_cpu.v"] \
        [file join $src_dir "lbtiny_top.v"] \
    ]
    set xdc_file  [file join $src_dir "lbtiny.xdc"]
} else {
    puts "ERROR: unknown target '$target'. Use 'bringup' or 'top'."
    exit 1
}

set rtl_files  [concat $shared_rtl $top_rtl]
set mem_file   [file join $src_dir "rom_init.mem"]
set build_dir  [file join $root_dir "build" $proj_name]

foreach f [concat $rtl_files [list $mem_file $xdc_file]] {
    if {![file exists $f]} {
        puts "ERROR: required file not found: $f"
        exit 1
    }
}

proc check_run_complete {run_name label} {
    set run_obj  [get_runs $run_name]
    set progress [get_property PROGRESS $run_obj]
    set status   [get_property STATUS $run_obj]
    puts "$label status: $status ($progress)"
    if {$progress ne "100%" || ![string match -nocase "*Complete*" $status]} {
        puts "ERROR: $label did not complete successfully."
        puts "ERROR: Run $run_name status was: $status"
        exit 1
    }
}

file mkdir $build_dir
cd $build_dir

foreach path [list \
    [file join $build_dir $proj_name.cache] \
    [file join $build_dir $proj_name.hw] \
    [file join $build_dir $proj_name.ip_user_files] \
    [file join $build_dir $proj_name.runs] \
    [file join $build_dir $proj_name.sim] \
    [file join $build_dir $proj_name.srcs] \
    [file join $build_dir $proj_name.xpr] \
] {
    if {[file exists $path]} { file delete -force $path }
}

create_project $proj_name $build_dir -part $part_name
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

add_files -norecurse $rtl_files
set_property top $top_name [current_fileset]

add_files -fileset sources_1 -norecurse $mem_file
set mem_obj [get_files $mem_file]
set_property file_type {Memory Initialization Files} $mem_obj
set_property used_in_synthesis true $mem_obj

add_files -fileset constrs_1 -norecurse $xdc_file

update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
check_run_complete synth_1 "Synthesis"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
check_run_complete impl_1 "Implementation/bitstream"

set bit_file [file join $build_dir "$proj_name.runs" "impl_1" "$top_name.bit"]
if {![file exists $bit_file]} {
    puts "ERROR: expected bitstream not found: $bit_file"
    exit 1
}

puts "SUCCESS: $bit_file"
exit 0