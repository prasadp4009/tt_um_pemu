# test_freq.tcl -- program one bitstream and run Phase A+B self-test.
# Usage: vivado -mode batch -source fpga/test_freq.tcl -tclargs <FREQ> <fault>
#   FREQ:  50, 100, 125, or 150 (programs fpga/emu_top_<FREQ>.bit)
#   fault: 0=normal 1=vacuity (expect final RD_STATUS 0x41 instead of 0x40)
# Prints: heartbeats, decoded status word, signature, PASS/FAIL.

set FREQ  [lindex $argv 0]
set fault [lindex $argv 1]
puts "=== TEST ${FREQ} MHz fault=$fault ==="

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices xc7z010_1] 0]
current_hw_device $dev
refresh_hw_device $dev

# --- program the bitstream for this frequency ---
set bitfile "fpga/emu_top_${FREQ}.bit"
if {![file exists $bitfile]} { puts "FAIL: bitfile not found: $bitfile"; exit 1 }
set_property PROGRAM.FILE [file normalize $bitfile] $dev
set_property PROBES.FILE [file normalize "fpga/emu_top_${FREQ}.ltx"] $dev
program_hw_devices $dev
refresh_hw_device $dev
# refresh_hw_vio is required for the probes to appear (not just refresh_hw_device)
refresh_hw_vio [lindex [get_hw_vios] 0]
puts "programmed $bitfile"

# --- VIO helpers: probes are named by signal (vio_start_test, etc.) ---
set ::vio [lindex [get_hw_vios] 0]
# Build a name->probe map (get_hw_probes pattern matching is unreliable)
set ::probe_map [dict create]
foreach p [get_hw_probes -of_objects $::vio] {
    # probe name is the last component, e.g. "vio_start_test"
    set pname [lindex [split $p /] end]
    dict set ::probe_map $pname $p
}
proc vout {sig val} {
    set p [dict get $::probe_map $sig]
    set_property OUTPUT_VALUE $val $p
    commit_hw_vio $::vio
}
proc vin {sig} {
    refresh_hw_vio $::vio
    set p [dict get $::probe_map $sig]
    return [get_property INPUT_VALUE $p]
}
proc hex2int {h} { scan $h %x v; return $v }

# --- 1. clock heartbeats: both halves of vio_heartbeats must increment ---
set hb1 [hex2int [vin vio_heartbeats]]
after 1000
set hb2 [hex2int [vin vio_heartbeats]]
set c125_1 [expr {($hb1 >> 16) & 0xFFFF}]; set tc_1 [expr {$hb1 & 0xFFFF}]
set c125_2 [expr {($hb2 >> 16) & 0xFFFF}]; set tc_2 [expr {$hb2 & 0xFFFF}]
puts "heartbeat1=0x[format %08x $hb1] heartbeat2=0x[format %08x $hb2]"
if {$c125_2 == $c125_1} { puts "FAIL: 125MHz clock not toggling"; exit 1 }
if {$tc_2 == $tc_1}     { puts "FAIL: test clock not toggling (MMCM not locked?)"; exit 1 }
puts "clocks OK: clk125 alive, test_clk alive"

# --- 2. pulse reset ---
vout vio_reset 1
after 200
vout vio_reset 0
after 200
# --- 3. inject_fault per arg ---
vout vio_inject_fault $fault
# --- 4. start ---
vout vio_start_test 1

# --- 5. poll for completion: phaseB_pass || fail_code != 0 ---
set status 0; set done 0
for {set i 0} {$i < 60} {incr i} {
    after 1000
    set status [hex2int [vin vio_status]]
    set bpass [expr {($status >> 30) & 1}]
    set fcode [expr {($status >> 16) & 0xFF}]
    if {$bpass || $fcode != 0} { set done 1; break }
}
if {!$done} { puts "FAIL: test did not complete in 60s, status=0x[format %08x $status]"; exit 1 }

set sig [hex2int [vin vio_signature]]
set apass [expr {($status >> 31) & 1}]
set bpass [expr {($status >> 30) & 1}]
set fcode [expr {($status >> 16) & 0xFF}]
set ms    [expr {$status & 0xFFFF}]

set mnames {A_autobaud A_run1 A_halt A_run2 B_load B_verify B_go B_wr \
            B_haltseen B_pinseq B_status B_txdata m12 m13 m14 m15}
puts "status=0x[format %08x $status] sig=0x[format %08x $sig]"
puts "phaseA_pass=$apass phaseB_pass=$bpass fail_code=0x[format %02x $fcode]"
set msbits {}
for {set b 0} {$b < 16} {incr b} {
    if {($ms >> $b) & 1} { lappend msbits [lindex $mnames $b] }
}
puts "milestones_reached: $msbits"

# --- 6. re-arm loader ---
vout vio_start_test 0
after 200

if {$fault} {
    # vacuity run: we EXPECT failure (fail_code 0x0F from the 0x41 expectation)
    if {$fcode == 0x0F && !$bpass} {
        puts "VACUITY OK: injected fault detected (fail_code=0x0F), test correctly FAILs"
    } else {
        puts "VACUITY BROKEN: fault injected but test did not fail as expected!"
        exit 1
    }
} else {
    if {$bpass && $apass && $fcode == 0} {
        puts "RESULT: PASS at ${FREQ} MHz"
    } else {
        puts "RESULT: FAIL at ${FREQ} MHz (fail_code=0x[format %02x $fcode])"
        exit 1
    }
}
close_hw_manager
