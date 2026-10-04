## The XDC file for the LisaFPGA Desktop board. There are a whole lot of pins defined in here!

## As well as some other stuff, like this allowing of combinatorial loops on certain nets
## Which we have to do thanks to the Lisa's architecture
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/BD_out[*]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[13]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[14]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[15]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[16]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[17]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[18]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[19]}]
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets {cpu_board/latched_MMU_address[20]}]

## Tell Vivado that our SPI configuration flash bus is 4 bits wide to maximize bitstream loading speed at boot
## It should be about 4x faster than the default 1x configuration; almost instantaneous
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]

## Make sure Vivado knows about synchronizers we have in the design to avoid timing issues
## If we don't do this, Vivado will think we have timing violations on these paths, when in fact we don't
## The literal purpose of these paths is to fix the timing violations caused by clock domain crossings!
## False-path into the first stage of the HDMI reset synchronizer
## The whole point of the synchronizer is to get reset from the DOTCK domain into the clk_pixel domain
## So we need to tell Vivado to relax and ignore the timing violations on the synchronizer's first stage since we're already handling it
set_false_path -to [get_cells lisa_hdmi_output/_reset_hdmi_int_reg]
## False-path into the first stage of the I/O board reset synchronizer
set_false_path -to [get_cells io_board/_RESET_int_reg]
## False-path into the first stage of the USB reset synchronizer
set_false_path -to [get_cells usbrst_int_reg]
## False-path into the first stage of the I/O board AS synchronizer
set_false_path -to [get_cells io_board/_AS_int_reg]
## False-path into the INTIO synchronizer on the I/O board; ignore it because the synchronizer once again handles the DOTCK-to-C16M CDC
set_false_path -to [get_cells io_board/_INTIO_int_reg]
## False-path into the first stage of the _PSTRB_ungated synchronizer
set_false_path -to [get_cells io_board/_PSTRB_ungated_int_reg]

## Here are some more false paths for the system ON signal
## These goes into the DOTCK BUFGCTRL and serves as the clock enables
## The signals come from the COP, and then we synchronize them into the domains of their respective BUFGCTRLs
## First up, do DOTCK
set_false_path -to [get_cells ON_int_dotck_reg]
## Same for C16M
set_false_path -to [get_cells ON_int_c16m_reg]
## And C5M
set_false_path -to [get_cells ON_int_c5m_reg]
## And SCCCK
set_false_path -to [get_cells ON_int_sccck_reg]

## Another ON-related false path: the blank_video signal that goes into the HDMI_Interface
## This blanks the video when Lisa is off and is literally just the ON signal, but once again we have a CDC issue between COPCK and clk_pixel
## There's a synchronizer on the HDMI_Interface side, but we still need to declare the false path to avoid timing violations
set_false_path -to [get_cells lisa_hdmi_output/blank_video_int_reg]

## Now do false paths for all of the interrupt signals that go to the CPU
## We're properly synchronizing all of them on the CPU board
set_false_path -to [get_cells cpu_board/_RSIR_int_reg]
set_false_path -to [get_cells cpu_board/_INT0_int_reg]
set_false_path -to [get_cells cpu_board/_INT1_int_reg]
set_false_path -to [get_cells cpu_board/_INT2_int_reg]
set_false_path -to [get_cells cpu_board/_KBIR_int_reg]
## These next few signals don't feed directly into the interrupt encoder, but they're used to generate HPIR and IOIR_internal
## So they indirectly feed in and also must be synchronized
set_false_path -to [get_cells cpu_board/_NMI_int_reg]
set_false_path -to [get_cells cpu_board/_HDER_latched_int_reg]
set_false_path -to [get_cells cpu_board/_SFER_latched_int_reg]
set_false_path -to [get_cells cpu_board/_IOIR_int_reg]
set_false_path -to [get_cells cpu_board/_VTIR_int_reg]

## This RSTSW-related false path goes from the COPCK_2x to the DOTCK domain; RSTSW is gated with ON in a FF which is why it's in COPCK at all
set_false_path -to [get_cells _RSTSW_dotck_int_reg]

## This false path goes into the synchronizer that syncronizes the _RESET signal to the SCCCK_2x domain for the SCCCK divide by 2 logic
set_false_path -to [get_cells _RESET_SCCCK_int_reg]

## Here's a false path between the 6522 and the COP for our extended-length DDRA data strobe signal
## I'm synchronizing this signal into the COPCK_2x domain, so we just need to declare a false path into the synchronizer
set_false_path -to [get_cells io_board/KBD_via_DDRA_extended_int_reg]

## The CONT register on the I/O board is clocked by the DOTCK, but we read the contrast in the 1080p30/60 domain
## We have a synchronizer for this, so we just need to declare a false path for it
set_false_path -to [get_cells {lisa_hdmi_output/CONT_int_reg[*]}]

## Same deal for TONE and VC, which come from the I/O board in the DOTCK domain and get read in the ~48KHz
## clk_audio domain to build the audio samples. HDMI_Interface.sv has proper two-stage ASYNC_REG synchronizers
## on both, so false-path into their first stages. (These only started showing up as hold violations once the
## clk_audio generated-clock constraint actually applied -- before that clk_audio was unconstrained and these
## CDC paths simply weren't being analyzed at all. Applies to stock builds equally, not just OUTPUT_1024X768.)
set_false_path -to [get_cells lisa_hdmi_output/TONE_int_reg]
set_false_path -to [get_cells {lisa_hdmi_output/VC_int_reg[*]}]

## We need yet another false path on the I/O board for a really crazy path that never actually happens in real life but Vivado flags
## The path is FDC MA bus -> BD_out -> IO_D -> the SCC write registers
## Obviously that never happens; we never communicate directly from the FDC to the SCC without the CPU in the middle, so it's a false path
## Vivado generated this _xlnx_shared_i0 line for me (I previously had it inline with each of my false path constraints)
## No idea why it did this, but it makes things simpler, so I'm not complaining
set _xlnx_shared_i0 [get_cells -hierarchical -filter {NAME =~ io_board/absolutely_amazing_scc_implementation/*}]
set_false_path -from [get_cells {io_board/MA_reg[*]}] -to $_xlnx_shared_i0
## Same deal for a path from the FDC counter to the SCC
set_false_path -from [get_cells {io_board/FDC_counter_reg[*]}] -to $_xlnx_shared_i0
## And from FDC_RAM_addr_select to the SCC
set_false_path -from [get_cells io_board/FDC_RAM_addr_select_reg] -to $_xlnx_shared_i0
## And _FDC_RAM_CS_processed to the SCC
set_false_path -from [get_cells io_board/_FDC_RAM_CS_processed_reg] -to $_xlnx_shared_i0

## There are similar false paths we need to do from the FDC to the two VIAs, once again for the same reason
set _xlnx_shared_i1 [get_cells -hierarchical -filter {NAME =~ io_board/kbd_via/*}]
set _xlnx_shared_i2 [get_cells -hierarchical -filter {NAME =~ io_board/pp_via/*}]
set_false_path -from [get_cells {io_board/MA_reg[*]}] -to $_xlnx_shared_i1
set_false_path -from [get_cells {io_board/MA_reg[*]}] -to $_xlnx_shared_i2
set_false_path -from [get_cells {io_board/FDC_counter_reg[*]}] -to $_xlnx_shared_i1
set_false_path -from [get_cells {io_board/FDC_counter_reg[*]}] -to $_xlnx_shared_i2
set_false_path -from [get_cells io_board/FDC_RAM_addr_select_reg] -to $_xlnx_shared_i1
set_false_path -from [get_cells io_board/FDC_RAM_addr_select_reg] -to $_xlnx_shared_i2
set_false_path -from [get_cells io_board/_FDC_RAM_CS_processed_reg] -to $_xlnx_shared_i1
set_false_path -from [get_cells io_board/_FDC_RAM_CS_processed_reg] -to $_xlnx_shared_i2

## We also have to false-path a few other signals going into and out of the VIAs, but we have synchronizers for them so it's fine
## First up, the DISK_DIAG signal from the FDC to the parallel port VIA
set_false_path -to [get_cells io_board/DISK_DIAG_int_reg]
## And the FDIR signal from the FDC to the keyboard VIA
set_false_path -to [get_cells io_board/FDIR_int_reg]
## Then the READY signal from the COP to the keyboard VIA
set_false_path -to [get_cells io_board/_READY_COP_int_reg]
## The DATA_QUEUED signal from the COP to the keyboard VIA
set_false_path -to [get_cells io_board/DATA_QUEUED_COP_int_reg]
## And the READ_ACK signal from the keyboard VIA to the COP
set_false_path -to [get_cells io_board/READ_ACK_COP_int_reg]
## Also false-path the COP data bus (both directions); we can't put a synchronizer on it because of inter-bit skew, but syncing the handshake signals is enough
set_false_path -to [get_cells {io_board/kbd_via/port_a_c_reg[*]}]
set_false_path -to [get_cells {io_board/L_COP_out_reg[*]}]
## False-path from the keyboard VIA's DDRA register to the DDRA extension logic that runs in C16M; we have a synchronizer for this too
set_false_path -to [get_cells io_board/KBD_via_DDRA_int_reg]
## And finally, a false path from the keyboard VIA to the USB keyboard interface's keyboard input; there's a synchronizer in the USB keyboard module
set_false_path -to [get_cells usb_kbd_interface/KBD_in_int_reg]

## There's an annoying DRC rule during implementation that gives us an error if we try to drive 3 or more MMCMs from one IBUF
## You can do it, but the MMCMs have to placed in certain places relative to the IBUF, which doesn't work out for us
## So to get around this, we tell Vivado to ignore the rule for our sysclk
## This would be bad for a clock that was actively clocking a ton of logic, but since we're only using this clock to feed MMCMs, it's fine
## The MMCMs will get rid of any skew that would be generated by this violation anyway
## sysclk_ibuf drives FOUR MMCMs now (clock_divider, dotck_mmcm, hdmi_clock_divider and
## hdmi_clock_divider_1024x768), which trips the DRC rule about one IBUF feeding 3+ MMCMs placed in
## different CMT columns. This used to be demoted with BACKBONE, but BACKBONE *asserts* that backbone
## routing is used -- and once the fourth MMCM changed the placement, the router stopped using it and
## DRC RTRES-1 failed at bitstream time ("set to BACKBONE but do not use backbone resources").
## ANY_CMT_COLUMN relaxes the same placement rule without claiming a particular routing resource, so it
## cannot become self-contradictory the way BACKBONE did. Fine here because this net only feeds MMCMs,
## which clean up any skew themselves.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets sysclk_ibuf]
## Yet another annoying rule exists for the BUFGMUX/BUFGCTRL primitives used for clock muxing
## If you daisy-chain muxes, they have to be placed adjacent to each other in the same CMT column, but we have 3 of them and it's impossible
## So we again tell Vivado to ignore the rule for our dot clock nets; it's fine once again since nobody cares if the intermediate clocks have skew
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets dotck_A]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets dotck_B]
## The four dotck_mmcm outputs feed the first-stage muxes through their own BUFGs, so those are
## BUFG->BUFG cascades too and need the same treatment as dotck_A/dotck_B above. This only started
## failing placement once the HDMI clock mux became a three-way cascade: BUFGCTRL usage is still only
## 17 of 32, so it is not resource exhaustion -- there are simply now more cascades competing for
## adjacent BUFGCTRL sites than the placer can satisfy at once, and it had previously been getting
## these placed legally by luck rather than by constraint.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -quiet dotck_generator/inst/dotck_20M]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -quiet dotck_generator/inst/dotck_40M]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -quiet dotck_generator/inst/dotck_60M]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -quiet dotck_generator/inst/dotck_80M]

## Based on the pins we used for our HDMI output, the OSERDES primitives for TMDS encoding are in a particular part of the FPGA
## And to avoid violating some design rules, we have to put the MMCM that feeds the OSERDES in that same part (X0Y2)
## But by default, Vivado tries to put the primary clock divider MMCM there instead, so force it into X0Y0 and put our HDMI MMCM in X0Y2
set_property LOC MMCME2_ADV_X0Y2 [get_cells lisa_hdmi_output/hdmi_clock_generator/inst/mmcm_adv_inst]
set_property LOC MMCME2_ADV_X0Y0 [get_cells primary_clock_divider/inst/mmcm_adv_inst]
## We don't explicitly place the 1024x768 MMCM (hdmi_clock_generator_1024x768) anywhere -- it also feeds the same
## OSERDES via the BUFGMUXes below, but only at 65/325MHz (vs. 148.5/742.5MHz for the stock clocks), so there's much
## more timing margin to work with even if the placer doesn't put it as close to the OSERDES as X0Y2. If Timing Summary
## ever shows trouble specifically on the clk_pixel_1024x768/clk_pixel_x5_1024x768 domains, an explicit LOC in whichever
## CMT column is free may be needed here too.

## Place the RAM board in the clock region directly adjacent to the SRAM I/O pins (X1Y1) to ensure that the SRAM interface is as fast as possible
## Certain unluckily-slow SRAM chips can be borderline too slow to work properly at a 75MHz DOTCK if we don't do this
## First, create a pblock to contain all of the logic for the RAM board
create_pblock MEM_PBLOCK
## And then add all of the RAM board (slot1) logic to it
add_cells_to_pblock [get_pblocks MEM_PBLOCK] [get_cells {slot1}]
## Then finally, stick it in the X1Y1 clock region
resize_pblock [get_pblocks MEM_PBLOCK] -add {CLOCKREGION_X1Y1:CLOCKREGION_X1Y1}

## Another thing for the SRAM interface: we need to set max delays for the SRAM signals to ensure that the SRAM has enough time to respond
## These max delays tell the Vivado how long of a path it's allowed to take when routing the SRAM signals internally
## And a timing violation is generated if it fails to route them as fast as our delay allows
## This way, we can set the max internal delay well below the 75MHz DOTCK period of 13-ish ns, and that ensures that there's still plenty of time for the signals to propagate outside the FPGA
## The datapath_only option means that we don't care about setup/hold timing here in relation to any clocks, just the raw routing delay
## Which is exactly what we want given that the SRAM is asynchronous
set_max_delay -datapath_only 6.0 -to [get_ports _CE_SRAM _OE_SRAM _WE_SRAM _UDS_SRAM _LDS_SRAM {A_SRAM[*]} {D_SRAM[*]}]

## We also need to declare some false paths related to our clock muxing
## This is because only one of the clocks is actually active at a time, so timing analysis between the 4 dot clocks is pointless
## Instead of a billion false path constraints, we can instead just make an exclusive clock group for the 4 DOTCKs
## This is just a single line, and tells Vivado that these clocks are all mutually exclusive and should be analyzed as such
set_clock_groups -name exclusive_dotcks -logically_exclusive -group dotck_20M_dotck_mmcm -group dotck_40M_dotck_mmcm -group dotck_60M_dotck_mmcm -group dotck_80M_dotck_mmcm
## *** IMPORTANT XDC LIMITATION ***: this Vivado rejects BOTH 'proc' AND 'if' inside an .xdc file
## ("[Designutils 20-1307] Command 'if' is not supported in the xdc constraint file") -- and it does so as a
## CRITICAL WARNING that does NOT fail the run, so anything inside such a block silently never applies. Do not
## use control flow here; write plain unconditional constraints only. (A .tcl file added to the constraints
## fileset instead of an .xdc would allow full Tcl, if conditional constraints are ever really needed.)
## THREE-WAY mode selection: 1080p30, 1080p60 and 1024x768 are all live and runtime-selectable, muxed by a
## CASCADED pair of BUFGMUXes (stage A picks the 1080p rate, stage B swaps in 1024x768). Only one can ever be
## driving clk_pixel, so they are mutually exclusive -- without this Vivado times the impossible crossings
## between them and reports thousands of bogus failing endpoints.
##
## *** Clock names here are NOT predictable from the source and have caught us out three times. *** Vivado names
## a derived clock after whatever net it lands on, which has variously been the bare port, "<port>_<ip_instance>"
## (clk_pixel_1024x768_hdmi_clock_divider_1024x768), and the intermediate wire (clk_pixel_second_position).
## The cascade adds another: the stage-A output clk_pixel_a. So list every candidate and let get_clocks match
## whatever exists. ALWAYS confirm against the Clock Summary in top_timing_summary_routed.rpt after a build --
## a group that matches nothing fails silently and only shows up as impossible cross-clock paths.
set_clock_groups -name exclusive_pixel_clks -logically_exclusive \
    -group [get_clocks -quiet {clk_pixel_1080p30}] \
    -group [get_clocks -quiet {clk_pixel_1080p60}] \
    -group [get_clocks -quiet {clk_pixel_1024x768* clk_pixel_second_position}]
set_clock_groups -name exclusive_5x_pixel_clks -logically_exclusive \
    -group [get_clocks -quiet {clk_pixel_x5_1080p30}] \
    -group [get_clocks -quiet {clk_pixel_x5_1080p60}] \
    -group [get_clocks -quiet {clk_pixel_x5_1024x768* clk_pixel_x5_second_position}]

## The cascaded BUFGMUXes can't satisfy rule_cascaded_bufg (stage A and stage B won't be adjacent in the same
## CMT column), exactly as the three daisy-chained DOTCK muxes already can't. Same workaround, same reasoning:
## nobody cares if the intermediate clock carries some skew.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -quiet lisa_hdmi_output/clk_pixel_a]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -quiet lisa_hdmi_output/clk_pixel_x5_a]

## The new first-stage muxes need the same CE false paths as the existing ones -- their select comes from a
## register in the "user pressing buttons" world with no meaningful timing relationship.
set_false_path -to [get_pins -quiet lisa_hdmi_output/bufgmux_clk_pixel_a/CE*]
set_false_path -to [get_pins -quiet lisa_hdmi_output/bufgmux_clk_pixel_x5_a/CE*]

## The 1024x768 MMCM's two output BUFGs feed the pixel-clock BUFGMUXes below, forming a BUFG->BUFG cascade.
## Vivado's rule_cascaded_bufg wants those adjacent and cyclic, but (unlike hdmi_clock_divider, which is LOC'd
## to MMCME2_ADV_X0Y2 near the OSERDES) this MMCM floats, so the placer put its BUFGs down at BUFGCTRL_X0Y8/Y9
## while the muxes landed at X0Y20/Y21 -- not adjacent, so placement failed. Same situation and same workaround
## as the dotck_A/dotck_B daisy-chained mux nets above; nobody cares if these intermediate clocks have skew.
## NOTE: these nets are INSIDE the IP instance ("<ip_instance>/inst/<port_name>"), not at the HDMI_Interface
## level -- naming them at the wrong level makes get_nets match nothing and the constraint silently do nothing.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets lisa_hdmi_output/hdmi_clock_generator_1024x768/inst/clk_pixel_1024x768]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets lisa_hdmi_output/hdmi_clock_generator_1024x768/inst/clk_pixel_x5_1024x768]

## Another HDMI-related thing: we need to set false paths for the select signals going into the HDMI clock muxes
## They're generated in the "user flipping switches" domain and we can't synchronize them to any of the pixel clock domains since they feed into the clock muxes themselves
## So just declare false paths and call it there
## (The BUFGMUXes and framerate synchronizers are always instantiated regardless of OUTPUT_1024X768 -- only the
## second BUFGMUX input, and what video_id_code/frame timing that maps to, changes -- see HDMI_Interface.sv)
set_false_path -to [get_pins lisa_hdmi_output/bufgmux_clk_pixel/CE*]
set_false_path -to [get_pins lisa_hdmi_output/bufgmux_clk_pixel_x5/CE*]

## The three DOTCK clock muxes need exactly the same treatment, for exactly the same reason: SPEED_SEL is a
## physical switch in the "user flipping things" domain feeding a clock mux select, so there's no sensible
## timing relationship to analyze. Without these, SPEED_SEL_dotck_reg -> dotck_final_mux/CE0 shows up as a
## small hold violation (around -0.02 to -0.25ns depending on placement) and the design misses timing.
## This is pre-existing and applies to stock builds too, not just the 1024x768 work.
set_false_path -to [get_pins dotck_mux_20M40M/CE*]
set_false_path -to [get_pins dotck_mux_60M80M/CE*]
set_false_path -to [get_pins dotck_final_mux/CE*]

## We do use the framerate select signals in some other places though, so they're fed through synchronizers in those cases
## We need false paths for those too
set_false_path -to [get_cells lisa_hdmi_output/framerate_sel_int_pixel_reg]
set_false_path -to [get_cells lisa_hdmi_output/framerate_sel_int_pixel_x5_reg]

## Create a constraint for our 48KHz audio clock
## This is important because we generate it in the logic world, and then move it to a clock net with a BUFG
## With all three modes runtime-selectable, the audio counter always runs off the muxed clk_pixel (74.25MHz,
## 148.5MHz or 65MHz depending on video_mode) and picks its threshold to match -- see HDMI_Interface.sv. So
## there is no longer a build-time variant to swap by hand: constrain it from the final BUFGMUX output.
##
## divide_by has to be a single number for a clock whose real divide changes with mode (1546 / 3094 / 1354).
## 1546 is the 1080p30 value; in the other two modes this is off by up to 2x. That only costs STA precision on
## a ~48KHz domain feeding a couple of audio synchronizer flops, all of which are false-pathed anyway, so it
## has no bearing on functional correctness -- but do not read the reported clk_audio frequency as truth.
create_generated_clock -name clk_audio -source [get_pins lisa_hdmi_output/bufgmux_clk_pixel/O] -divide_by 1546 [get_pins lisa_hdmi_output/buf_audio/O]

## clk_audio is ~48KHz and the pixel clocks are 65-148.5MHz, so every path between them is a slow-to-fast
## handoff that is stable for thousands of pixel clocks -- there is no phase relationship worth analysing.
## Declare them asynchronous, mirroring how the TONE/VC crossings *into* clk_audio are already false-pathed.
## Without this, re-sourcing clk_audio from the BUFGMUX output (needed once all three modes became runtime
## selectable) makes it "related" to every pixel clock, and the 1080p60 relationship -- half the period of
## 1080p30 -- fails on all 258 audio_sample_word endpoints at about -1.3ns.
## NOTE this must come AFTER the create_generated_clock above, or clk_audio won't exist yet to be grouped.
set_clock_groups -name async_clk_audio -asynchronous \
    -group [get_clocks -quiet {clk_audio}] \
    -group [get_clocks -quiet {clk_pixel_1080p30 clk_pixel_1080p60 clk_pixel_1024x768* clk_pixel_second_position}]

## ---------------------------------------------------------------------------------------------
## USB full-speed spike (USB_FULL_SPEED in top.sv). Only binds in a full-speed build; in a stock
## low-speed build usbclk_fs does not exist, -quiet matches nothing and this applies nothing.
##
## The USB clock is genuinely asynchronous to the Lisa clocks: it is a separate protocol domain,
## and every signal crossing between them already goes through a synchronizer (see the two
## set_false_path entries near the top of this file, and the synchronizers inside
## usb_keyboard_interface.sv / usb_mouse_interface.sv). Vivado nonetheless treats them as related
## because both derive from sysclk, which at 12MHz cost nothing -- an 83ns period made every
## crossing trivially passable. At ~96MHz that slack is gone and the false relationships would
## start failing, exactly as clk_audio did once it was re-sourced from the pixel BUFGMUX.
##
## NOTE the name is wildcarded on purpose. Vivado renames IP-derived clocks to
## <output_port>_<ip_instance>, and this one is inside a generate block, so the exact name is not
## worth guessing. VERIFY IT with `get_clocks` on the first full-speed build rather than assuming
## this matched -- a group that silently binds nothing looks identical to one that worked.
set_clock_groups -name async_usbclk_fs -asynchronous \
    -group [get_clocks -quiet {usbclk_fs*}] \
    -group [get_clocks -quiet {sys_clk_pin dotck_* clk_pixel_* C16M* COPCK* SCCCK* C5M*}]

## DELIBERATELY NO PULLTYPE ON THE USB PINS. The board provides the 15k pulldowns the USB spec
## requires for host-side termination (R97-R100 on rev 3), and the device's own pull-up on D+ (full
## speed) or D- (low speed) is what declares its speed. An FPGA pull-up on either line would look
## like a device attaching and break speed detection outright. This is called out because the
## settings-flash debugging ended with "always pull up a floating input" -- that lesson does NOT
## transfer here; these pins are terminated externally and must stay that way.

## Make some more false paths going into the Lite Adapter synchronizers for the PH0 and MT signals
set_false_path -to [get_cells lisa_lite/PH0_int_reg]
set_false_path -to [get_cells lisa_lite/MT_int_reg]

## And a create_clock constraint for our main 125MHz sysclk signal
create_clock -period 8.000 -name sys_clk_pin -waveform {0.000 4.000} -add [get_ports sysclk]

## Now define all of our I/O pin constraints, starting with the sysclk input
set_property -dict {PACKAGE_PIN B8 IOSTANDARD LVCMOS33} [get_ports sysclk]

## Audio and Video Stuff
set_property -dict {PACKAGE_PIN A8 IOSTANDARD LVCMOS33} [get_ports _VSYNC]
set_property -dict {PACKAGE_PIN B9 IOSTANDARD LVCMOS33} [get_ports _HSYNC]
set_property -dict {PACKAGE_PIN C9 IOSTANDARD LVCMOS33} [get_ports VID]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports {CONT[0]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {CONT[1]}]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33} [get_ports {CONT[2]}]
set_property -dict {PACKAGE_PIN C1 IOSTANDARD LVCMOS33} [get_ports {CONT[3]}]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports {CONT[4]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {CONT[5]}]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS33} [get_ports INVID]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports SCANLINES]
set_property -dict {PACKAGE_PIN M16 IOSTANDARD LVCMOS33} [get_ports FRAMERATE_SEL]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports TONE]
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {VC[0]}]
set_property -dict {PACKAGE_PIN D2 IOSTANDARD LVCMOS33} [get_ports {VC[1]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {VC[2]}]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD TMDS_33} [get_ports HDMI_CLK_N]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD TMDS_33} [get_ports HDMI_CLK_P]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD TMDS_33} [get_ports {HDMI_D_N[0]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD TMDS_33} [get_ports {HDMI_D_P[0]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD TMDS_33} [get_ports {HDMI_D_N[1]}]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD TMDS_33} [get_ports {HDMI_D_P[1]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD TMDS_33} [get_ports {HDMI_D_N[2]}]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD TMDS_33} [get_ports {HDMI_D_P[2]}]
#set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports HDMI_HPD]
#set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports HDMI_SCL]
#set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports HDMI_SDA]


## ---------------------------------------------------------------------------------------------------
## Configuration SPI flash reused for saved settings (see settings_flash.sv)
## ---------------------------------------------------------------------------------------------------
## These are the FPGA's own configuration pins in bank 14, driven as ordinary user I/O after
## configuration completes. Pin functions confirmed from the device itself via
##   get_package_pins -filter {PIN_FUNC =~ "*FCS_B*" || PIN_FUNC =~ "*D00*" || PIN_FUNC =~ "*D01*"}
## rather than assumed:  L13 = FCS_B,  K17 = D00_MOSI,  K18 = D01_DIN.
## CCLK is deliberately absent -- it is not a user-accessible pin, and is driven through the
## STARTUPE2 primitive's USRCCLKO port inside settings_flash instead.
## D02 (L14) and D03 (M14) are left unconstrained: the QE bit is set at the factory on this part
## (W25Q128JV*SIQ*), so the flash's WP#/HOLD# functions are disabled and those pins only carry data
## during quad transfers, which this design never issues.
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports FLASH_D02]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports FLASH_D03]
set_property -dict {PACKAGE_PIN L13 IOSTANDARD LVCMOS33} [get_ports FLASH_CS_N]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports FLASH_MOSI]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports FLASH_MISO]
# MISO must have a pull-up. The flash's DO pin is high-Z whenever it is not actively driving --
# between commands, and during the command/address phases of a read -- and this board has no
# external pull-up on the net. Without PULLUP the FPGA input floats and simply retains its last
# value, so a captured 0 or 1 on this pin means NOTHING about what the flash did.
# That confounded a whole ILA debugging session (2026-08-13): the settings block read back 0x00
# and the status poll read back 0xFF, and BOTH were just the decaying residue of the previous
# driven bit -- the block read follows the JEDEC ID byte 0x18, which ends on a 0, and the poll
# follows a long idle during which the line drifted high. Two different "findings" were built on
# those readings and both were wrong.
# With the pull-up, undriven reads as 0xFF and anything else is real data from the flash.
set_property PULLTYPE PULLUP [get_ports FLASH_MISO]

## Required once bank-14 config pins are used as user I/O, and good practice regardless: tells Vivado
## the config bank runs at 3.3V from VCCO. Without these, DRC CFGBVS-1 fires.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## The settings load happens once at power-up and its result crosses into the pixel domain through a
## two-stage synchroniser, so false-path the first stage like every other CDC in this file.
set_false_path -to [get_cells lisa_hdmi_output/settings_loaded_int_reg]

## settings_data / settings_valid cross from the settings_flash sysclk domain into the pixel clock
## domain. There is no synchroniser on the bus itself and it does not need one: it is written once
## during the power-up read and never changes again, and the consumer is gated behind a two-stage
## synchroniser on settings_loaded, so it is only ever sampled long after it went stable.
## Without this Vivado times all ~50 bits as ordinary single-cycle sysclk -> clk_pixel paths, which
## fails by about -4.6ns and drags the whole design's WNS down with it.
## set_max_delay -datapath_only rather than a plain false path: it still bounds how far apart the bits
## can arrive (so the bus can't skew arbitrarily) while dropping the meaningless phase requirement,
## and it disables the hold check on these paths too.
## Everything leaving settings_flash (sysclk domain) for the pixel domain is stable-when-read: the loaded
## block and JEDEC ID are written once and held, and the diagnostic word is only ever displayed. Constrain
## the crossing at the clock level rather than naming individual registers -- naming them meant every new
## signal (settings_data, then jedec_id, then dbg_word) silently went unconstrained and tanked WNS until
## someone noticed. sysclk only clocks settings_flash here; everything else runs off derived clocks.
set_max_delay -datapath_only 20.000 -from [get_clocks sys_clk_pin] \
    -to [get_clocks -quiet {clk_pixel_1080p30 clk_pixel_1080p60 clk_pixel_1024x768*}]
set_max_delay -datapath_only 20.000 -from [get_clocks -quiet {clk_pixel_1080p30 clk_pixel_1080p60 clk_pixel_1024x768*}] \
    -to [get_clocks sys_clk_pin]

## Parallel SRAM Interface
## Ensure all of the SRAM pins have a fast slew rate instead of the default of slow and set them all to the max drive strength of 12mA
## We have to do this because our 55ns SRAM is borderline too slow to work at a 75MHz DOTCK, so we need the fastest I/O we can possibly get
set_property -dict {PACKAGE_PIN K6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports _CE_SRAM]
set_property -dict {PACKAGE_PIN L1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports _OE_SRAM]
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports _WE_SRAM]
set_property -dict {PACKAGE_PIN K3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports _UDS_SRAM]
set_property -dict {PACKAGE_PIN L3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports _LDS_SRAM]
set_property -dict {PACKAGE_PIN N2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[1]}]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[2]}]
set_property -dict {PACKAGE_PIN M3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[3]}]
set_property -dict {PACKAGE_PIN M2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[4]}]
set_property -dict {PACKAGE_PIN K5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[5]}]
set_property -dict {PACKAGE_PIN L4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[6]}]
set_property -dict {PACKAGE_PIN L6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[7]}]
set_property -dict {PACKAGE_PIN L5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[8]}]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[9]}]
set_property -dict {PACKAGE_PIN V1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[10]}]
set_property -dict {PACKAGE_PIN U4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[11]}]
set_property -dict {PACKAGE_PIN U3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[12]}]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[13]}]
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[14]}]
set_property -dict {PACKAGE_PIN V5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[15]}]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[16]}]
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[17]}]
set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[18]}]
set_property -dict {PACKAGE_PIN T5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[19]}]
set_property -dict {PACKAGE_PIN T4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {A_SRAM[20]}]
set_property -dict {PACKAGE_PIN N5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[0]}]
set_property -dict {PACKAGE_PIN P5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[1]}]
set_property -dict {PACKAGE_PIN P4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[2]}]
set_property -dict {PACKAGE_PIN P3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[3]}]
set_property -dict {PACKAGE_PIN P2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[4]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[5]}]
set_property -dict {PACKAGE_PIN M4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[6]}]
set_property -dict {PACKAGE_PIN N4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[7]}]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[8]}]
set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[9]}]
set_property -dict {PACKAGE_PIN M6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[10]}]
set_property -dict {PACKAGE_PIN N6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[11]}]
set_property -dict {PACKAGE_PIN R6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[12]}]
set_property -dict {PACKAGE_PIN R5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[13]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[14]}]
set_property -dict {PACKAGE_PIN V6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {D_SRAM[15]}]
set_property -dict {PACKAGE_PIN T8 IOSTANDARD LVCMOS33} [get_ports {RAM_SEL[0]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33} [get_ports {RAM_SEL[1]}]

## Floppy Disk Interface
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports {ESFLOPPY_COMM_BUS[0]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {ESFLOPPY_COMM_BUS[1]}]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports {ESFLOPPY_COMM_BUS[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {ESFLOPPY_COMM_BUS[3]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {ESFLOPPY_COMM_BUS[4]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {ESFLOPPY_COMM_BUS[5]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports RDA_ESFLOPPY]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports WRD_ESFLOPPY]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports SNS_ESFLOPPY]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports _WRQ_ESFLOPPY]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports HDS_ESFLOPPY]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {PH_ESFLOPPY[0]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {PH_ESFLOPPY[1]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {PH_ESFLOPPY[2]}]
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVCMOS33} [get_ports {PH_ESFLOPPY[3]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports MT1_ESFLOPPY]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports MT0_ESFLOPPY]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports _DR1_ESFLOPPY]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports _DR0_ESFLOPPY]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports PWM_ESFLOPPY]
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports LEFT_ESFLOPPY]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports OK_ESFLOPPY]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports RIGHT_ESFLOPPY]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports RDA_EXTFLOPPY]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports WRD_EXTFLOPPY]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports SNS_EXTFLOPPY]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports _WRQ_EXTFLOPPY]
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports HDS_EXTFLOPPY]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {PH_EXTFLOPPY[0]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {PH_EXTFLOPPY[1]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {PH_EXTFLOPPY[2]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {PH_EXTFLOPPY[3]}]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports MT1_EXTFLOPPY]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports MT0_EXTFLOPPY]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports _DR1_EXTFLOPPY]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports _DR0_EXTFLOPPY]
set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports PWM_EXTFLOPPY]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports FLOPPY_SRC]

## ProFile Interface
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33} [get_ports {ESPROFILE_COMM_BUS[0]}]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {ESPROFILE_COMM_BUS[1]}]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {ESPROFILE_COMM_BUS[2]}]
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33} [get_ports _CMD_ESPROFILE]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports _BSY_ESPROFILE]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports R_W_ESPROFILE]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports _STRB_ESPROFILE]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports _PRES_ESPROFILE]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports _PARITY_ESPROFILE]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports OCD_ESPROFILE]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[0]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[1]}]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[2]}]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[3]}]
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[4]}]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[5]}]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[6]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {PD_ESPROFILE[7]}]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports _CMD_EXTPROFILE]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports _BSY_EXTPROFILE]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports R_W_EXTPROFILE]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports _STRB_EXTPROFILE]
set_property -dict {PACKAGE_PIN U11 IOSTANDARD LVCMOS33} [get_ports _PRES_EXTPROFILE]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports _PARITY_EXTPROFILE]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports OCD_EXTPROFILE]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[0]}]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[1]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[2]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[3]}]
set_property -dict {PACKAGE_PIN T13 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[4]}]
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[5]}]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[6]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {PD_EXTPROFILE[7]}]
set_property -dict {PACKAGE_PIN R10 IOSTANDARD LVCMOS33} [get_ports HDD_SRC]

## Keyboard Interface
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports KBD_DN]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports KBD_DP]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports KBD]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports KBD_SEL]

## Mouse Interface
set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS33} [get_ports MOUSE_DN]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports MOUSE_DP]
set_property -dict {PACKAGE_PIN U9 IOSTANDARD LVCMOS33} [get_ports {M_LISA[0]}]
set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports {M_LISA[1]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {M_LISA[2]}]
set_property -dict {PACKAGE_PIN U6 IOSTANDARD LVCMOS33} [get_ports {M_LISA[3]}]
set_property -dict {PACKAGE_PIN R7 IOSTANDARD LVCMOS33} [get_ports {M_LISA[4]}]
set_property -dict {PACKAGE_PIN T6 IOSTANDARD LVCMOS33} [get_ports {M_LISA[5]}]
set_property -dict {PACKAGE_PIN R8 IOSTANDARD LVCMOS33} [get_ports {M_LISA[6]}]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports MOUSE_SEL]

## GPIO Pins
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports {GPIO[0]}]
set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports {GPIO[1]}]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports {GPIO[2]}]
set_property -dict {PACKAGE_PIN D3 IOSTANDARD LVCMOS33} [get_ports {GPIO[3]}]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {GPIO[4]}]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports {GPIO[5]}]

## Comms With External SCC
set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVCMOS33} [get_ports SCC_C4M]
set_property -dict {PACKAGE_PIN B3 IOSTANDARD LVCMOS33} [get_ports SCC_WR]
set_property -dict {PACKAGE_PIN A1 IOSTANDARD LVCMOS33} [get_ports SCC_RD]
set_property -dict {PACKAGE_PIN B6 IOSTANDARD LVCMOS33} [get_ports _SCC_RSIR]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports SCC_A2]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports SCC_A1]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports _SCC_CS]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports _SCC_PSI]
set_property -dict {PACKAGE_PIN D7 IOSTANDARD LVCMOS33} [get_ports {SCC_D[0]}]
set_property -dict {PACKAGE_PIN E7 IOSTANDARD LVCMOS33} [get_ports {SCC_D[1]}]
set_property -dict {PACKAGE_PIN E5 IOSTANDARD LVCMOS33} [get_ports {SCC_D[2]}]
set_property -dict {PACKAGE_PIN E6 IOSTANDARD LVCMOS33} [get_ports {SCC_D[3]}]
set_property -dict {PACKAGE_PIN C7 IOSTANDARD LVCMOS33} [get_ports {SCC_D[4]}]
set_property -dict {PACKAGE_PIN D8 IOSTANDARD LVCMOS33} [get_ports {SCC_D[5]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {SCC_D[6]}]
set_property -dict {PACKAGE_PIN A6 IOSTANDARD LVCMOS33} [get_ports {SCC_D[7]}]

## I/O From Internal SCC (Not Implemented In HDL Yet)
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports SYNCA]
set_property -dict {PACKAGE_PIN H5 IOSTANDARD LVCMOS33} [get_ports TXDA]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports RTSA]
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33} [get_ports DTRA]
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33} [get_ports RXDA]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports CTSA]
set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33} [get_ports DCDA]
set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports TRXCA]
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports RTXCA]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33} [get_ports TXDB]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS33} [get_ports DTRB]
set_property -dict {PACKAGE_PIN F6 IOSTANDARD LVCMOS33} [get_ports RTSB]
set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports RXDB]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports CTSB_TRXCB]
set_property -dict {PACKAGE_PIN B1 IOSTANDARD LVCMOS33} [get_ports INTERNAL_SCC_EN]

## Everything Else
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports _PWRSW]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports ON]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports _RSTSW]
set_property -dict {PACKAGE_PIN R12 IOSTANDARD LVCMOS33} [get_ports _RESET]
set_property -dict {PACKAGE_PIN R13 IOSTANDARD LVCMOS33} [get_ports _NMISW]
set_property -dict {PACKAGE_PIN B7 IOSTANDARD LVCMOS33} [get_ports {SPEED_SEL[0]}]
set_property -dict {PACKAGE_PIN C5 IOSTANDARD LVCMOS33} [get_ports {SPEED_SEL[1]}]
set_property -dict {PACKAGE_PIN C6 IOSTANDARD LVCMOS33} [get_ports CPU_ROM_SEL]
set_property -dict {PACKAGE_PIN F5 IOSTANDARD LVCMOS33} [get_ports IO_ROM_SEL]


