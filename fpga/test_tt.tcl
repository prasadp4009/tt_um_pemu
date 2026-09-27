# test_tt.tcl -- program the TT-wrapper bitstream and run the test.py-equivalent
# self-test on hardware.
# Usage: vivado -mode batch -source fpga/test_tt.tcl -tclargs <FREQ> <fault>
#   FREQ:  50, 100, 125, or 150 (programs fpga/emu_tt_<FREQ>.bit)
#   fault: 0=normal (expect tt_pass=1, fail_code=0)
#          1=vacuity (loader expects PE_RUNNING after HALT -> must fail
#             at the post-HALT RD_STATUS check with fail_code=0x0E)
# Prints: heartbeats, decoded status word + milestone table, signature,
# observation registers, PASS/FAIL.
#
# SPDX-License-Identifier: Apache-2.0

set FREQ  [lindex $argv 0]
set fault [lindex $argv 1]
puts "=== TT TEST ${FREQ} MHz fault=$fault ==="

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices xc7z010_1] 0]
current_hw_device $dev
refresh_hw_device $dev

# --- program the bitstream for this frequency ---
set bitfile "fpga/emu_tt_${FREQ}.bit"
if {![file exists $bitfile]} { puts "FAIL: bitfile not found: $bitfile"; exit 1 }
set_property PROGRAM.FILE [file normalize $bitfile] $dev
set_property PROBES.FILE [file normalize "fpga/emu_tt_${FREQ}.ltx"] $dev
program_hw_devices $dev
refresh_hw_device $dev

# --- find the two VIOs: main (has vio_start_test) and dbg (has tt_dbg0) ---
set vio_main ""
set vio_dbg ""
foreach v [get_hw_vios] {
    refresh_hw_vio $v
    set has_main 0
    set has_dbg 0
    foreach p [get_hw_probes -of_objects $v] {
        set pname [lindex [split $p /] end]
        if {$pname eq "vio_start_test"} { set has_main 1 }
        if {$pname eq "tt_dbg0"}        { set has_dbg 1 }
    }
    if {$has_main} { set vio_main $v }
    if {$has_dbg}  { set vio_dbg $v }
}
if {$vio_main eq ""} { puts "FAIL: main VIO (vio_start_test) not found"; exit 1 }
if {$vio_dbg eq ""}  { puts "FAIL: dbg VIO (tt_dbg0) not found"; exit 1 }
puts "main VIO: $vio_main"
puts "dbg  VIO: $vio_dbg"
puts "programmed $bitfile"

set ::probe_map [dict create]
foreach p [get_hw_probes -of_objects $vio_main] {
    set pname [lindex [split $p /] end]
    dict set ::probe_map $pname $p
}
set ::vio $vio_main
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

set ::dbg_map [dict create]
foreach p [get_hw_probes -of_objects $vio_dbg] {
    set pname [lindex [split $p /] end]
    dict set ::dbg_map $pname $p
}
proc din {sig} {
    refresh_hw_vio $::vio_dbg
    set p [dict get $::dbg_map $sig]
    return [hex2int [get_property INPUT_VALUE $p]]
}

# --- 1. clock heartbeat: test clock must be alive ---
set hb1 [hex2int [vin vio_heartbeats]]
after 1000
set hb2 [hex2int [vin vio_heartbeats]]
puts "heartbeat1=0x[format %08x $hb1] heartbeat2=0x[format %08x $hb2]"
if {$hb2 == $hb1} { puts "FAIL: test clock not toggling (MMCM not locked?)"; exit 1 }
puts "clocks OK: test_clk alive"

# --- 2. pulse reset ---
vout vio_reset 1
after 200
vout vio_reset 0
after 200
# --- 3. inject_fault per arg ---
vout vio_inject_fault $fault
# --- 4. start ---
vout vio_start_test 1

# --- 5. poll for completion: tt_pass || fail_code != 0 (up to 120s) ---
set status 0; set done 0
for {set i 0} {$i < 120} {incr i} {
    after 1000
    set status [hex2int [vin vio_status]]
    set tpass [expr {($status >> 31) & 1}]
    set fcode [expr {($status >> 16) & 0xFF}]
    if {$tpass || $fcode != 0} { set done 1; break }
}
if {!$done} { puts "FAIL: test did not complete in 120s, status=0x[format %08x $status]"; exit 1 }

set ms     [expr {$status & 0xFFFF}]
set fcode  [expr {($status >> 16) & 0xFF}]
set tpass  [expr {($status >> 31) & 1}]
set sig    [hex2int [vin vio_signature]]
set dbg0   [din tt_dbg0]
set dbg1   [din tt_dbg1]
set dbg2   [din tt_dbg2]

puts "status=0x[format %08x $status] (tt_pass=$tpass fail_code=0x[format %02x $fcode] milestones=0x[format %04x $ms])"
puts "signature=0x[format %08x $sig]"

set mnames {TX_IDLE ST_PROG LOAD0 LOAD1 VF0 VF1 GO RUNNING DRAIN1 HALTED DRAIN2 XFER PULSE SPIOK TXFIFO}
puts "--- milestones ---"
for {set b 0} {$b < 15} {incr b} {
    set hit [expr {($ms >> $b) & 1}]
    puts "  [format %2d $b] [lindex $mnames $b]: [expr {$hit ? {HIT} : {miss}}]"
}

set st_prog [expr {$dbg0 & 0xFF}]
set st_run  [expr {($dbg0 >> 8) & 0xFF}]
set st_halt [expr {($dbg0 >> 16) & 0xFF}]
puts "RD_STATUS: prog=0x[format %02x $st_prog] run=0x[format %02x $st_run] halt=0x[format %02x $st_halt]"

set saw_pulse [expr {($dbg1 >> 31) & 1}]
set spi_ok    [expr {($dbg1 >> 30) & 1}]
set edge_cnt  [expr {($dbg1 >> 16) & 0xFF}]
set mosi      [expr {$dbg1 & 0xFFFF}]
puts "SPI pins: saw_pulse=$saw_pulse spi_ok=$spi_ok sclk_edges=$edge_cnt mosi=0x[format %04x $mosi] (expect 16 / 0xa53c)"

set txf_n     [expr {($dbg2 >> 24) & 0xFF}]
set txf_zeros [expr {($dbg2 >> 16) & 0xFF}]
set txf_bad   [expr {($dbg2 >> 15) & 1}]
set three_z   [expr {($dbg2 >> 14) & 1}]
puts "TXFIFO: words=$txf_n zeros=$txf_zeros bad=$txf_bad three_consecutive_zero=$three_z"

# --- 6. verdict ---
if {$fault == 1} {
    if {!$tpass && $fcode == 0x0E} {
        puts "VACUITY-OK: fault run failed exactly at post-HALT RD_STATUS (fail_code=0x0E), no false pass"
    } else {
        puts "FAIL: vacuity run did not behave as designed (tpass=$tpass fcode=0x[format %02x $fcode])"
        exit 1
    }
} else {
    if {$tpass && $fcode == 0} {
        if {$ms == 0x7FFF} {
            puts "PASS: all 15 TT milestones hit, signature=0x[format %08x $sig]"
        } else {
            puts "FAIL: tt_pass set but milestones incomplete (0x[format %04x $ms] != 0x7fff)"
            exit 1
        }
    } else {
        puts "FAIL: tpass=$tpass fcode=0x[format %02x $fcode]"
        exit 1
    }
}
