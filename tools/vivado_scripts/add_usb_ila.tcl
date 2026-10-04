# ============================================================================================
# add_usb_ila.tcl -- create the ILA used to capture raw USB line activity for the full-speed spike.
#
# Run ONCE inside Vivado (Tcl Console):
#     source tools/vivado_scripts/add_usb_ila.tcl
#
# Then set DEBUG_USB_ILA = 1'b1 in top.sv and build.
#
# FIVE probes, because Vivado's BASIC ChipScope licence hard-ERRORS on an ILA with more than five
# ("[Chipscope 16-620] ... more than 5 probes enabled") -- and it does so at the very END of
# synthesis, so discovering it costs a full run. Probe WIDTH is not restricted.
#
#   0 usb_p1_lines [4:0]   port 1 (KBD): bit4 dp_in, bit3 dm_in, bit2 oe, bit1 dp_out, bit0 dm_out
#   1 usb_p0_lines [4:0]   port 0 (MOUSE): same bit order
#   2 usb_p1_dbg  [18:0]   port 1: bit18 connected, bits17:14 state, bits13:0 pc
#   3 usb_p0_dbg  [18:0]   port 0: same
#   4 usb_status   [7:0]   bit7:6 p1_typ, bit5 p1_report, bit4 p1_conerr,
#                          bit3:2 p0_typ, bit1 p0_report, bit0 p0_conerr
#
# Each port's raw lines get their own probe so they can be triggered on directly without building a
# masked compare by hand -- the same reasoning behind keeping dbg_state separate in the settings ILA.
#
# The core is instantiated in RTL, not inserted into the netlist via mark_debug. Netlist insertion
# depends on constraints binding to net names that survive optimisation, which is precisely the
# failure mode this project keeps hitting. An instantiated core either connects or synthesis errors.
#
# Clocked at usbclk (~96MHz in a full-speed build), so every sample is one 96MHz tick and a
# full-speed bit is 8 samples wide. 4096 deep = 42.7us = about 512 bit times.
# ============================================================================================

if {[llength $argv] > 0} {
    open_project [lindex $argv 0]
}

set ip_name "usb_ila"

if {[llength [get_ips -quiet $ip_name]]} {
    puts "INFO: '$ip_name' already exists -- deleting and recreating so this script is re-runnable."
    export_ip_user_files -of_objects [get_files -quiet [get_property IP_FILE [get_ips $ip_name]]] \
        -no_script -reset -force -quiet
    remove_files [get_files [get_property IP_FILE [get_ips $ip_name]]]
}

set ila_def [lindex [lsort [get_ipdefs -all xilinx.com:ip:ila:*]] end]
if {$ila_def eq ""} { error "No xilinx.com:ip:ila IP definition found." }
puts "INFO: using $ila_def"

create_ip -vlnv $ila_def -module_name $ip_name

# Probe count first: the per-probe width properties do not exist until it is committed.
set_property -dict [list CONFIG.C_NUM_OF_PROBES {5}] [get_ips $ip_name]

set widths {5 5 19 19 8}
set probe_cfg [list]
for {set i 0} {$i < 5} {incr i} {
    lappend probe_cfg CONFIG.C_PROBE${i}_WIDTH [lindex $widths $i]
}
set_property -dict $probe_cfg [get_ips $ip_name]

# C_EN_STRG_QUAL gives basic capture control at RUNTIME, so one bitstream covers both a full-rate
# capture (for judging signal quality) and a qualified one, with no rebuild.
set_property -dict [list \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
    CONFIG.C_TRIGIN_EN {false} \
    CONFIG.C_TRIGOUT_EN {false} \
] [get_ips $ip_name]

generate_target all [get_files [get_property IP_FILE [get_ips $ip_name]]]
catch { config_ip_cache -export [get_ips $ip_name] }
export_ip_user_files -of_objects [get_files [get_property IP_FILE [get_ips $ip_name]]] -no_script -sync -force -quiet
create_ip_run [get_files [get_property IP_FILE [get_ips $ip_name]]]

puts "-------------------------------------------------------------------"
puts "Created IP '$ip_name'."
puts "  probes      : [get_property CONFIG.C_NUM_OF_PROBES [get_ips $ip_name]]"
puts "  depth       : [get_property CONFIG.C_DATA_DEPTH    [get_ips $ip_name]]"
puts ""
puts "Next: set DEBUG_USB_ILA = 1'b1 in top.sv, then synthesize + implement."
puts "-------------------------------------------------------------------"
