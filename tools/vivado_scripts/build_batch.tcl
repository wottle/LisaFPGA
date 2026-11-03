# Full production build in batch Vivado: synthesis, implementation, bitstream, then top.mcs for the config flash.
# Written with an AI assistant. Run from the repo root (synthesis ~85 min of which up to an hour is silent, impl ~50 min):
#   C:/AMDDesignTools/2026.1/Vivado/bin/vivado.bat -mode batch -source tools/vivado_scripts/build_batch.tcl -log <log>
# Afterwards read LisaFPGA.runs/impl_1/build_timing.rpt (git-ignored, as *.rpt there): WNS/WHS >= 0, 0 failing setup/hold endpoints, and only the
# known 1080p60 pulse-width entries (see CLAUDE.md, "Vivado/XDC gotchas").
set root [file normalize [file join [file dirname [info script]] ../..]]
open_project $root/LisaFPGA.xpr
puts "synth flatten: [get_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY [get_runs synth_1]]"
puts "synth directive: [get_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE [get_runs synth_1]]"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
puts "SYNTH: [get_property STATUS [get_runs synth_1]]"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL: [get_property STATUS [get_runs impl_1]]"
set d $root/LisaFPGA.runs/impl_1
# The run does not make the .mcs (and reset_run deletes the old one): W25Q128JV, 16 MB, quad SPI
write_cfgmem -force -format mcs -interface spix4 -size 16 -loadbit "up 0x0 $d/top.bit" -file $d/top.mcs
open_run impl_1
report_timing_summary -no_detailed_paths -file $d/build_timing.rpt
report_utilization -file $d/build_util.rpt
puts "DONE"
