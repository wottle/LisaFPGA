# Adds a second, dedicated Clocking Wizard IP (hdmi_clock_divider_1024x768) that generates the
# 65.0MHz pixel clock and 325.0MHz 5x TMDS serialization clock needed for the new fixed
# 1024x768@60Hz HDMI output mode, and reverts any CLKOUT5/CLKOUT6 taps an earlier version of this
# script may have added directly to the stock hdmi_clock_divider IP (see "why a separate IP" below).
#
# *** Why a separate IP instead of just adding two more taps to hdmi_clock_divider? ***
# hdmi_clock_divider's existing four outputs (742.5/371.25/148.5/74.25MHz) all share ONE MMCM VCO
# that's tuned to be a clean multiple of 74.25MHz. 65MHz/325MHz don't share a clean common multiple
# with that VCO -- dividing it by the nearest available integers landed on ~67.47MHz and ~371.09MHz
# (3.8% and 14.2% off nominal), and critically, the ratio between those two came out to 5.5, not 5.
# TMDS serialization via OSERDES2 requires the "5x" clock to be EXACTLY 5x the pixel clock, so that's
# not just imprecise, it's non-functional. A single MMCM only has one VCO, so the two frequency
# families (1080p's 74.25MHz-based clocks and 1024x768's 65MHz-based ones) need two separate MMCMs.
#
# This has to be run once, inside Vivado, before OUTPUT_1024X768 (see top.sv) can be built as 1'b1 --
# IP customization can't safely be hand-edited outside of Vivado, since Vivado tracks a checksum over
# it and needs to regenerate the IP's output products (generated Verilog/DCP) afterwards.
#
# Usage (from a shell, with Vivado on your PATH):
#   vivado -mode batch -source tools/vivado_scripts/add_1024x768_clocks.tcl -tclargs LisaFPGA.xpr
#
# Or from Vivado's Tcl Console with the project already open:
#   source tools/vivado_scripts/add_1024x768_clocks.tcl
#
# Only needs to be run once per checkout; the resulting .xci changes should be committed like any
# other source file.

if {[llength $argv] > 0} {
    open_project [lindex $argv 0]
}

## Step 1: revert the CLKOUT5/CLKOUT6 taps on the stock hdmi_clock_divider IP, if present (an
## earlier version of this script added them there before the shared-VCO problem above was found).
## Harmless / a no-op if they were never added.
if {[get_property CONFIG.CLKOUT5_USED [get_ips hdmi_clock_divider]] eq "true"} {
    set_property -dict [list \
        CONFIG.CLKOUT5_USED {false} \
        CONFIG.CLKOUT6_USED {false} \
    ] [get_ips hdmi_clock_divider]
    puts "Reverted hdmi_clock_divider back to 4 outputs (removed the mistaken CLKOUT5/6 taps)."
}

## Step 2: create the new dedicated IP for the 1024x768 clocks, if it doesn't already exist.
## Cloning hdmi_clock_divider's exact IPDEF (VLNV) keeps the IP core version identical.
if {[llength [get_ips -quiet hdmi_clock_divider_1024x768]] == 0} {
    create_ip -vlnv [get_property IPDEF [get_ips hdmi_clock_divider]] -module_name hdmi_clock_divider_1024x768
}

## Match the non-output-specific settings of the working hdmi_clock_divider IP exactly, since these
## affect actual clocking correctness for the OSERDES-driven TMDS output (both IPs ultimately feed
## the same OSERDES logic in hdmi.sv, via the BUFGMUX in HDMI_Interface.sv). In particular,
## MMCM_COMPENSATION=ZHOLD requires external feedback (which is why clkfb_in/clkfb_out get wired
## through a BUFG in HDMI_Interface.sv for hdmi_clock_divider) -- we need the same treatment here.
## FEEDBACK_SOURCE=FDBK_ONCHIP is what actually exposes the clkfb_in/clkfb_out ports that the BUFG feedback
## loop in HDMI_Interface.sv connects to (the default, FDBK_AUTO, handles feedback internally and exposes no
## such ports). ZHOLD compensation requires that external feedback path, so these two go together. Likewise
## PRIMARY_PORT renames the input clock port from its default clk_in1 to sysclk, matching hdmi_clock_divider.
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {125.000} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.PRIMARY_PORT {sysclk} \
    CONFIG.CLKIN1_JITTER_PS {80.0} \
    CONFIG.FEEDBACK_SOURCE {FDBK_ONCHIP} \
    CONFIG.CLKFB_IN_PORT {clkfb_in} \
    CONFIG.CLKFB_OUT_PORT {clkfb_out} \
    CONFIG.MMCM_COMPENSATION {ZHOLD} \
    CONFIG.MMCM_BANDWIDTH {OPTIMIZED} \
    CONFIG.USE_PHASE_ALIGNMENT {true} \
    CONFIG.USE_FREQ_SYNTH {true} \
    CONFIG.USE_RESET {false} \
    CONFIG.USE_LOCKED {false} \
] [get_ips hdmi_clock_divider_1024x768]

## CLKOUT1 is already enabled by default on a fresh IP -- configure it for the 65MHz pixel clock.
## CLKOUTn_DRIVES must be No_buffer to match hdmi_clock_divider: the BUFGMUXes in HDMI_Interface.sv are
## themselves the clock buffers, so letting the IP insert its own BUFG (the default) creates a redundant
## BUFG->BUFGMUX cascade. That cascade violates Vivado's rule_cascaded_bufg (which wants cascaded BUFGs
## adjacent, and fails placement outright when they land in different halves of the device), adds an extra
## uncompensated buffer delay on a clock feeding OSERDES TMDS serialization, and shifts where Vivado
## auto-derives the output clock -- which in turn stops the XDC's set_clock_groups from matching by name.
set_property -dict [list \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {65.000} \
    CONFIG.CLK_OUT1_PORT {clk_pixel_1024x768} \
    CONFIG.CLKOUT1_DRIVES {No_buffer} \
] [get_ips hdmi_clock_divider_1024x768]

## Enable CLKOUT2 for the 325MHz 5x TMDS clock. This has to be its own set_property call before the
## frequency below -- CLKOUTn_REQUESTED_OUT_FREQ is read-only until CLKOUTn_USED is already committed
## true (see this repo's history for the failed single-dict attempts that discovered this the hard way).
set_property -dict [list \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLK_OUT2_PORT {clk_pixel_x5_1024x768} \
    CONFIG.CLKOUT2_DRIVES {No_buffer} \
] [get_ips hdmi_clock_divider_1024x768]

set_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {325.000} [get_ips hdmi_clock_divider_1024x768]

generate_target all [get_files hdmi_clock_divider.xci]
generate_target all [get_files hdmi_clock_divider_1024x768.xci]
export_ip_user_files -of_objects [get_files hdmi_clock_divider.xci] -no_script -sync -force -quiet
export_ip_user_files -of_objects [get_files hdmi_clock_divider_1024x768.xci] -no_script -sync -force -quiet

puts "hdmi_clock_divider is back to 4 outputs (1080p30/60 clocks, untouched)."
puts "hdmi_clock_divider_1024x768 now exists with 2 outputs: clk_pixel_1024x768 (65MHz) and clk_pixel_x5_1024x768 (325MHz)."
puts "Check the console output above (or the IP customization dialog) for the ACTUAL locked frequencies Vivado chose, AND"
puts "confirm the two outputs' divides land in an exact 5:1 ratio (clk_pixel_x5_1024x768 must be EXACTLY 5x clk_pixel_1024x768"
puts "for TMDS/OSERDES2 serialization to work) -- this is what the shared hdmi_clock_divider VCO could NOT do, which is why"
puts "this is now a separate IP. If the achieved frequencies differ meaningfully from 65.000/325.000 MHz, the audio-clock"
puts "divider threshold in HDMI_Interface.sv (currently 12'd676, see gen_audio_clk_1024x768_fallback) and the XDC's"
puts "clk_audio -divide_by value may need recomputing."
