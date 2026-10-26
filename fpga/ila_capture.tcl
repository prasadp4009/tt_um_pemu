# ila_capture.tcl -- capture ILA waveform during test.
# Usage: vivado -mode batch -source fpga/ila_capture.tcl -tclargs <FREQ>
# Assumes fpga/emu_top_<FREQ>.bit is programmed (or programs it).
# Writes fpga/ila_<FREQ>mhz.vcd and .csv.

set FREQ [lindex $argv 0]
puts "=== ILA CAPTURE at ${FREQ} MHz ==="

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices xc7z010_1] 0]
current_hw_device $dev
set_property PROBES.FILE [file normalize "fpga/emu_top_${FREQ}.ltx"] $dev
refresh_hw_device $dev

# VIO for control
set vio [lindex [get_hw_vios] 0]
refresh_hw_vio $vio
set pmap [dict create]
foreach p [get_hw_probes -of_objects $vio] {
    dict set pmap [lindex [split $p /] end] $p
}
proc vout {s v} {
    set_property OUTPUT_VALUE $v [dict get $::pmap $s]
    commit_hw_vio $::vio
}
proc vin {s} {
    refresh_hw_vio $::vio
    return [get_property INPUT_VALUE [dict get $::pmap $s]]
}
proc h2i {h} { scan $h %x v; return $v }
set ::vio $vio
set ::pmap $pmap

# ILA
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
refresh_hw_device $dev  ;# fixed: no refresh_hw_ila cmd
puts "ILA probes:"
foreach p [get_hw_probes -of_objects $ila] { puts "  [lindex [split $p /] end]" }

# Reset and start test
vout vio_reset 1; after 200; vout vio_reset 0; after 200
vout vio_inject_fault 0

# Arm ILA (no trigger, just capture)
run_hw_ila $ila
after 500
vout vio_start_test 1
puts "Test started, waiting for ILA..."
wait_on_hw_ila -timeout 60 $ila
puts "ILA capture done"

# Wait for test completion
for {set i 0} {$i < 60} {incr i} {
    after 1000
    set st [h2i [vin vio_status]]
    if {(($st >> 30) & 1) || ((($st >> 16) & 0xFF) != 0)} { break }
}
puts "Final status: 0x[format %08x $st]"
vout vio_start_test 0

set idata [get_hw_ila_data $ila]
write_hw_ila_data -force -vcd_file fpga/ila_${FREQ}mhz.vcd $idata
write_hw_ila_data -force -csv_file fpga/ila_${FREQ}mhz.csv $idata
puts "Wrote fpga/ila_${FREQ}mhz.vcd and .csv"
close_hw_manager
