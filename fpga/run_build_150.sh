#!/bin/bash
cd /home/jarvis/asic/projects/js-pemu
export PATH=/home/prasadp4009/tools/xilinx/2026.1/Vivado/bin:$PATH
export XILINXD_LICENSE_FILE=/home/prasadp4009/licences/xilinx.lic
export LD_LIBRARY_PATH=/home/jarvis/lib/ncurses5/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
echo "=== BUILD 150MHz START ==="
vivado -mode batch -source fpga/build.tcl -tclargs 150 -log fpga/build_150.log -journal fpga/build_150.jou
echo "=== BUILD 150MHz EXIT: $? ==="
