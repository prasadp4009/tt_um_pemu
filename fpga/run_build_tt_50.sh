#!/bin/bash
# run_build_tt_50.sh -- build the TT-wrapper bitstream at 50 MHz in the background.
# SPDX-License-Identifier: Apache-2.0
set -u
REPO=~/asic/projects/js-pemu
cd "$REPO" || exit 1
export PATH=/home/prasadp4009/tools/xilinx/2026.1/Vivado/bin:$PATH
export XILINXD_LICENSE_FILE=/home/prasadp4009/licences/xilinx.lic
export LD_LIBRARY_PATH=/home/jarvis/lib/ncurses5/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
mkdir -p fpga/logs
vivado -mode batch -source fpga/build_tt.tcl -tclargs 50 \
  > fpga/logs/build_tt_50.log 2>&1
echo "exit=$?  log=fpga/logs/build_tt_50.log"
