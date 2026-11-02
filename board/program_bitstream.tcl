# Program the default bitstream via Vivado Hardware Manager.
# Usage:
#   D:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source board\program_bitstream.tcl

set script_dir [file normalize [file dirname [info script]]]
set BIT [file join $script_dir bitstreams sd_rd_img_median_canny.bit]
if {![file exists $BIT]} {
    puts "ERROR: bitstream not found: $BIT"
    exit 1
}
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
puts "DEVICE=$dev"
set_property PROGRAM.FILE $BIT $dev
program_hw_devices $dev
puts "PROGRAMMED=$BIT"
close_hw_target
disconnect_hw_server
close_hw_manager
