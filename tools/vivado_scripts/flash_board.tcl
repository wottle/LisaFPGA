# Write a bitstream to the board's config flash (W25Q128JVSIQ) over JTAG. Written with an AI assistant.
#   C:/AMDDesignTools/2026.1/Vivado/bin/vivado.bat -mode batch -source tools/vivado_scripts/flash_board.tcl -tclargs <file.mcs>
# With no argument it writes the committed LisaFPGA.runs/impl_1/top.mcs. Only with the Lisa OFF and the user's go-ahead.
# - 3 MHz JTAG: the default 15 MHz fails verify part-way ([Labtools 27-3347], which wrongly blames the flash part).
# - ADDRESS_RANGE use_file erases only the bitstream's sectors, so the saved settings at 0xC00000 survive.
# - If it fails, do NOT power-cycle (the board would come up unconfigured): just run it again.
# Afterwards the FPGA runs Vivado's flash loader: a cold power cycle (board switch) boots the new design.
set root [file normalize [file join [file dirname [info script]] ../..]]
set mcs [expr {[llength $argv] ? [lindex $argv 0] : "$root/LisaFPGA.runs/impl_1/top.mcs"}]
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
close_hw_target
set_property PARAM.FREQUENCY 3000000 [current_hw_target]
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROBES.FILE {} $dev
set_property FULL_PROBES.FILE {} $dev
refresh_hw_device -update_hw_probes false $dev
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}] 0]
set cm [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE {use_file} $cm
set_property PROGRAM.FILES [list $mcs] $cm
set_property PROGRAM.PRM_FILE {} $cm
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cm
set_property PROGRAM.BLANK_CHECK 0 $cm
set_property PROGRAM.ERASE 1 $cm
set_property PROGRAM.CFG_PROGRAM 1 $cm
set_property PROGRAM.VERIFY 1 $cm
set_property PROGRAM.CHECKSUM 0 $cm
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $cm
puts "FLASH_OK"
close_hw_manager
