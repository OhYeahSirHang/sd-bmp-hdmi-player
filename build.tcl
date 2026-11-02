# Portable Vivado build script for sd_bmp_video320 submission.
# Usage (Windows):
#   D:/Xilinx/Vivado/2022.2/bin/vivado.bat -mode batch -source build/build.tcl
# The project copy under build/vivado_project is self-contained.

set build_dir [file normalize [file dirname [info script]]]
set proj_dir  [file join $build_dir vivado_project]
set proj_file [file join $proj_dir sd_bmp_hdmi.xpr]
set out_dir   [file join $build_dir output]

if {![file exists $proj_file]} {
    puts "ERROR: project not found: $proj_file"
    exit 1
}
file mkdir $out_dir
open_project $proj_file
puts "TOP=[get_property top [current_fileset]]"
puts "PART=[get_property part [current_project]]"

# Runs may have no run directory after copying; reset if possible, then launch.
catch {reset_run synth_1}
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "SYNTH_PROGRESS=[get_property PROGRESS [get_runs synth_1]]"
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "== SYNTH FAILED =="
    exit 1
}

catch {reset_run impl_1}
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL_PROGRESS=[get_property PROGRESS [get_runs impl_1]]"
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "== IMPL FAILED =="
    exit 1
}

open_run impl_1
report_utilization    -file [file join $build_dir reports report_impl_util.rpt]
report_timing_summary -file [file join $build_dir reports report_impl_timing.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
    -file [file join $build_dir reports report_hier_util.rpt]
report_clock_utilization -file [file join $build_dir reports report_clock_util.rpt]

set bit_src [file join $proj_dir sd_bmp_hdmi.runs impl_1 sd_rd_img.bit]
set bit_dst [file join $out_dir sd_rd_img.bit]
if {[file exists $bit_src]} {
    file copy -force $bit_src $bit_dst
    puts "BITSTREAM=$bit_dst"
}
puts "== BUILD OK =="
