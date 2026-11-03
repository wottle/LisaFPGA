# Load a bitstream into the FPGA over JTAG (volatile: a power cycle boots the flash again). Written with an AI assistant.
#   C:/AMDDesignTools/2026.1/Vivado/bin/vivado.bat -mode batch -source tools/vivado_scripts/jtag_load.tcl -tclargs <file.bit>
# With no argument it loads the committed LisaFPGA.runs/impl_1/top.bit. The emulated Lisa comes up switched OFF.
set root [file normalize [file join [file dirname [info script]] ../..]]
set bit [expr {[llength $argv] ? [lindex $argv 0] : "$root/LisaFPGA.runs/impl_1/top.bit"}]
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROBES.FILE {} $dev
set_property FULL_PROBES.FILE {} $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "DONE pin: [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
close_hw_target
close_hw_manager
