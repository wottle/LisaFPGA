#!/bin/sh
# Runs a soft-CPU testbench in xsim:  sh tools/usb_fw/sim/run.sh [tb_name]
# Build the firmware first (tools/usb_fw/build.ps1); the testbench loads the same .mem the bitstream does.
TB=${1:-tb_softcpu}
V=/c/AMDDesignTools/2026.1/Vivado/bin
R=$(cd "$(dirname "$0")/../../.." && pwd)
S=$R/LisaFPGA.srcs/sources_1
W=$(dirname "$0")/work; mkdir -p "$W"; cd "$W" || exit 1
cp "$S/new/usb_host_fw.mem" .
SRCS="$S/imports/picorv32/picorv32.v $(ls $S/new/usb_softcpu.sv $S/new/usb_sie*.sv ../usb_dev_model*.sv 2>/dev/null) ../$TB.sv"
"$V/xvlog.bat" -sv $SRCS > xvlog.out 2>&1;          grep -E 'ERROR|WARNING' xvlog.out
"$V/xelab.bat" -debug off $TB -s $TB > xelab.out 2>&1; grep -E 'ERROR' xelab.out
"$V/xsim.bat" $TB -R 2>&1 | grep -v -E '^(\*\*\*\*|  \*\*|Vivado|Copyright|INFO|Time resolution|source|run -all|exit|#|$)'
