# ============================================================================================
# add_usb_fs_clock.tcl -- create the dedicated MMCM that clocks the USB host cores.
#
# Run ONCE inside Vivado (Tcl Console):
#     source tools/vivado_scripts/add_usb_fs_clock.tcl
#
# Creates (or reconfigures) an IP named `usb_fs_clock` producing `usbclk_fs` at 60.000MHz, the single
# clock the m1nl fork of usb_hid_host needs: 5x oversampling for full-speed (12Mbps) devices, and an
# internal divide-by-5 prescaler to 12MHz (8x oversampling) for low-speed (1.5Mbps) ones, with the
# speed detected per device at attach. History: this IP first ran at 96MHz for a full-speed-only
# spike on the original core; re-running this script retargets it in place.
#
# WHY A DEDICATED MMCM, not another tap on clock_divider: clock_divider's VCO is
# 125 x 50.125 / 10 = 626.5625MHz, and 60MHz off that needs a divide of 10.443 -- not reachable in
# the 0.125 fractional steps CLKOUT0 allows. Same trap as the 1024x768 clocks; see the "Required
# one-time Vivado step" section of CLAUDE.md. A dedicated MMCM has its own VCO.
#
# *** WHY THE ACCURACY CHECK BELOW MATTERS ***
# USB full-speed hosts must hold 12Mbps to +/-0.05%. Low speed allows +/-1.5%, which forgave a lot;
# full speed will not. This script computes the ACHIEVED frequency from the MMCM divider settings and
# fails loudly if it is out of spec, rather than trusting "no errors" -- which this project has
# learned the hard way is not evidence of anything.
#
# Expected: VCO 900MHz (125 x 36 / 5, as the 96MHz version landed on) / 15 = exactly 60.0000MHz.
# MMCM CLKOUT0 divides in 0.125 steps, so check the achieved figure rather than assuming integers.
# ============================================================================================

if {[llength $argv] > 0} {
    open_project [lindex $argv 0]
}

set ip_name "usb_fs_clock"

# The m1nl usb_hid_host core runs from ONE 60MHz clock: 5x oversampling at full speed (12Mbps), and a
# divide-by-5 prescaler to 12MHz, i.e. 8x oversampling, for low-speed devices -- detected per device.
# (This was 96MHz / 8x for the earlier full-speed-only spike on the original core.)
set target_mhz 60.0
set oversample 5

if {[llength [get_ips -quiet $ip_name]] == 0} {
    # Clone the IPDEF of an existing Clocking Wizard so the core version matches the rest of the
    # project. The property is IPDEF, not VLNV -- getting that wrong is a silent no-match.
    create_ip -vlnv [get_property IPDEF [get_ips clock_divider]] -module_name $ip_name
} else {
    puts "INFO: '$ip_name' already exists -- reconfiguring in place."
}

# Split into separate set_property calls, not one -dict: the Clocking Wizard validates a whole
# dict against the PRE-change state and rolls the entire batch back on any ordering dependency.
#
# No external feedback / ZHOLD here, unlike hdmi_clock_divider. That machinery exists to phase-align
# the TMDS pixel clocks feeding OSERDES; USB is a free-running domain with no such requirement, so
# internal feedback keeps the IP simpler and exposes no clkfb ports to wire up.
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {125.000} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.PRIMARY_PORT {sysclk} \
    CONFIG.CLKIN1_JITTER_PS {80.0} \
    CONFIG.USE_PHASE_ALIGNMENT {false} \
    CONFIG.USE_FREQ_SYNTH {true} \
    CONFIG.USE_RESET {false} \
    CONFIG.USE_LOCKED {false} \
] [get_ips $ip_name]

# CLKOUT1 (wizard numbering) == MMCM CLKOUT0, the one with fractional divide.
# DRIVES = BUFG: this clock goes straight to fabric as usbclk, so the IP should supply the global
# buffer. (Contrast hdmi_clock_divider_1024x768, which uses No_buffer because a BUFGMUX follows it.)
set_property -dict [list \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.CLK_OUT1_PORT {usbclk_fs} \
] [get_ips $ip_name]

set_property -dict [list \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %.3f $target_mhz] \
    CONFIG.CLKOUT1_DRIVES {BUFG} \
] [get_ips $ip_name]

# ---- Verify by arithmetic, not by absence of errors -----------------------------------------
set mult   [get_property CONFIG.MMCM_CLKFBOUT_MULT_F  [get_ips $ip_name]]
set divclk [get_property CONFIG.MMCM_DIVCLK_DIVIDE    [get_ips $ip_name]]
set odiv   [get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F [get_ips $ip_name]]
if {$odiv == 0 || $odiv eq ""} {
    set odiv [get_property CONFIG.MMCM_CLKOUT0_DIVIDE [get_ips $ip_name]]
}

set vco  [expr {125.0 * $mult / $divclk}]
set fout [expr {$vco / $odiv}]
set bitrate [expr {$fout / double($oversample)}]
set err  [expr {($fout - $target_mhz) / $target_mhz * 100.0}]

puts "-------------------------------------------------------------------"
puts [format "  CLKFBOUT_MULT_F   : %s"        $mult]
puts [format "  DIVCLK_DIVIDE     : %s"        $divclk]
puts [format "  CLKOUT0_DIVIDE    : %s"        $odiv]
puts [format "  VCO               : %.4f MHz   (must be 600-1440)" $vco]
puts [format "  usbclk_fs         : %.4f MHz"  $fout]
puts [format "  => USB bit rate   : %.4f Mbps  (error %+.4f%%)" $bitrate $err]
puts "-------------------------------------------------------------------"

if {$vco < 600.0 || $vco > 1440.0} {
    puts "*** ERROR: VCO $vco MHz is outside the 600-1440MHz range for this part. ***"
}
if {abs($err) > 0.05} {
    puts "*** ERROR: bit-rate error [format %+.4f $err]% exceeds the USB full-speed host"
    puts "***        tolerance of +/-0.05%. This clock is NOT spec compliant."
    puts "***        Do not proceed on the assumption that it will work -- adjust the"
    puts "***        requested frequency, or use a fractional bit-rate accumulator instead."
} else {
    puts "OK: within the +/-0.05% USB full-speed host tolerance."
}

generate_target all [get_files [get_property IP_FILE [get_ips $ip_name]]]
catch { config_ip_cache -export [get_ips $ip_name] }
export_ip_user_files -of_objects [get_files [get_property IP_FILE [get_ips $ip_name]]] -no_script -sync -force -quiet
create_ip_run [get_files [get_property IP_FILE [get_ips $ip_name]]]

puts ""
puts "Created/updated IP $ip_name at $target_mhz MHz. Next: build with USB_FULL_SPEED = 1 in top.sv."
