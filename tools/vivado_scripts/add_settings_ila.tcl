# ============================================================================================
# add_settings_ila.tcl -- create the ILA debug core used to capture settings_flash SPI traffic.
#
# Run ONCE inside Vivado (Tcl Console):
#     source tools/vivado_scripts/add_settings_ila.tcl
#
# Creates an IP named `settings_ila` with 16 probes matching the instantiation inside
# settings_flash.sv (guarded by the DEBUG_ILA parameter). The core is explicitly instantiated
# in RTL rather than inserted into the netlist via mark_debug, deliberately: netlist insertion
# depends on constraints binding to net names that survive optimisation, and this project has
# repeatedly been bitten by constraints that silently matched nothing. An instantiated core
# either connects or the build errors -- no silent failure mode.
#
# Probe map (keep in sync with settings_flash.sv). Only FIVE probes, because Vivado's BASIC
# ChipScope license refuses to synthesize an ILA with more than 5 -- "[Chipscope 16-620] ... more
# than 5 probes enabled". Probe WIDTH is not restricted, so everything is packed into 5 buses.
# The split is chosen so the two things we trigger on (state) and qualify capture on (xfer_done)
# land conveniently: state is its own probe, and xfer_done is bit 0 of the flags probe.
#   0 state[4:0]                                                            5 bits
#   1 rx_byte[7:0]                                                          8 bits
#   2 {flash_cs_n, sck_r, flash_mosi, flash_miso}                           4 bits  (bit3..bit0)
#   3 {do_save, busy, eos, xfer_start, xfer_active, xfer_done}              6 bits  (bit5..bit0)
#   4 {tx_byte[7:0], byte_idx[4:0], cs_dly[5:0], bit_cnt[3:0]}             23 bits  (bit22..bit0)
# ============================================================================================

set ip_name "settings_ila"

if {[llength [get_ips -quiet $ip_name]]} {
    puts "INFO: '$ip_name' already exists -- deleting and recreating so this script is re-runnable."
    export_ip_user_files -of_objects [get_files -quiet [get_property IP_FILE [get_ips $ip_name]]] \
        -no_script -reset -force -quiet
    remove_files [get_files [get_property IP_FILE [get_ips $ip_name]]]
}

# Don't hardcode the IP version -- pick the newest ila available in this Vivado.
set ila_def [lindex [lsort [get_ipdefs -all xilinx.com:ip:ila:*]] end]
if {$ila_def eq ""} { error "No xilinx.com:ip:ila IP definition found." }
puts "INFO: using $ila_def"

create_ip -vlnv $ila_def -module_name $ip_name

# Probe count first: the per-probe width properties do not exist until it is committed.
# (Same ordering dependency that forced the split set_property calls in add_1024x768_clocks.tcl.)
set_property -dict [list CONFIG.C_NUM_OF_PROBES {5}] [get_ips $ip_name]

set widths {5 8 4 6 23}
set probe_cfg [list]
for {set i 0} {$i < 5} {incr i} {
    lappend probe_cfg CONFIG.C_PROBE${i}_WIDTH [lindex $widths $i]
}
set_property -dict $probe_cfg [get_ips $ip_name]

# 4096 samples deep. C_EN_STRG_QUAL is the important one: it turns on basic capture control, so at
# RUNTIME (no rebuild) we can choose between capturing every 125MHz cycle -- a 32.7us window, enough
# to see CS/SCK edges around one command -- and capturing only when xfer_done is high, which stores
# one sample per SPI byte and covers thousands of bytes of protocol.
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
puts "  capture ctrl: [get_property CONFIG.C_EN_STRG_QUAL  [get_ips $ip_name]]"
puts ""
puts "Next: set DEBUG_FLASH_ILA = 1'b1 in top.sv, then synthesize + implement."
puts "-------------------------------------------------------------------"
