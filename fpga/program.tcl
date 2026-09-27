# program.tcl -- program the Zybo PL with a bitstream via the live hw_server.
# Run from the repo root:
#   vivado -mode batch -source fpga/program.tcl -tclargs <FREQ>
# Programs fpga/emu_top_<FREQ>.bit.
set FREQ [lindex $argv 0]
set bitfile "fpga/emu_top_${FREQ}.bit"
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
current_hw_device [get_hw_devices xc7z010_1]
refresh_hw_device [lindex [get_hw_devices xc7z010_1] 0]
set_property PROGRAM.FILE $bitfile [get_hw_devices xc7z010_1]
program_hw_devices [get_hw_devices xc7z010_1]
refresh_hw_device [lindex [get_hw_devices xc7z010_1] 0]
puts "PROGRAM DONE: $bitfile"
close_hw_manager
