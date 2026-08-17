# ============================================================================================
# capture_settings_ila.tcl -- drive the settings_flash ILA from Vivado's Hardware Manager.
#
# Usage, after opening the Hardware Manager and programming the DEBUG_FLASH_ILA bitstream:
#     source tools/vivado_scripts/capture_settings_ila.tcl
#     ila_probes            ;# list the probes actually present, with their real names
#     ila_arm_program       ;# capture 1: the page-program command and the polls that follow
#     ila_arm_wren          ;# capture 2: the very first WREN, at full 125MHz rate
#     ila_arm_poll          ;# capture 3: only the status-poll bytes
#     ila_go                ;# arm, wait for trigger, upload, open the waveform
#
# WHY THREE: the whole save spans a ~45ms sector erase = 5.6M clocks at 125MHz, far beyond any
# capture depth. So we trigger on a specific phase instead of trying to catch the lot, and use
# capture control (storage qualification) to store one sample per SPI byte where that helps.
# All of this is runtime-settable -- switching between these needs no rebuild.
#
# PROBE PACKING. The BASIC ChipScope license allows only 5 probes per ILA, so signals are
# concatenated (see settings_flash.sv). Reading the waveform:
#   dbg_state[4:0]   sequencer state -- decode table is in CLAUDE.md
#   rx_byte[7:0]     last byte clocked in from the flash
#   dbg_bus[3:0]     bit3 flash_cs_n, bit2 sck_r, bit1 flash_mosi, bit0 flash_miso
#   dbg_flags[5:0]   bit5 do_save, bit4 busy, bit3 eos, bit2 xfer_start,
#                    bit1 xfer_active, bit0 xfer_done
#   dbg_misc[22:0]   [22:15] tx_byte, [14:10] byte_idx, [9:4] cs_dly, [3:0] bit_cnt
# ============================================================================================

proc _ila {} {
    set ilas [get_hw_ilas -quiet]
    if {[llength $ilas] == 0} {
        error "No ILA found. Is the DEBUG_FLASH_ILA bitstream programmed, and refresh_hw_device run?"
    }
    return [lindex $ilas 0]
}

# Probe names depend on how Vivado flattens the generate block, so never hardcode them -- find
# by substring. Same discipline as using get_clocks instead of assuming clock names.
proc _p {frag} {
    set hits [get_hw_probes -quiet -of_objects [_ila] -filter "NAME =~ *${frag}*"]
    if {[llength $hits] == 0} { error "No probe matching '*${frag}*'. Run ila_probes to see what exists." }
    if {[llength $hits] > 1}  { puts "WARNING: '$frag' matched [llength $hits] probes, using [lindex $hits 0]" }
    return [lindex $hits 0]
}

proc ila_probes {} {
    foreach p [get_hw_probes -of_objects [_ila]] {
        puts [format "  %-60s width %s" [get_property NAME $p] [get_property WIDTH $p]]
    }
}

# "don't care" compare string of the right width, e.g. width 6 -> eq6'bXXXXXX
proc _dc {p} {
    set w [get_property WIDTH $p]
    return "eq${w}'b[string repeat X $w]"
}

proc _reset_conditions {} {
    set ila [_ila]
    set_property CONTROL.DATA_DEPTH 4096 $ila
    set_property CONTROL.TRIGGER_CONDITION AND $ila
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
    # Clear every probe's trigger and capture compare so a stale setting from a previous arm
    # can't quietly AND itself into the new one.
    foreach p [get_hw_probes -of_objects $ila] {
        catch { set_property TRIGGER_COMPARE_VALUE [_dc $p] $p }
        catch { set_property CAPTURE_COMPARE_VALUE [_dc $p] $p }
    }
}

# xfer_done is bit 0 of dbg_flags, so the capture qualifier is a masked compare on that probe.
proc _capture_on_xfer_done {} {
    set ila [_ila]
    set_property CONTROL.CAPTURE_MODE BASIC $ila
    set_property CONTROL.CAPTURE_CONDITION AND $ila
    set_property CAPTURE_COMPARE_VALUE eq6'bXXXXX1 [_p dbg_flags]
}

# ============================================================================================
# CRITICAL RULE FOR EVERY QUALIFIED CAPTURE BELOW.
#
# When capture control (storage qualification) is on, the trigger only registers on a sample
# that PASSES the qualifier. So a trigger state must be one the sequencer sits in when
# xfer_done is high -- i.e. a state written as `S_x: if (xfer_done) ...`.
#
# States entered from S_DESEL for a single cycle (S_PP_WREN 0x12, S_ER_CMD 0x0D, S_POLL_CMD
# 0x1A, S_PP_A2 0x14 ...) have xfer_done LOW on the one cycle they are active, so a trigger on
# them can NEVER coincide with the qualifier and the core waits forever. This was learned the
# hard way: a trigger on S_PP_WREN sat at WAITING FOR TRIGGER indefinitely even though the
# on-screen readout proved the sequencer was reaching the page-program phase.
#
# Safe trigger states (they transition on xfer_done): S_PP_CMD 0x13, S_PP_DATA 0x18,
# S_POLL_RD 0x1B, S_POLL_END 0x1C, S_ER_END 0x11.
# ============================================================================================

# ---- capture 1: the page-program phase -----------------------------------------------------
# Trigger on S_PP_CMD (0x13) -- reached the instant the page-program's WREN byte finishes
# clocking out, so it marks the start of the program phase. Store only completed SPI bytes.
# This is THE capture: 64 samples of pre-trigger history cover the tail of the erase poll, and
# everything after is the PP command + address + 16 data bytes and every status byte the poll
# then reads back.
proc ila_arm_program {} {
    set ila [_ila]
    _reset_conditions
    set_property TRIGGER_COMPARE_VALUE eq5'h13 [_p dbg_state]
    _capture_on_xfer_done
    set_property CONTROL.TRIGGER_POSITION 64 $ila
    puts "Armed: trigger on state==S_PP_CMD (0x13), storing one sample per SPI byte."
}

# ---- capture 2: the first WREN, at full rate -----------------------------------------------
# Trigger on do_save (bit 5 of dbg_flags), store EVERY clock -- no qualifier, so the coincidence
# rule above does not apply here. 4096 samples at 125MHz = 32.7us, which at SCK=clk/8 covers
# roughly the first 250 SPI bits: CS assertion, clock edges, the WREN byte, MISO behaviour.
# This is the one that answers "is the electrical timing sane".
proc ila_arm_wren {} {
    set ila [_ila]
    _reset_conditions
    set_property TRIGGER_COMPARE_VALUE eq6'b1XXXXX [_p dbg_flags]
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
    set_property CONTROL.TRIGGER_POSITION 256 $ila
    puts "Armed: trigger on do_save, full-rate 32.7us window (no storage qualifier)."
}

# ---- capture 3: the status polls only ------------------------------------------------------
# Trigger on S_POLL_END (0x1C), which transitions on xfer_done so it satisfies the rule above.
# Trigger position mid-buffer captures polls both before and after. Use this to see whether the
# status byte is EVER anything but 0xFF, and what the erase poll returned before the program --
# it must have returned bit0=0 at least once, or the sequencer could never have advanced.
proc ila_arm_poll {} {
    set ila [_ila]
    _reset_conditions
    set_property TRIGGER_COMPARE_VALUE eq5'h1C [_p dbg_state]
    _capture_on_xfer_done
    set_property CONTROL.TRIGGER_POSITION 2048 $ila
    puts "Armed: trigger on state==S_POLL_END (0x1C), storing one sample per SPI byte."
}

# ---- capture 4: the automatic JEDEC ID read -- THE CONTROL EXPERIMENT ----------------------
# Needs NO button press: auto_load re-reads the ID every ~34ms, so this fires within a frame of
# arming. Trigger on S_ID_CMD (0x01), full rate, so the whole 4-byte ID exchange is visible bit
# by bit -- 4 bytes x 64 clocks = 256 clocks, easily inside the 4096-sample window.
#
# This is the reference against which the save capture is judged. A healthy W25Q128JV answers
# 0x9F with EF 40 18, which requires it to actually drive MISO. If MISO stays high here too,
# the SPI link is dead for every command and the save sequence is not the culprit; if it returns
# EF 40 18 while the save's status reads stay 0xFF, the fault is specific to what the save does.
proc ila_arm_jedec {} {
    set ila [_ila]
    _reset_conditions
    set_property TRIGGER_COMPARE_VALUE eq5'h01 [_p dbg_state]
    set_property CONTROL.CAPTURE_MODE ALWAYS $ila
    set_property CONTROL.TRIGGER_POSITION 64 $ila
    puts "Armed: trigger on state==S_ID_CMD (0x01), full rate. Fires by itself within ~34ms."
}

# ---- run ------------------------------------------------------------------------------------
# Status properties live under STATUS.*, refreshed only by an explicit refresh_hw_device. Use
# -update_hw_probes false: a full refresh re-reads the probes file and can knock the core out of
# its armed state, which looks exactly like "the trigger never fired".
proc ila_status {} {
    set ila [_ila]
    refresh_hw_device -update_hw_probes false -quiet [current_hw_device]
    puts [format "  %-16s %s" CORE_STATUS  [get_property STATUS.CORE_STATUS  $ila]]
    puts [format "  %-16s %s" SAMPLE_COUNT [get_property STATUS.SAMPLE_COUNT $ila]]
    return [get_property STATUS.CORE_STATUS $ila]
}

# Arm only -- returns immediately, so the console stays usable while you work the board buttons.
# Prefer this over ila_go: wait_on_hw_ila BLOCKS the Tcl console, and if the trigger never fires
# you are stuck needing to interrupt Vivado. (Easy to walk into here, because the save sequencer
# only accepts do_save from S_IDLE and never returns there once the poll stalls -- so there is
# exactly ONE trigger opportunity per configuration of the FPGA.)
proc ila_run {} {
    run_hw_ila [_ila]
    set st [ila_status]
    if {$st eq "IDLE"} {
        error "Core still IDLE after run_hw_ila -- it did NOT arm. Do not touch the board yet."
    }
    puts "Armed. Now on the board: hold SEL ~3s -> SAVE SETTINGS -> SEL. Then: ila_status, ila_fetch <tag>"
}

# Upload whatever the core has, display it, and dump a CSV readable outside Vivado.
# Refuses to upload an untriggered core: doing so STOPS it and throws the capture away
# ("[Labtools 27-157] hw_ila stopped. No data to upload."), and since there is only one trigger
# opportunity per configuration, that costs a whole reprogram cycle.
proc ila_fetch {{tag capture}} {
    set st [ila_status]
    if {[string match -nocase "*WAITING*" $st] || $st eq "IDLE"} {
        error "Core is '$st' -- NOT triggered. Uploading now would stop it and discard the capture.\
               Do the board sequence first (hold SEL ~3s -> SAVE SETTINGS -> SEL), then retry."
    }
    set d [upload_hw_ila_data [_ila]]
    display_hw_ila_data $d
    set csv [file normalize "C:/Users/wottle/Documents/Development/LisaFPGA/ila_${tag}.csv"]
    write_hw_ila_data -csv_file $csv -force $d
    puts "CSV written to: $csv"
}

puts "Loaded. Arm: ila_arm_jedec (no buttons) | ila_arm_program | ila_arm_wren | ila_arm_poll"
puts "       Run: ila_run -> (work the board) -> ila_status -> ila_fetch <tag>"
