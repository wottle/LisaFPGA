# LisaFPGA — Project Notes for Claude

## Recently completed: merged upstream (ESFloppy release) into feature/settings-flash-persistence,
## moved the on-screen menu's summon gesture off OK

**Branch:** `feature/settings-flash-persistence`, now merged with `main` (merge commit `6421dff`).

**Why the merge:** upstream (`alexthecat123/LisaFPGA`) shipped real ESFloppy firmware on 2026-08-18
(`1ddf2ad`), plus two commits after it. Our fork's `main` was already byte-identical to upstream `main` at
merge time, so this was really "pull the feature branch forward," not a cross-fork reconciliation. All
conflicts were confined to `LisaFPGA.runs/impl_1/*` — tracked Vivado build output (bitstream, P&R reports,
backup `.vdi` files) that both branches had independently regenerated. Resolved by keeping the feature
branch's own last-built artifacts (`git checkout --ours`); they'll be overwritten by the next real build
regardless. Zero conflicts in any actual source file (`top.sv`, `HDMI_Interface.sv`, `README.md` all merged
clean).

**Why the button-logic change:** ESFloppy's new firmware treats a held SEL button (the same physical button
wired to our `OK` input) as its own long-press gesture — `LONG_PRESS_DURATION = 1000ms` in its `uiState.h`
triggers a force-eject on its status screen (`ui.cpp`) or a screen-pop in its file picker
(`uiFilePicker.cpp`). Since our on-screen menu's summon gesture was "hold OK ~3s," and the buttons are wired
to both the FPGA and the ESFloppy ESP32 in parallel, every attempt to open our menu fired ESFloppy's 1-second
long-press first — an unwanted eject, every time.

**Fix (in `HDMI_Interface.sv`):** moved the summon gesture from "hold OK ~3s" to "hold LEFT+RIGHT together
~3s". Verified against ESFloppy's actual firmware source (cloned `alexthecat123/ESFloppy`) that LEFT and
RIGHT have **no hold-duration logic anywhere** — `ui.cpp`, `uiFilePicker.cpp`, `uiSettingsMenu.cpp` all read
them only as single-frame "move selection" press edges, so holding both together produces one harmless,
self-canceling nudge on ESFloppy's screen and nothing escalating. This is the one gesture on the 3-button pad
that's provably silent to ESFloppy.

Implementation split what used to be one `ok_pressed`-driven state machine into two independent ones:
- `summon_pressed` (`LEFT && RIGHT`, both active-low) drives a renamed `summon_frames`/`summon_long_fired`
  counter that toggles `menu_active` — structurally identical to the old `ok_frames`/`ok_long_fired` logic,
  just keyed off the chord instead of OK.
- OK's short-press action (activate menu item / cycle tuning axis) is now a plain release-edge detector
  (`!ok_pressed && prev_ok`), since OK no longer needs to distinguish short vs. long presses — every OK press
  is short now that it's not doing summon duty.
- Added `!summon_pressed` guards on the in-menu LEFT/RIGHT highlight-move block and the `tuning_active`
  offset write-back, so starting/ending the summon hold can't also nudge the menu highlight or (more
  importantly) walk the image to one edge over the 3-second hold if a user happens to be mid-adjustment when
  they summon the menu.

**Was untested when written** (superseded by the hardware test below). No Vivado/verilator/iverilog available in this environment (same constraint as
every prior session on this file) — this is a source-level change only, verified by careful reading and
structural comparison against the working `ok_pressed` logic it replaces, not by synthesis or a board. Next
step when hardware is available: build, flash, and confirm (a) LEFT+RIGHT hold opens/closes the menu, (b) a
disk in ESFloppy survives opening the menu without ejecting, (c) OK still activates menu items and cycles the
tuning axis/step, (d) tuning-mode LEFT/RIGHT image movement still works normally when summon isn't held.

**Hardware test (2026-10-03): PASSED, and now in flash.** Built at `5ef5c2a` (0 errors, WNS +0.253 / WHS +0.063,
0 failing setup/hold endpoints, only the 10 known 1080p60 pulse-width entries), JTAG-programmed, then written
to the config flash and confirmed by a cold boot from flash:

| Test | Result |
|---|---|
| (a) LEFT+RIGHT hold opens the menu | **Pass** — volatile, and again after cold boot from flash |
| (b) disk in ESFloppy survives the summon | **Not yet tested** — ESFloppy's OLED is out of action (see below), so there's no way to see whether a disk ejected |
| (c) OK activates menu items / cycles tuning axis | **Pass** — OK was how ADJUST IMAGE got turned on |
| (d) no drift while holding the chord in tuning mode | **Pass** |

Cold boot also brought back the saved alignment, confirming the flash write's `use_file` range left the
settings block at `0xC00000` alone. **(b) is the one this change exists for** — check it when the replacement
display arrives.

**Board repair (2026-10-04): USB-C uplink FIXED -- the fault was D5, the USB-C port's ESD clamp.** A failed buck
converter in the case put an overvoltage on the 5V rail. Symptom: the board powered up, booted and drove video
normally, but its USB-C uplink enumerated nothing at all -- no CH334F hub, no FT232H, no CP2102N, no ESP32s, all
four ACT LEDs dark, and not even an "Unknown USB Device" in Device Manager. The ESFloppy OLED also died and is
still out.

Diagnosis, from the rev 3 netlist (`lisafpga_rev_3_easyeda_project.epro2` is EasyEDA Pro text; the PCB section
records every pad's net in `PAD_NET` entries, which beats reading the schematic drawing):
- **D5 is a USBLC6-2SC6** across the USB-C uplink: pins 1/6 `USBC_DP`, 3/4 `USBC_DN`, 5 `5V_USBC`, 2 `GND`. The
  uplink D+/D- go straight to the **CH334F hub (U15)** pins 15/14.
- `5V_USBC` (USB-C VBUS) is a separate net from the board's main `5V`; **SW1 is the power switch joining them**,
  since USB-C is the board's only power input. SW1 was on during the event, so D5 took the overvoltage.
- D9/D10 are the same part on the keyboard/mouse ports, with VBUS on the main rail. They survived, and those
  ports still worked -- which argued D5 was not shorted.
- **The decisive measurement: DC volts on D+ (D5 pin 1) with the board powered and connected to the PC.** A live
  hub pulls D+ up through 1.5k against the host's 15k pull-down, giving ~3V; a dead hub gives ~0V. It read
  **0.8V** -- so the hub WAS alive, but something was dragging D+ down to roughly 500 ohms to ground, below the
  ~2V the host needs to detect an attach. That is why Windows saw nothing at all rather than a failed enumeration.
- With SW1 off, D5's VBUS net held only D5 and two 100nF caps, yet read 30k to ground where a healthy clamp
  reads open -- the overstressed clamp had gone leaky on both sides.
- **Removing D5 brought every device back immediately; a replacement USBLC6-2SC6 (marking `UL26`) was then fitted.**
  Confirmed afterwards: hub, FT232H (EEPROM identity intact, serial `000000` matching `ft232h_eeprom.bin`), both
  ESP32-S3s and the CP2102N all enumerate. Vivado then found the onboard FT232H as JTAG target
  `xilinx_tcf/Xilinx/000000` and the FPGA behind it, so the board's own JTAG path is fully back and
  `program_board.sh` is usable again. The CP2102N shows Device Manager problem code 28 on the Windows
  machine, which is only a missing Silicon Labs CP210x driver -- it reports its custom "LisaFPGA Serial B" string,
  so the chip and its EEPROM are fine.

**Lesson for any future "board runs but USB is dead":** measure D+ before replacing anything. ~0V = hub dead or
unpowered, ~3V = hub fine and the problem is elsewhere, anything in between = something leaking on the line.
And remove a suspect protection part *before* fitting its replacement -- testing with it absent is unambiguous,
whereas a straight swap that still fails can't tell a bad new part from a wrong diagnosis.

While the uplink was down, the 2026-10-03 hardware test above went through an external Digilent programmer on
header J19, which Vivado recognises natively; it remains a good fallback.

## Current work: HDMI output modes — 1080p30 / 1080p60 / 1024x768, runtime selectable

**Branch:** `feature/1024x768-hdmi-output` (created off `main`, not yet merged or pushed). Commit `6dbe125`
carries the original two-way 1024x768 work; everything after it is uncommitted at time of writing.

**Why:** The user has a 1024x768 display and wants LisaFPGA to drive it natively rather than relying on the
display's own upscaling. That grew into full runtime mode switching once a second (1920x1080, 11.6") panel
turned out to reject 1080p30 — see the display-compatibility finding below.

### What's implemented

**All three modes live in one bitstream and are selected at runtime** — see "Three-way runtime mode switching"
below for the details. In short: `video_mode` follows the FRAMERATE jumper (1080p30 / 1080p60) exactly as a
stock board does, until the on-screen menu's RESOLUTION item takes over, at which point all three are reachable.

Build-time constants in `top.sv`:
- `OUTPUT_1024X768` — whether the 1024x768 mode is *included* (it no longer picks which mode the jumper means).
- `OUTPUT_1080P_HALIGN` — where the image sits horizontally in the 1080p frame (centre / left / right).
- `ALIGNMENT_TUNING_MODE` — compiles in the on-screen menu and live alignment tuning.

**Files touched:**
- `top.sv` — the three constants above, passed down to `HDMI_Interface`, plus wiring the ESFloppy buttons in.
- `HDMI_Interface.sv` — by far the most changed: three-way clocking (cascaded BUFGMUXes), `video_mode`,
  video_id_code and audio-threshold selection, the 1024x768 H-ROM scaling (960x728, area-weighted
  anti-aliasing on the 4/3 horizontal axis), a 3A-ROM stopgap (centred 1:1, **not** properly scaled — still a
  follow-on), pipeline-latency compensation, and the whole menu/readout. Clocking-wise there are **two** MMCMs:
  the original `hdmi_clock_divider` (1080p30/60, untouched) and a dedicated `hdmi_clock_divider_1024x768`
  (65MHz / 325MHz), each with its own external feedback BUFG loop.
- `LisaFPGA.srcs/sources_1/imports/hdmi/hdmi.sv` — frame timing derived at runtime from `video_id_code`
  (16=1080p60, 34=1080p30, 0=1024x768 VESA DMT "no CEA data" sentinel) rather than hardcoded. `frame_width` is
  now also exported, for the pipeline-latency wrap.
- `LisaFPGA.srcs/constrs_1/imports/lisaStuff/LisaFPGA.xdc` — three-way pixel-clock exclusivity, `clk_audio`
  declared asynchronous to the pixel clocks, `CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN` on the cascade's
  intermediate nets and the 1024x768 MMCM outputs, and CE false paths on every clock mux (HDMI and DOTCK).
  **Read "Vivado/XDC gotchas" below before touching this file** — several constraints here were silently not
  applying for a long time, and the XDC has real restrictions that fail quietly.
- `LisaFPGA.srcs/sources_1/new/mem_board_2mb.sv` — fixed a pre-existing declaration-order error.
- `tools/vivado_scripts/add_1024x768_clocks.tcl` — **required one-time manual step**, see below.
- `README.md` / `FAQ.md` — updated for `OUTPUT_1024X768` and `OUTPUT_1080P_HALIGN`.

### Required one-time Vivado step before building with `OUTPUT_1024X768 = 1'b1`

Vivado wasn't available in the environment this was developed in, so the Clocking Wizard IPs' `.xci`
files couldn't be safely hand-edited (they're checksummed). Instead, run this once inside Vivado (Tcl
Console, or `vivado -mode batch -source ... -tclargs LisaFPGA.xpr`):
```tcl
source tools/vivado_scripts/add_1024x768_clocks.tcl
```
This creates a **second, dedicated** Clocking Wizard IP, `hdmi_clock_divider_1024x768` (65.0MHz pixel,
325.0MHz 5x TMDS), alongside the existing `hdmi_clock_divider` (left at its stock 4 outputs).

**Why a separate IP, not just two more taps on `hdmi_clock_divider`:** the first attempt at this *did*
just add CLKOUT5/6 taps to the existing IP, and it looked like it worked (Vivado accepted the config,
no errors) — but checking the actual locked frequencies (`MMCM_CLKOUT5_DIVIDE`/`MMCM_CLKOUT6_DIVIDE`
against the shared VCO) showed they'd landed at ~67.47MHz and ~371.09MHz (3.8%/14.2% off nominal), and
critically the ratio between them was 5.5, not the exact 5 that TMDS/OSERDES2 serialization requires.
`hdmi_clock_divider`'s one VCO is tuned to be a clean multiple of 74.25MHz for the 1080p clocks, and
65MHz doesn't share a clean common multiple with that — no integer divider pair off that VCO could hit
both 65/325MHz *and* an exact 5:1 ratio. A dedicated MMCM with its own, unconstrained VCO fixes this.
**Always check the achieved-frequency math after running this script** (dump
`CONFIG.MMCM_CLKOUT{0,1}_DIVIDE{_F}`, `CONFIG.MMCM_CLKFBOUT_MULT_F`, `CONFIG.MMCM_DIVCLK_DIVIDE` on
`hdmi_clock_divider_1024x768` and recompute) rather than trusting "no errors" — if the achieved
frequencies are meaningfully off 65.000/325.000MHz, or the ratio isn't exactly 5, the 1024x768 audio-divider
threshold (`12'd676` in `HDMI_Interface.sv`) would need recomputing to match. **Already confirmed correct on
this project's actual build**: VCO = 125MHz × 39.000/5 = 975MHz, giving CLKOUT1
(`MMCM_CLKOUT0_DIVIDE_F=15.000`) = 975/15 = exactly 65.000MHz, and CLKOUT2 (`MMCM_CLKOUT1_DIVIDE=3`) =
975/3 = exactly 325.000MHz — a perfect, error-free 5:1 ratio.

**Audio threshold arithmetic, since it has been got wrong twice:** the counter runs `0..threshold` inclusive,
so a half period is `threshold + 1` clocks and the full divide is `2*(threshold + 1)`. Therefore
`threshold = round(f_pixel / 96000) - 1`, giving 772 (1080p30), 1546 (1080p60) and **676** (1024x768). An
earlier version used 677 for 1024x768 by rounding 65000000/(2*48000) = 677.08 and forgetting the `-1`; that
gave a ~0.15% pitch error — inaudible, but wrong.

### Vivado/XDC gotchas learned the hard way (2026-08-02, Vivado 2026.1)

All of these were found while getting the first `OUTPUT_1024X768` build through the tools. Every one of
them failed **silently** — Vivado emitted a critical warning buried among ~140 others and completed the
run anyway, so the build "succeeded" while doing the wrong thing.

- **XDC rejects `proc` AND `if`** — `[Designutils 20-1307] Command 'if' is not supported in the xdc
  constraint file`. It's a CRITICAL WARNING, not an error, so anything inside the block just never
  applies. Write plain unconditional constraints. This bit us twice: an `if`-guarded `clk_audio`
  constraint meant the audio clock was **completely unconstrained** for every build up to 2026-08-02,
  and an `if`/`proc`-guarded `set_clock_groups` meant pixel-clock exclusivity never applied either.
  If conditional constraints are genuinely needed, a `.tcl` file in the constraints fileset allows full
  Tcl (Vivado `source`s it rather than `read_xdc`-ing it). The `clk_audio` line now has to be swapped
  by hand when flipping `OUTPUT_1024X768` — see the comment block on it in the XDC.
- **Verify a constraint bound by its EFFECT, never by absence of an error.** "No 12-4739 warnings" is
  equally consistent with "constraint applied" and "constraint never ran". Check the Inter Clock Table
  in `top_timing_summary_routed.rpt` — if the supposedly-exclusive clocks still appear as a row there,
  the group didn't take.
- **Vivado renames IP-derived clocks.** The 1024x768 clocks are
  `clk_pixel_1024x768_hdmi_clock_divider_1024x768` (`<output_port>_<ip_instance>`), *not* the bare port
  name — same suffixing as the existing `dotck_20M_dotck_mmcm`. Confusingly the `hdmi_clock_divider`
  ones *aren't* suffixed. Always check real names with `get_clocks` rather than assuming.
- **IP-internal net paths for `CLOCK_DEDICATED_ROUTE`** live at
  `lisa_hdmi_output/hdmi_clock_generator_1024x768/inst/<port>`, not at the `HDMI_Interface` level.
  Wrong path = `get_nets` matches nothing = constraint silently does nothing.
- **`clk_pixel_1080p60` does not exist in an `OUTPUT_1024X768` build** (those MMCM taps go unused, so no
  clock is derived), and symmetrically the 1024x768 clocks don't exist in a stock build. A constraint
  naming a nonexistent clock kills the whole `set_clock_groups`, so both pairs are declared
  unconditionally with `get_clocks -quiet`; whichever pair can't resolve logs a benign 12-4739 and
  applies nothing.
- **Clocking Wizard `CLKOUTn_DRIVES` must be `No_buffer`** on `hdmi_clock_divider_1024x768`, matching the
  stock IP, because the `BUFGMUX` in `HDMI_Interface.sv` *is* the buffer. Leaving the default (`BUFG`)
  inserts a redundant buffer, creating a `BUFG->BUFG` cascade that **fails placement outright**
  (`rule_cascaded_bufg` / "IO Clock Placer failed") when the two land in different halves of the device.
- **Clocking Wizard properties have ordering dependencies** — `CLKOUTn_REQUESTED_OUT_FREQ` is read-only
  until `CLKOUTn_USED` is committed true, and a single `set_property -dict` validates the whole dict
  against the pre-change state and rolls the entire batch back. Hence the split `set_property` calls in
  `add_1024x768_clocks.tcl`. Also: `NUM_OUT_CLKS` is derived, not settable (harmless warning), the
  property for cloning an IP's type is `IPDEF` (not `VLNV`), and IPs created by an older Vivado are
  `IS_LOCKED` until `upgrade_ip`, which makes *all* their CONFIG properties read-only.
- **Synthesis of this design legitimately takes ~85 minutes**, nearly all of it in a single silent
  "Cross Boundary and Area Optimization" phase that can go **60+ minutes with zero log output and flat
  memory** while pegging one core. This is NOT a hang — do not kill it. (It was killed once on exactly
  that mistaken diagnosis, costing a full cycle.) Implementation is separately ~50 min.
- **Constraint-only changes do not need re-synthesis.** The implementation run does
  `add_files top.dcp` + `read_xdc` + `link_design`, so it re-reads the XDC from source every time. Use
  `set_property NEEDS_REFRESH false [get_runs synth_1]` + `reset_run impl_1` to skip the 85-minute
  resynthesis. Only do this when the RTL genuinely hasn't changed.
- **1080p60 builds cannot report "timing met" — and that is pre-existing, not a regression.** The 1080p60 TMDS
  clock is 742.19MHz (5x the 148.5MHz pixel clock, for 10:1 OSERDES serialization), and that exceeds the rated
  speed of the primitives carrying it on this -2 Artix-7: `BUFGCTRL` min period is 1.592ns (~628MHz) and
  `OSERDESE2/CLK` is 1.471ns (~680MHz), against an actual 1.347ns. Nine pulse-width endpoints fail on
  `clk_pixel_x5_*`, WPWS around -0.245ns. Both the BUFGMUX and the 742.5MHz clock are original LisaFPGA design,
  so every stock build has always had this; it is marginal-but-working silicon behaviour, and 1080p60 output is
  demonstrably fine on real hardware. **Do not chase it as a bug.** It does NOT appear in `OUTPUT_1024X768`
  builds, whose 5x clocks are 325MHz (1024x768) and 371MHz (1080p30), both well inside spec. When judging a
  1080p60 build, check that setup (WNS) and hold (WHS) are clean and that the only failures are these
  pulse-width entries.
- **`sysclk_ibuf` is an IBUF output and must NEVER clock fabric registers** (fixed 2026-08-17). It feeds
  four MMCM reference inputs, which is legitimate on a dedicated route, but with no BUFG the net runs on
  general routing and its insertion delay depends on placement. `settings_flash` alone puts ~250 registers
  on it (fanout was 281), and on the first build with `DEBUG_FLASH_ILA` turned back off the clock arrived
  3.796ns at one end and 7.646ns at the other: **3.735ns of skew against 0.673ns of data delay, giving 58
  hold violations at WHS -3.211ns** on same-clock, zero-logic-level paths. Setup was fine (WNS +0.029) —
  hold is what breaks, and hold failures are fatal regardless of clock speed.
  It had passed every previous build purely by luck: the ILA needs a real clock buffer, so Vivado inserted
  a BUFG on that net and every register downstream inherited a low-skew clock. **Turning the debug core
  off is what exposed it**, which is a nasty ordering — the "clean up for production" step is the one that
  broke timing. Fix: `sysclk_fabric`, a BUFG'd copy, now clocks everything in the fabric
  (`settings_flash`, the two save/load handshake blocks in `top.sv`, and `IO_board`); `sysclk_ibuf` goes
  only to MMCM reference inputs. Check WHS, not just WNS, on any build where a debug core is added or
  removed.
- **Flash programming from Vivado fails at the default 15MHz JTAG clock. Use 3MHz.** (Found 2026-10-03.)
  `program_hw_cfgmem` erased fine, then wrote ~1.48MB correctly before `Program/Verify Operation failed.
  Byte 1551953 does not match (FF != 00)` — `[Labtools 27-3347] Flash Programming Unsuccessful`. **The
  error text blames the flash part ("verify the selected flash part matches"), and that is a red herring**:
  Vivado had just read the JEDEC ID itself (`ef 40 18`, correct for the W25Q128JV) and the erase had worked.
  A write that succeeds for a megabyte and a half and then drops a byte is a marginal link, not a wrong part.
  The same `27-3347` failure happened in August through the board's onboard FT232H, so it is not specific to
  one programmer. Fix, before creating the cfgmem:
  ```tcl
  close_hw_target
  set_property PARAM.FREQUENCY 3000000 [current_hw_target]
  open_hw_target
  ```
  Then succeeded first time, in 2m41s. Closing the target invalidates `current_hw_device` and any existing
  cfgmem handle, so reselect the device and recreate the cfgmem afterwards.
  The correct part string for this board's **W25Q128JVSIQ** is **`w25q128jvq-spi-x1_x2_x4`** — the trailing
  `Q` in the ordering code is Winbond's fixed-Quad-Enable variant, which Vivado lists as `jvq`. (`jvm` is the
  DTR variant; `_x8` entries are for dual-parallel flash pairs.) Always set
  `PROGRAM.ADDRESS_RANGE use_file`: it erases only the bitstream's sectors (`0x000000`-`0x3A607B`), which is
  what keeps the saved settings block at `0xC00000` alive across a reflash — confirmed by cold boot.
  **If a flash write fails, do not power-cycle**: the bitstream region is erased or partial and the board
  will come up unconfigured. JTAG still works and a retry recovers it.
- To iterate faster when RTL *has* changed, `STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none` (skips the
  phase that eats the hour) and `.DIRECTIVE RuntimeOptimized` help a lot; turn both off for a final build.

### Hardware test result (2026-08-02): WORKS — 1024x768 output confirmed on the real display

The `OUTPUT_1024X768 = 1'b1` build was JTAG-programmed onto the board (`top.bit` straight into the FPGA via
Vivado Hardware Manager — the board's FT232H shows up as `xc7a100t_0`, no `.mcs` or openFPGALoader needed
for a volatile test) and **the 1024x768 picture came up correctly, filling most of the screen.** The
clocking, frame timing, `video_id_code` switching and centering all work.

**One quality issue found, and being addressed:** text showed vertical strokes alternating between 1px and
2px wide. That's inherent to the nearest-neighbour 4/3 horizontal scale — the LUT drew one of every three
source columns twice. Fixed by switching the 1024x768 H-ROM horizontal path to **area-weighted
anti-aliasing**: each output pixel covers exactly 0.75 of a source pixel, so of every 4 outputs two are pure
and two are a 2/3 + 1/3 blend of adjacent source columns, making every stroke render at equal visual weight.
See the long comment on `hscale_lut_a`/`hscale_lut_b`/`hscale_blend` in `HDMI_Interface.sv`.
- This is the only place output stops being strict nearest-neighbour; 1080p and the 3A path are untouched
  and stay perfectly sharp integer scales (`blend_en` is hardwired low there, so `pixel_level` only ever
  takes its 0 or 3 values and the greys never appear).
- `pixel` (1 bit) became `pixel_level` (2 bits, intensity in thirds), and RGB generation now scales
  `white_level` by 85/256 or 171/256 for the two intermediate greys.
- **It needs two framebuffer reads per output pixel** (primary + secondary column), so Vivado has to
  replicate the ~33KB framebuffer block RAM. **Check BRAM utilization after synthesis** — if it fails to
  infer block RAM and falls back to distributed RAM, LUT usage will explode and the array should be
  explicitly duplicated into two identically-written copies instead.
- Why not just use an integer scale and avoid all this: 1024 can't fit 720 at 2x (needs 1440), and the only
  integer option, 1x, gives a 720x728 image that's ~25% too narrow. Correct proportions need ~4:3, which is
  what 960x728 provides. Within 1024x768 you cannot have both correct aspect and uniform pixel widths.

**Still untested on hardware:** audio in either jumper position. (The 1080p30 fallback position was confirmed
working on 2026-08-07 while testing `OUTPUT_1080P_HALIGN` — see that section below.)

### Earlier status: BUILDS CLEANLY

As of 2026-08-02 an `OUTPUT_1024X768 = 1'b1` build gets all the way through synthesis, implementation and
bitstream generation on Vivado 2026.1 (Windows machine — a Mac Pro running Windows, project copied over via
USB from the Mac where this was originally developed; driven interactively from its Tcl Console). Nothing
has been programmed onto a board yet.

**Timing status: MET.** `All user specified timing constraints are met` — WNS +0.366ns / WHS +0.051ns,
**0 failing endpoints of 10022** on setup, hold and pulse width. The 1024x768 pixel domain has lots of
margin (65MHz is far below the 148.5MHz this pipeline was tuned for); the tightest clock in the design is
the pre-existing `dotck_80M`.

Getting there took four implementation runs, because three separate constraint bugs each failed silently
(see the XDC gotchas above). The sequence, in case timing ever regresses:
- `set_clock_groups` for pixel-clock exclusivity wasn't binding, so Vivado analyzed ~1659 impossible paths
  between `clk_pixel_1080p30` and the 1024x768 pixel clock (both feed the same BUFGMUX; the jumper picks
  one). That alone was WNS -8.125ns / TNS -10875ns. **Check the Inter Clock Table in
  `top_timing_summary_routed.rpt` first if timing looks bad — if those two clocks appear as a row there,
  the exclusivity isn't applying again.**
- Once `clk_audio` was genuinely constrained for the first time, the TONE/VC CDC synchronizers into it
  showed up as hold violations and needed `set_false_path` (now in the XDC).
- One last pre-existing hold violation (`SPEED_SEL_dotck_reg[1]` -> `dotck_final_mux/CE0`, ~-0.02 to -0.25ns
  depending on placement) needed false paths on the three DOTCK clock muxes' CE pins, mirroring what the XDC
  already did for the HDMI framerate mux. **This one came back later** because the fix had originally been
  pasted into the Tcl console rather than the XDC file — an in-memory constraint applies to that run only and
  silently vanishes on the next one. It is now genuinely in `LisaFPGA.xdc`. Lesson: put constraint fixes in the
  file, not the console, or the next build quietly regresses. Mirroring what the XDC already did for
  the HDMI framerate mux. This is unrelated to 1024x768 and applies to stock builds too.

**Test plan:**
1. Run `tools/vivado_scripts/add_1024x768_clocks.tcl` (one-time) and verify the achieved frequencies/
   ratio as described above.
2. Flip `OUTPUT_1024X768` to `1'b1` in `top.sv`, and swap the `clk_audio` constraint in the XDC to the
   1024x768 variant (see the comment block on it — this is manual, XDC can't branch).
3. Synthesis → Implementation → Bitstream, then generate `top.mcs` — note the bitstream run does NOT produce
   the .mcs, that needs a separate `write_cfgmem`. The config flash is a **Winbond W25Q128JVSIQ, 128Mbit =
   16MB** (found in the rev 3 schematic), so `-format mcs -interface spix4 -size 16` is correct; the bitstream
   is ~3.65MB. `program_board.sh` expects the result at `LisaFPGA.runs/impl_1/top.mcs`. Check the Timing
   Summary as described above.
   Knowing the part means the flash can also be written **directly from Vivado** on the Windows machine via
   `create_hw_cfgmem` + `program_hw_cfgmem` (`get_cfgmem_parts w25q128*` for the exact part string), instead of
   copying the .mcs to the Mac for openFPGALoader — openFPGALoader only avoided needing the part number
   because it auto-detects the JEDEC ID.
4. Copy `top.mcs` back to the Mac, program via `program_board.sh` or
   `openFPGALoader --cable ft232 --fpga-part xc7a100tcsg324 --write-flash <path>/top.mcs`.
5. Test **both** jumper positions against the 1024x768 display: first position should show 1080p30
   (fallback works), second position should show 1024x768@60Hz, centered, with ~32px/~20px borders, no
   rolling/tearing. **Check audio in both positions** — that's the main functional risk introduced by
   the dynamic audio-clock-threshold rework.

### 1080p horizontal alignment constant (added 2026-08-07)

`OUTPUT_1080P_HALIGN` in `top.sv` (`HALIGN_CENTER` / `HALIGN_LEFT` / `HALIGN_RIGHT`, default centre) picks where the
image sits horizontally within the 1080p frame, for cases whose screen cut-out isn't centred on the panel. Passed to
`HDMI_Interface` as the `HALIGN_1080P` parameter, which derives `H_ROM_1080P_X` / `A3_ROM_1080P_X` at elaboration
time — these replaced the hardcoded 240 / 352 offsets in both the `lisa_x` computation and the active-area test.
Spare width is 480px (H ROM, 1440 wide) and 704px (3A ROM, 1216 wide). 1024x768 is deliberately unaffected.

**Confirmed working on hardware 2026-08-07** with `OUTPUT_1080P_HALIGN = HALIGN_LEFT`: the image sits flush against
the left edge of a 1080p LCD with the whole 480px border on the right. Timing still met (WNS +0.798ns / WHS +0.071ns,
0 failing endpoints of 10645). Note this was tested from an `OUTPUT_1024X768 = 1'b1` build with the FRAMERATE jumper
in its **first** position — the alignment constant only affects the 1080p paths, so that's the position that exercises
it, and it means **the 1080p30 fallback is now also confirmed working on hardware** (previously untested).
`HALIGN_RIGHT` and the 3A ROM offsets have not been tested, but they're the same two derived constants.

### On-screen menu + live alignment tuning (`ALIGNMENT_TUNING_MODE`, added 2026-08-08)

**Confirmed working on hardware 2026-08-08 — menu and all four settings tested and behaving as expected.**

`ALIGNMENT_TUNING_MODE` in `top.sv` (default `1'b0`) compiles in a runtime menu driven by the three ESFloppy
buttons. It's designed so a single bitstream behaves **exactly like a stock build** until you deliberately
summon the menu, which is why it can reasonably be left enabled:

| State | LEFT / RIGHT | OK short press | OK held ~5s |
|---|---|---|---|
| Normal | nothing (still pass through to the ESP32) | nothing | **open menu** |
| Menu open | move the highlight | activate the item | close menu |
| Adjust on, menu closed | move the image | cycle axis then step size | open menu |

Menu items: `RESOLUTION` (1080P30 / 1080P60 / 1024X768), `ADJUST IMAGE`, `SCANLINES`, `MAX CONTRAST`,
`SAVE SETTINGS`, `EXIT`. The selected
row is drawn inverted, and the box auto-centres for whichever mode is live.
- Each setting is a **toggle XORed onto the real input** (`mode_sel_eff`, `scanlines_eff`, `contrast_eff`), so the
  physical jumpers still work and the menu just flips whatever they currently say.
- **RESOLUTION only switches between the two modes the build already has** (the FRAMERATE jumper's two positions).
  Getting 1080p60 *and* 1024x768 selectable in one build is a much bigger job — see the note below.
- Long presses are timed by counting frames, so the target changes with frame rate (300 frames at 60Hz, 150 at
  30Hz). OK's short-press action fires on *release*, so a long hold doesn't also trigger it on the way past.
- **`mode_override` is a register in the `clk_pixel` domain that selects the BUFGMUX generating `clk_pixel`** —
  a deliberate circular dependency that works because BUFGMUX switching is glitchless. Confirmed working on
  hardware, but it's the most novel thing here; if mode switching ever hangs instead of re-syncing, move that
  register to a stable clock domain.
- Font is 64 glyph slots of 8x8 (digits, space, colon, A-Z), built at elaboration from readable string literals
  via `ascii_glyph()` rather than hand-encoded ROM contents.
- Whole thing costs ~700 LUTs over the pre-menu build (18333 -> 18933, 29.9%) and doesn't move timing.

**Alignment tuning specifics** (the `ADJUST IMAGE` item):
- The current offset is drawn as `X240C` style in the top-left: axis, three digits, then `C`/`F` for the step.
  Read the number off, bake it in, then turn the constant back off.
- Buttons are sampled once per frame, which doubles as a ~16ms debounce; holding repeats at 60/sec.
- The image offset starts wherever `OUTPUT_1080P_HALIGN` put it, and clamps to 480 (H ROM) / 704 (3A ROM).
- Offsets seed on the first frame from `CPU_ROM_SEL`, so 3A machines start centred too.
- **The ESFloppy OLED cannot be used for this** — checked the rev 3 schematic: `OLED1` is on `ESFLOPPY_SCL`/`SDA`,
  which are ESP32-S3 pins. The FPGA has no I2C path to it; its only link to that subsystem is the 6-bit
  `ESFLOPPY_COMM_BUS`. Hence the on-screen readout instead. The three buttons *are* real FPGA pins
  (G13/D14/C14) and are still passed through to the ESP32 as before, so nothing is broken for ESFloppy.
- Works in **both** output modes, with a **separate offset register per mode** (`h_offset_1080p` /
  `h_offset_1024`) so flipping the jumper doesn't destroy the value you just tuned in the other one. The buttons,
  the readout and the clamp all follow whichever mode is currently live. Spare width, and hence the clamp, is
  480 (1080p H ROM) / 704 (1080p 3A) / 64 (1024x768 H ROM) / 416 (1024x768 3A stopgap) — note 1024x768 has far
  less room to move than 1080p. Switching modes re-clamps if the stored value exceeds the new mode's limit.
- Only the *horizontal* offset is adjustable. 1024x768 does have 40px of vertical slack (728 rows in 768) if
  vertical tuning is ever wanted; 1080p H ROM has none (1092 rows cropped into 1080).
- When disabled the offsets fold back to elaboration-time constants; **check utilization on the first build with
  it enabled**, since the readout adds a 128-byte font ROM plus three 1024x4 decimal-conversion ROMs.



### Three-way runtime mode switching (2026-08-11) — WORKING ON HARDWARE

**All three modes now live in one bitstream and selectable at runtime: 1080p30, 1080p60 and 1024x768.**
Confirmed working on hardware. This replaced the old scheme where `OUTPUT_1024X768` chose, at synthesis time,
which single mode the FRAMERATE jumper's second position mapped to.

- `video_mode` (2-bit register in `HDMI_Interface.sv`) is the single source of truth: 0=1080p30, 1=1080p60,
  2=1024x768. It follows the FRAMERATE jumper (30/60) until the menu's RESOLUTION item is used, after which the
  menu owns it — so an untouched board behaves exactly like a stock one. Seeded on the first frame tick because
  the jumper is a runtime input; the ~33ms of 1080p30 before that is far shorter than any display takes to sync.
- **Cascaded BUFGMUXes**: stage A picks the 1080p rate, stage B swaps in 1024x768 (same for the x5 clocks).
  Needs `CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN` on the intermediate nets, exactly like the DOTCK mux chain.
- `OUTPUT_1024X768` now only controls whether mode 2 is *reachable*. Clear it and the second mux stage plus the
  entire 1024x768 scaling path fold away as dead code, for a leaner build.
- The audio counter always runs off the muxed `clk_pixel` with a three-way threshold (772 / 1546 / 676), so
  **the old manual clk_audio XDC swap is gone** — that whole class of "forgot to swap it" bug no longer exists.

**Timing lessons from getting there (three implementation runs):**
- The AA (anti-aliasing) path closes fine at 148.5MHz. An earlier stock build seemed to prove this but did NOT:
  with `OUTPUT_1024X768` clear the whole blend path is dead code and gets optimised away (BRAM dropped 34 -> 18
  tiles, which is how we spotted it). Only a build where 1024x768 is reachable actually exercises it.
- **`clk_audio` must be declared asynchronous to the pixel clocks.** Once it is sourced from the BUFGMUX output
  it becomes "related" to all three, and the 1080p60 relationship (half of 1080p30's period) fails on all 258
  audio_sample_word endpoints at ~-1.3ns. It is a 48KHz -> 148.5MHz handoff with no phase relationship.
- **The 1080p60 pixel domain is the tight one: WNS +0.096ns**, versus +6.8 (1080p30) and +8.7 (1024x768). The
  critical path is `hdmi/cx_reg` -> `lisa_x_b_reg`, 10 logic levels / 4 carry chains: the PIPELINE_LAT add, the
  `>= frame_width` compare, the wrap subtract and the offset subtract, all in one clock. It signs off, but with
  little headroom. **If more margin is ever needed, register `cx_adj`** so the add/compare/wrap lands in one
  clock and the offset subtract in the next, and bump `PIPELINE_LAT` from 6 to 7 to keep the alignment.
- Pulse width still shows 10 failing endpoints — the pre-existing 1080p60 742MHz BUFG/OSERDES limit documented
  above, now one endpoint worse purely because the cascade adds a BUFGMUX. Not a regression.

**HDMI audio remains untested on hardware** and is hard to test on this setup, because the board's onboard
speaker is driven from the `TONE` pin straight into a hardware Speaker Amp — completely independent of the
HDMI audio packet path. So HDMI audio only matters to someone using a monitor's speakers.

### Display compatibility finding (2026-08-11): some panels reject 1080p30 but accept 1080p60

An 11.6" 1920x1080 panel showed "No support" for LisaFPGA's 1080p30 while happily displaying an Apple TV, and
the **same** LisaFPGA signal worked on a different monitor. The signal is fine; the panel simply doesn't accept
that mode. Most PC-style monitors and small driver boards specify a vertical frequency range like 50-75Hz, and
1080p30's 30Hz refresh falls *below* the minimum, so the scaler rejects it as out of range. TVs are usually more
permissive because 24/30Hz are normal broadcast rates. **Confirmed on hardware: a stock (`OUTPUT_1024X768 = 0`)
build driving 1080p60 displays correctly on that panel.** So "the display is 1920x1080" does not imply it takes
1080p30 — accepting 1080p60 says nothing about 1080p30, they are separate modes negotiated separately.

Practical consequence: **that panel cannot use an `OUTPUT_1024X768` build at all**, because such a build's only
1080p mode is 1080p30. Serving both that panel and a 1024x768 display from one bitstream requires the three-way
mode project below. Note also that LisaFPGA never reads EDID (`HDMI_SCL`/`HDMI_SDA` are commented out in the
XDC) and ignores hot-plug detect, so it cannot adapt to what a display advertises — it just emits the mode.


### Settings persistence in the config flash — WORKING ON HARDWARE (2026-08-14)

`settings_flash.sv` reuses the FPGA's own configuration flash (Winbond W25Q128JV) to store a 16-byte
settings block at **0xC00000** (12MB in, ~8MB clear of the 3.65MB bitstream at address 0), so alignment
offsets survive a power cycle. **Confirmed end to end on hardware on 2026-08-14**: the menu's SETTINGS item
showed SAVED, and after reconfiguring the FPGA the board came straight up with the saved alignment instead of
the compile-time defaults. Erase, page-program, checksum, load and fallback all work.

The root cause of the long-running failure is written up under "ROOT CAUSE" below — a free-running SCK
divider that dropped the MSB of the first byte of every command issued after a deselect. Read that section
before touching the shift engine.

A blank sector still falls back to compile-time defaults, which is what a board with nothing saved should do.

**Menu behaviour on the `SAVE SETTINGS` row.** `settings_valid_q` is sticky — it means "a valid block exists
in flash" — so once the first save lands the row would read SAVED forever and a second save would produce no
visible change even though it really did write. A `save_disp_cnt` frame counter therefore forces the row to
show `SAVING` for 30 frames (~0.5s at 60Hz, ~1s at 30Hz) on every press, then fall back to `SAVED`. The write
itself is much shorter than that, so without the hold the transition would flicker past in two or three
frames. `SAVING` also overrides the JEDEC/`dbg_word` hex readout that the row shows while nothing is saved.

**How it is accessed.** After configuration, CS/MOSI/MISO appear on ordinary bank-14 I/O — `FCS_B=L13`,
`D00_MOSI=K17`, `D01_DIN=K18` on this part (confirmed via `get_package_pins -filter {PIN_FUNC =~ "*FCS_B*"}`,
not guessed). CCLK is **not** a user pin and can only be driven through `STARTUPE2`'s `USRCCLKO`. Single-bit
SPI throughout, clocked from the stable 125MHz sysclk (NOT the pixel clock, whose frequency changes with mode).

**What was wrong and got fixed along the way** — all of these were real, and none of them alone fixed it:
- **The flash was completely silent (JEDEC ID read back FFFFFF).** Fixed by some combination of driving
  `WP#`/`HOLD#` (L14/M14) high — a floating HOLD# low holds the chip inert — gating the first access on
  `STARTUPE2`'s `EOS`, and retrying every ~34ms instead of once at power-up. The three were bundled, so which
  one mattered is unknown. After this the ID read **EF4018**, correct for a W25Q128JV.
- **CS never rose to commit the erase.** `S_ER_A0` launched the last address byte and jumped straight to the
  status poll, so the command was still in flight and CS stayed low. SPI commands commit on CS *rising*.
  Added `S_ER_END` plus a shared `S_DESEL` state holding CS high ~256ns between every command.
- **`settings_save_req` and `settings_valid_q` were driven from TWO `always_ff` blocks.** Multiple drivers on
  a register — illegal, and Vivado resolved it silently with no error or warning rather than failing. The save
  request never behaved as written. All of that logic now lives in one block.

**Where it was stuck** (historical — resolved 2026-08-14, see ROOT CAUSE below). With a live state readout on the menu (`dbg_word` = state / last rx byte / flags), the
sequencer *is* running the save: it reaches the page-program phase and cycles `S_PP_DATA` -> `S_DESEL` ->
`S_POLL_RD` -> `S_POLL_END`. But the status register reads **0xFF**, whose bit 0 (BUSY) is set, so the poll
never exits. 0xFF is not a valid status value (a real part returns 0x00 idle / 0x03 busy) — it is the
signature of the flash not driving MISO at all. So mid-sequence the chip stops responding, even though a
JEDEC read from a fresh idle state works.


**Goal, precisely.** Let a user tune image alignment (and scanlines/contrast/resolution) from the on-screen
menu and have it survive a power cycle, so nothing has to be baked into the bitstream. The fallback if this
is abandoned is unchanged and perfectly usable: read the offset off the tuning readout and put it in
`OUTPUT_1080P_HALIGN` (or an explicit pixel constant), which is how the tuning tool was designed to be used.

**Block format** (16 bytes at 0xC00000), so a known-good block can be written externally to test the read
path in isolation:

| Offset | Contents |
|---|---|
| 0..3   | magic `'L' 'F' 'P' 'G'` |
| 4..5   | h_offset_1080p (little-endian, 11 bits used) |
| 6..7   | v_offset_1080p |
| 8..9   | h_offset_1024 |
| 10..11 | v_offset_1024 |
| 12     | flags: bit0 scanlines, bit1 contrast, bits3:2 video_mode, bit4 "video_mode valid" |
| 13     | reserved |
| 14..15 | checksum: plain 16-bit sum of bytes 0..13 |

1080p30 and 1080p60 deliberately SHARE one offset pair — same 1920x1080 frame geometry, so the image sits in
the same place; only the refresh differs.

**How a save is requested** (three clock domains, worth knowing before changing anything): the menu (pixel
domain) snapshots the current values into `settings_save_data` and raises `settings_save_req` as a LEVEL.
top.sv synchronises that into sysclk, takes its rising edge as a one-shot `do_save`, waits to actually see
`busy` go high and then fall, and reports `settings_save_done` back as a level which the pixel domain
synchronises and uses to drop the request and set the SAVED indicator.

**Reading the on-screen diagnostic.** With the tuning menu open, the SAVE SETTINGS row shows `dbg_word` as six hex
digits, `SSRRFF`: `SS` = sequencer state, `RR` = last byte received, `FF` = flags (bit1 `do_save`, bit0
`busy`). State numbering follows the enum order in `settings_flash.sv`:

| Hex | State | Hex | State |
|---|---|---|---|
| 00 | S_IDLE | 11 | S_ER_END |
| 01-04 | S_ID_CMD, D0, D1, D2 (JEDEC) | 12 | S_PP_WREN |
| 05-09 | S_LD_CMD, A2b, A2, A1, A0 | 13 | S_PP_CMD |
| 0A-0B | S_LD_DATA, S_LD_CHECK | 14-17 | S_PP_A2, A1, A0, AL |
| 0C | S_ER_WREN | 18 | S_PP_DATA |
| 0D | S_ER_CMD | 19 | S_DESEL |
| 0E-10 | S_ER_A2, A1, A0 | 1A-1C | S_POLL_CMD, RD, END |

The values actually observed on hardware were **18FF01, 19FF01, 1BFF01, 1CFF01** = S_PP_DATA, S_DESEL,
S_POLL_RD, S_POLL_END, all with rx=FF and busy=1: the page-program phase runs, then the busy-poll spins
forever on a status byte of 0xFF. Re-derive this table from the enum in `settings_flash.sv` after any edit —
inserting a state renumbers everything below it.

**Hypotheses tested and ruled out**, so they are not re-tried:
- *Wrong pins* — no. `FCS_B=L13`, `D00_MOSI=K17`, `D01_DIN=K18` came from `get_package_pins` on the actual
  device, not from the schematic or memory.
- *SPI link dead* — no. JEDEC ID reads **EF4018**, exactly right for a W25Q128JV. Reads work.
- *Never leaving idle / request lost* — no. The diagnostic shows the sequencer reaching `S_PP_DATA` and the
  poll states, so the menu action, the CDC handshake and the erase phase all work.
- *Erase not committing (CS never rising)* — was true, now fixed, and the sequencer gets past it.
- *Multiple drivers on the request register* — was true, now fixed.
- *Blank sector vs dead link ambiguity* — resolved by the JEDEC readout. Note this trap: a blank sector reads
  0xFF and so does a floating MISO, so "DEFAULT" alone proves nothing about whether the link works.

**The symptom that was chased** (historical), stated exactly: after the page-program phase, Status Register 1 reads `0xFF`
forever. Bit 0 is the BUSY bit, so the poll never exits. `0xFF` is not a value a working part returns (idle
is 0x00, busy is 0x03) — it means the chip is not driving MISO at that point in the sequence, even though it
answers a JEDEC read issued from a fresh idle state.

**Suspects listed at the time** (all wrong, kept to show what plausible-but-unfounded looks like):
1. Whether the Write Enable Latch is actually set — read Status Register 1 straight after the WREN and look
   for WEL (bit 1). If WEL never sets, the erase and program are both being ignored.
2. CS and clock behaviour around command boundaries — particularly whether `S_DESEL`'s 32-cycle dwell really
   appears on the pin, and whether CCLK through `STARTUPE2` looks clean at the start of each command.
3. Whether the flash is still responding at all mid-sequence, or has been left in a state (e.g. mid-erase
   suspend, or an unrecognised command) where it ignores everything.

**A deduction that was WRONG — recorded because the reasoning looked airtight.** It ran: the only route to
`S_PP_WREN` is the post-erase poll exiting, and that poll only exits on a status byte with bit 0 clear, so
the flash must have returned a real status during the erase poll. The ILA disproved it. On the captured run
the erase poll **never exits** — it loops forever with `rx=0xFF`, which is simply a floating pulled-up MISO.
The logic was valid; the hidden premise, that the earlier on-screen `18FF01` reading and this run behave the
same, was not. **Do not reason forward from a single stale observation across builds.**

### ILA capture results (2026-08-13) — measurement was invalid; MISO had no pull-up

The ILA was worth it, but the first two conclusions drawn from it were **both wrong**, for the same
underlying reason. Recorded in full because the failure mode is instructive.

**What the captures established solidly** (these still stand):
- The SPI master is correct on the wire. `ila_arm_wren` (trigger `do_save`, full rate) shows
  `06` (WREN) → CS high 32 clocks → `20 C0 00 00` (4KB sector erase at 0xC00000) → CS high → `05` (RDSR1).
  `ila_arm_jedec` shows exactly **8 SCK rising edges per byte, uniformly spaced 8 clocks apart**, 128 edges
  across the 16 data bytes, no glitches, CS dwell correct. The sequencer, shift engine and CCLK-via-STARTUPE2
  path all work.
- **The JEDEC ID read works, every single time.** `9F` → `EF 40 18`, repeated on every ~34ms `auto_load`
  cycle, including in the samples immediately preceding a save. The link is alive and not wedged.
- The erase poll **never exits**: 2049 consecutive `RDSR1` reads, all returning `FF`.

**The invalid measurement.** `FLASH_MISO` (K18) had **no `PULLTYPE` constraint**, and the board has no
external pull-up. The flash's DO pin is high-Z whenever it is not actively driving — between commands, and
during the command and address phases of a read. So the FPGA input floated and simply held its last driven
value. **Every 0 or 1 captured on that pin while the flash was not driving means nothing.**

That single defect produced two confident, wrong conclusions:
- *"The block read returns 0x00, and a blank sector cannot read 0x00, so this is evidence of a fault."*
  Wrong. The block read follows the JEDEC ID's last byte `0x18`, which ends on a `0` bit; the line simply
  stayed low. `0x00` was residue, not data.
- *"`S_ID_D2` deasserted CS for only one 8ns clock, violating the part's 50ns tSHSL, wedging the chip."*
  The timing violation was **real and worth fixing** (the fix is in: `S_ID_D2` now routes through `S_DESEL`
  with `cs_dly = 32`, giving 264ns, confirmed on a later capture). But it was **not the cause** — with the
  correct dwell in place the symptom was completely unchanged.

Symmetrically, `rx=FF` on the status poll is *also* uninformative: it is equally "the flash returned 0xFF"
and "the flash drove nothing and the line had drifted high after a long idle".

**The fix to the measurement**, now in `LisaFPGA.xdc`: `set_property PULLTYPE PULLUP [get_ports FLASH_MISO]`.
With that, undriven reads as `0xFF` and anything else is genuine data from the flash. This is an XDC-only
change, so it needs implementation but **not** re-synthesis.

**What to conclude once the pull-up build is captured** (`ila_arm_jedec`, no buttons needed):
- 16 data bytes read `FF` → the flash is not answering `03` at all, even though it answers `9F`. The read
  path is broken, and the save is a downstream symptom.
- 16 data bytes read `00` → the flash *is* driving, the sector genuinely contains zeros, reads work fine,
  and the remaining problem is confined to the erase/program path.

**The transferable lesson, and it is the real one from this whole episode:** before reasoning about what a
signal *means*, establish that the signal is *observable*. A floating input is not a measurement. Two
separate "root causes" were derived from a pin that carried no information, and each looked airtight.


### ROOT CAUSE (2026-08-13): the SCK divider free-ran, so the first byte after every deselect lost its MSB

Found by decoding **MOSI at the SCK rising edges** in the pull-up ILA capture and comparing it against
`tx_byte` — i.e. by reading what the flash actually received rather than what the sequencer intended to send.

| Capture | Byte | Issued from | Intended | On the wire |
|---|---|---|---|---|
| load | 1 | `S_IDLE` | `9F` | `9F` ok |
| load | 5 | **first after `S_DESEL`** | `03` READ | **`06`** |
| load | 6-9 | same burst | `C0 00 00 00` | ok |
| save | 1 | `S_IDLE` | `06` WREN | `06` ok |
| save | 2 | **first after `S_DESEL`** | `20` erase | **`40`** |
| save | 6, 8 | **first after `S_DESEL`** | `05` RDSR1 | **`0A`** |

Every corrupted byte is exactly its intended value **shifted left by one** — MSB dropped, zero appended —
and *only* the first byte of a command issued after a deselect is affected.

**Mechanism.** `clkdiv` was free-running and never aligned to the start of a transfer. `sck_rise` is
`clkdiv==4`, `sck_fall` is `clkdiv==0`. When a byte begins at a phase where `sck_fall` arrives before
`sck_rise`, the falling-edge branch advances MOSI once before the flash has clocked anything, so the MSB is
gone before the first rising edge. Within a burst this never happened, because each byte is exactly 64
clocks = 8 whole divider cycles and the phase is inherited. `S_DESEL` dwells **33** clocks, and 33 mod 8 = 1,
rotating the phase by exactly one.

**Why it hid for nine build cycles.** The JEDEC ID read is issued straight from `S_IDLE`, never after a
deselect, so it always worked and always returned `EF 40 18` — which read as proof the SPI link was healthy.
Everything downstream of it was corrupted:
- `03` (READ) arrived as `06` (WREN) — a legal command with no data phase, so the flash correctly answered
  nothing, stayed perfectly responsive, and the settings block read back as whatever the floating MISO held.
  This is why loads always fell back to DEFAULT.
- `20` (sector erase) arrived as `40` and `05` (RDSR1) as `0A`, both undefined opcodes. So no erase ever
  happened, the status register was never actually read, and the busy-poll spun forever on an undriven line.

**Fix** (`settings_flash.sv`): re-align the divider at the start of every byte —
`else if (xfer_start && !xfer_active) clkdiv <= 3'd1;`. Load **1**, not 0: loading 0 makes the very next
cycle `sck_fall` and reproduces the bug. Starting at 1 gives 1,2,3,4(rise),5,6,7,0(fall), so the first edge
the flash sees is a rising one, with 4 clocks (32ns) of MOSI setup.

**Two lessons worth keeping.** First, the earlier `S_ID_D2` tSHSL fix (CS high for only one 8ns clock) was a
real violation and is still in, but it was never the cause — and *because* `S_DESEL` is 33 clocks, adding it
is what rotated the phase. Second, and more useful: every diagnosis that failed here was made by reasoning
about a signal's *value* (`rx_byte`, MISO) instead of checking what was physically transmitted. Decoding MOSI
against `tx_byte` took one awk pass and settled it immediately.

### ILA setup for the flash debug — built, and used successfully (2026-08-13)

Everything needed to capture this over JTAG is in the tree, and it worked — see "ILA capture results" above
for what it found. Keep it: the same three captures will verify the fix.

- `tools/vivado_scripts/add_settings_ila.tcl` — run once in the Tcl Console. Creates a `settings_ila` IP:
  5 probes, 4096 deep, with `C_EN_STRG_QUAL` on so capture control is available at runtime.
- `settings_flash.sv` gained a `DEBUG_ILA` parameter (default 0) and a generate-guarded instantiation at the
  bottom of the module. 46 bits packed into 5 probes:

  | Probe | Width | Contents |
  |---|---|---|
  | 0 `dbg_state` | 5 | sequencer state (decode table above) |
  | 1 `rx_byte` | 8 | last byte clocked in from the flash |
  | 2 `dbg_bus` | 4 | bit3 flash_cs_n, bit2 sck_r, bit1 flash_mosi, bit0 flash_miso |
  | 3 `dbg_flags` | 6 | bit5 do_save, bit4 busy, bit3 eos, bit2 xfer_start, bit1 xfer_active, bit0 xfer_done |
  | 4 `dbg_misc` | 23 | [22:15] tx_byte, [14:10] byte_idx, [9:4] cs_dly, [3:0] bit_cnt |

  **Five probes, not sixteen, because of a licence limit.** Vivado's BASIC ChipScope licence hard-ERRORS on
  an ILA with more than 5 probes (`[Chipscope 16-620] ... more than 5 probes enabled`) — and it does so at
  the very END of synthesis, after ~4 minutes, so discovering it costs a full run. Probe *width* is not
  restricted, hence the packing. The split is deliberate: `dbg_state` is its own probe (we trigger on it)
  and `xfer_done` is bit 0 of `dbg_flags` (we qualify capture on it), so neither needs a masked compare
  built by hand.
- `top.sv` gained `DEBUG_FLASH_ILA` (default `1'b0`) next to the other build constants, passed down.
- `tools/vivado_scripts/capture_settings_ila.tcl` — source it in the Hardware Manager for
  `ila_probes` / `ila_arm_program` / `ila_arm_wren` / `ila_arm_poll` / `ila_go`.

**The core is instantiated in RTL, not inserted into the netlist via `mark_debug`.** Netlist insertion relies
on constraints binding to net names that survive optimisation, which is exactly the failure mode this project
has hit over and over (see the XDC gotchas). An instantiated core either connects or synthesis errors.

**Why three capture setups rather than one.** A full save spans a ~45ms sector erase = 5.6M clocks at 125MHz,
so no capture depth covers the whole thing. Instead trigger on a phase, and use storage qualification to
store one sample per SPI byte where density matters more than edge detail:
- `ila_arm_program` — trigger on entering `S_PP_WREN`, store on `xfer_done`. The main one: shows the WREN,
  the PP command, address, 16 data bytes, and every status byte the poll then reads.
- `ila_arm_wren` — trigger on `do_save`, store every clock. 32.7us of full-rate detail on CS assertion and
  the first clock edges; this is the one that answers whether the electrical timing is sane.
- `ila_arm_poll` — trigger on `S_POLL_END`, store on `xfer_done`, trigger position mid-buffer so it captures
  polls both before and after. Shows whether the status byte is *ever* anything but 0xFF.

Switching between the three is a runtime property change — **one bitstream covers all of them**, no rebuild.

**Read the ILA first, then decide.** The point of this is to stop inferring. Resist changing RTL on the
strength of the waveform's first surprise; capture all three, then act.
**Historical note on how this was eventually cracked.** Nine build cycles at ~2h each went into inference
and got nowhere. The ILA settled it in one evening — but only once the measurement itself was made valid
(MISO pull-up) and the question was changed from "what did we receive" to "what did we actually transmit".

**Timing note:** every signal crossing out of this module into the pixel domain must be constrained, or WNS
collapses. Naming individual registers meant each newly added signal (`settings_data`, then `jedec_id`, then
`dbg_word`) silently went unconstrained and cost a build cycle. The XDC now constrains the crossing at the
CLOCK level (`sys_clk_pin` <-> the pixel clocks), which covers anything added later automatically.

### Parked: USB keyboard compatibility — full-speed and hub support

**Why Apple (and most modern) USB keyboards don't work.** The USB stack is nand2mario's `usb_hid_host`
(`LisaFPGA.srcs/sources_1/imports/src/usb_hid_host.v`), which is **low-speed only (1.5Mbps)** — the 12MHz `usbclk`
gives 8 samples/bit at that rate. Two independent blockers for Apple keyboards:
- Every Apple USB keyboard with USB ports on it (aluminium A1242/A1243, white A1048, Pro Keyboard M7803) is really a
  **built-in hub** with a keyboard behind it. The core has no hub enumeration at all — it assumes exactly one
  directly-attached device.
- Hubs are never low-speed, so even the outer device is unreachable at 1.5Mbps.

`FAQ.md` already documents this ("neither will any keyboard that has a built-in USB hub") and recommends a specific
cheap Lenovo set, which is what the user has working.

**The board hardware is NOT the blocker** (checked against the rev 3 schematic): each peripheral port has the four
15k pulldowns the spec requires for host-side termination at *either* speed (R97-R100), a USBLC6-2SC6 ESD suppressor
(D9/D10, a few pF, harmless), and 5V VBUS. D+/D- go straight to FPGA pins with **no series resistors** — full-speed
ideally wants ~22-33ohm to match the cable's ~90ohm differential impedance, so signal integrity is the open question,
but direct-to-FPGA full-speed is demonstrably workable (see WangXuan95/FPGA-USB-Device) and a bodge resistor is a
cheap fix if needed. Speed detection works too (the host reads which line the device pulls up). `usbclk` would need
to go 12MHz -> 48MHz, trivial given the spare MMCM capacity, and the FPGA is only ~29% full.

**The blocker is software.** Candidate cores, all of which implement only the *transaction* layer:
- [USB Host Core](https://opencores.org/projects/usb_host_core) — full-speed only, AXI4-Lite, GPL, verified on FPGA
  with hubs/mass storage/network devices. Self-described as "cutdown" and CPU-cycle-hungry.
- [USBHostSlave](https://opencores.org/projects/usbhostslave) — full *and* low speed, all four transfer types, LGPL
  (friendlier licence), FPGA-proven. Caveat from its own docs: *"still needs testing of host mode features related to
  accessing a low speed device via a hub"* — exactly our case.
- [core_usb_host](https://libfpga.com/cores/category/usb) — basic USB 1.1 host, GPL-3.0.

Enumeration — control transfers, hub-class requests (`SET_PORT_FEATURE` for power/reset, `GET_PORT_STATUS`),
downstream connect detection, second-address assignment, HID report parsing — is branchy stateful code normally run
as C on a soft CPU (PicoRV32/VexRiscv, a couple thousand LUTs), not written as RTL. So the work is: drop in a core,
add a soft CPU, write/port the stack, bridge into the existing `usb_keyboard_interface`/`usb_mouse_interface`.
**Note a full-speed upgrade alone does not fix Apple keyboards** — the hub stack is the part that matters, so this
is an all-or-nothing project rather than something that can be done halfway.

Cheaper alternatives if this is ever revisited: an external MAX3421E USB host controller over SPI (well-trodden, it's
what the Arduino USB Host Shield uses, but it's a board change → "rev 4" territory), or simply continuing to use a
low-speed keyboard. **Also worth checking the licence implications** — GPL cores are more viral than USBHostSlave's
LGPL, which matters for how LisaFPGA itself is distributed.

**Suggested first step if resumed:** bring up a host core + soft CPU and try enumerating a *directly attached
full-speed* keyboard before touching hub support. That validates the no-series-resistor signal integrity question on
the real board cheaply, and tells you early whether the physical layer is going to fight you.
### USB full-speed feasibility spike (2026-08-22) -- CONCLUDED, see the next section

**Note the section above is now historical background, not the current state.** The spike described as
its "suggested first step" has been implemented and is waiting on a hardware run.

**A correction worth stating plainly, because it was the premise of the whole question:**
`nand2mario/usb_hid_host` is not a core we could adopt to fix this — **it is already the core LisaFPGA
uses**. It is the limitation, not the remedy.

**What made the spike far cheaper than the soft-CPU project.** Low-speed and full-speed USB are
protocol-identical: same NRZI, bit stuffing, SYNC and SE0 EOP. They differ in rate and in **idle
polarity** — full-speed idle (J) is D+ high, low-speed is D- high. And this core decodes NRZI from its
internal `dmi` *alone*, not differentially, i.e. `dmi` is "the line that idles high". So the entire
polarity difference collapses to **swapping D+/D- at the two pin boundaries** — where inputs are
sampled, and where `up`/`um` drive the outputs. Everything between is untouched. Marked in the source
as SWAP POINT 1 of 2 and 2 of 2.

**Speed is set purely by the clock**, because the core samples 8x per bit: 12MHz/8 = 1.5Mbps,
96MHz/8 = 12Mbps.

**Clocking — the arithmetic was done up front, per the 1024x768 lesson.** `clock_divider` cannot
produce 96MHz: its VCO is 626.5625MHz and 96MHz needs a divide of 6.527. A dedicated MMCM can, exactly:
`CLKFBOUT_MULT_F 36.000, DIVCLK_DIVIDE 5` gives VCO 900MHz, and the **fractional** output divide
`CLKOUT0_DIVIDE_F 9.375` gives **96.0000MHz = 12.0000Mbps, +0.0000%** (confirmed on the generated IP).
The fractional divider is the key: an analysis considering only integer output dividers concludes
exact 96MHz is unreachable from 125MHz and settles for -0.0186%, which is wrong and needlessly spends
a third of the error budget. That matters because **full-speed hosts must hold 12Mbps to +/-0.05%**,
where low speed allowed +/-1.5% and forgave everything. `add_usb_fs_clock.tcl` computes the achieved
figure from the MMCM dividers and **fails loudly if it is out of spec**, rather than leaving it as a
manual check the way `add_1024x768_clocks.tcl` did.

**Build constants in `top.sv`:** `USB_FULL_SPEED` (default 0) and `DEBUG_USB_ILA` (default 0). The
clock is selected in a *generate*, not a BUFGMUX, so a `USB_FULL_SPEED = 0` build instantiates no
extra MMCM and no extra BUFG and is identical to stock — which matters, because BUFGCTRL is at 29/32.

**Both ports share one usbclk**, so a full-speed build runs BOTH ports at full speed and low-speed
keyboards/mice will NOT work in it. Fine for a test build; keep the constant at 0 for real use.
Supporting both at once means clock-enable dividing off the 96MHz clock — a later refinement.

**A `dbg_usb` output was added** exposing `{connected, state[3:0], pc[13:0]}`. `pc` is the microprogram
counter into `usb_hid_host_rom`, so it distinguishes "it did not work" from "it stalls at instruction
N" — the same reasoning behind `dbg_word` in `settings_flash`.

**Declaration-order cleanup:** `dpi`, `dmi`, `ukprdyd` and `nakd` were moved to the top of `ukp`. They
were used far above their original declarations, which Vivado synthesis tolerates with a warning but
**xvlog rejects outright** — meaning the file could not be syntax-checked without an 85-minute
synthesis run. `xvlog` ships with Vivado at `Vivado/bin/xvlog.bat` and now parses both changed files
cleanly. **Use it as a pre-build check**; it costs seconds and this project's build cycle does not.

**What the capture will tell us** (`tools/vivado_scripts/capture_usb_ila.tcl`):
- **Idle polarity, first.** With a device attached and the bus idle, `dp_in=1 / dm_in=0` means it
  attached as full speed; the reverse means low speed. That single reading says whether the device is
  even offering the speed being tested.
- **Edge quality.** D+/D- go straight to FPGA pins with **no series resistors** (full speed normally
  wants ~22-33 ohm against the cable's ~90 ohm differential impedance). Ringing or inconsistent
  sampling at the 8x points means the board needs bodge resistors — a cheap fix, and a decisive
  finding for any future rev 4.
- **How far enumeration gets**, from `pc` and `conerr`.

**Deliberately NO PULLTYPE on the USB pins.** The board has the 15k pulldowns the spec requires, and
the *device's* pull-up on D+ (full speed) or D- (low speed) is what declares its speed. An FPGA
pull-up on either line would look like a device attaching and break speed detection. The
settings-flash episode ended with "always pull up a floating input" — **that lesson does not transfer
here.**

**This is not expected to make Apple keyboards work.** They need hub enumeration, which this core has
none of. The spike exists to settle the physical-layer question before committing to the soft-CPU
project — and to find out cheaply if the board itself rules it out.


### USB: spike concluded, m1nl fork adopted (2026-10-04) -- integrated, built, low-speed regression PASSED

**The spike's verdict.** On a full-speed build of the original core, ILA captures at the FPGA pins showed
everything on the host side correct: attach detected, a 10ms bus reset, 40ms of keep-alives, then a SETUP
transaction that decodes byte-perfect -- SETUP `2D 00 10` (address 0, endpoint 0, CRC5 `0x02`), then
DATA0 `C3 80 06 00 02 00 00 18 00 A2 54` (GET_DESCRIPTOR, configuration, 24 bytes; CRC16 `0x54A2`
recomputed independently and matching), at exactly 12.0000Mbps with every run an exact multiple of the
bit time. Yet neither an Apple keyboard (whose built-in hub IS full speed) nor a USB flash drive plugged
in with no cable ever sent an ACK. **Cause: the original microcode sends low-speed keep-alive EOPs, never
SOF tokens, and full-speed devices need a SOF every 1ms.** Found by research, not by a build: the
m1nl fork of the same core (below) documents exactly that requirement. Signal integrity was a credible
suspect until the cable-less flash drive failed identically.

**A real bug the spike found and fixed along the way:** the original core counts every real-time delay
in clock cycles -- a fixed 12002-clock frame (1ms at 12MHz) and a 2^23-clock watchdog (~700ms). Clocked
8x faster for full speed, the 10ms bus reset became 1.25ms and the watchdog 87ms. USB specifies those
delays in absolute time, so they must not scale with bit rate. The m1nl core gets this right
(`interval == (FULL_SPEED ? 60000 : 12000)`).

**Rules learned the hard way during capture, all of which cost at least one round trip:**
- **Reprogramming the FPGA always brings the emulated Lisa up switched OFF, and USB is held in reset
  until it is switched on.** The cores' reset is the Lisa's `_RESET`, which is generated on `DOTCK`, which
  the Lisa's power switch gates. Symptom: both ports frozen at `pc = 0` with the error flag pinned high.
  Turn the Lisa on after every JTAG load before expecting any USB activity.
- **USB1 is port 0** (the `MOUSE_DP/DN` connector) and **USB2 is port 1** (`KBD_DP/DN`).
- **ILA probe names come from the source nets, not the packed bus names.** Concatenating signals into
  an ILA input makes Vivado's `.ltx` name each bit after its net (`usb_dp_in_port1`, ...); the packed
  names in `add_usb_ila.tcl` never exist at runtime.
- **An empty USB port is not quiet**: both lines sit low on the 15k pull-downs, so "D+ is low" is
  already true. Triggers must be conditions only a present device can create.
- **After a fetch, Hardware Manager drops its probe association** and the next `run_hw_ila` fails with
  "Use refresh_hw_device command, with a valid [debug_nets.ltx]". `capture_usb_ila.tcl` now does a full
  refresh at the start of every arm (`_ureset`) -- but NOT in `usb_status`, where a full refresh could
  knock an armed core out of its waiting state.
- **Storage qualification gives milliseconds of history from a 4096-sample buffer**: qualify on
  `oe = 1` and only host-driven samples are stored (`usb_arm_history`). That is how the reset and the
  40 keep-alives were seen. It shows order and count, not durations.

**The fork: [m1nl/usb_hid_host](https://github.com/m1nl/usb_hid_host)**, Apache-2.0, copyright
nand2mario (2023) and Mateusz Nalewajski (2026); imported at commit `e492176`, files unmodified. One
60MHz core detects per device whether it is full speed (5x oversampling) or low speed (a /5 prescaler
giving 8x), sends SOF every 1ms at full speed, and is proven on hardware (EBAZ4205) with an 8BitDo
controller, a Logitech keyboard and others. **No hub support** -- Apple keyboards with ports still will
not work (see "Hub support" below).

**Integration** (all in `top.sv` unless noted):
- `usb_hid_host.v` and `usb_hid_host_rom.mem` replaced in place with the fork's. `usb_hid_host_rom.v`
  keeps its filename (so the `.xpr` needs no edit) but now holds the fork's **dual-port** microcode ROM,
  one read port per core, as in the fork's own `usb_hid_host_dual` reference design.
- **Two clock domains.** The cores run on `usbclk_core`: 60MHz from `usb_fs_clock` when
  `USB_FULL_SPEED = 1`, else the 12MHz from `clock_divider` (a low-speed-only fallback). The Lisa-protocol
  modules `usb_keyboard_interface` / `usb_mouse_interface` stay on the **12MHz `usbclk`, untouched**,
  because their timing is in 12MHz cycles (keyboard serial bit times 188/258/369, mouse quadrature step
  6000) and at 60MHz the Lisa keyboard protocol would run 5x too fast.
- Reports cross 60MHz -> 12MHz through **`xpm_cdc_handshake`** (the design's first use of XPM). Each
  report is **latched on its `full_report` pulse** first, because the core's key/mouse outputs are a live
  decode of a receive buffer that is rebuilt byte by byte as the next report arrives, then copied into a
  transfer register so `src_in` stays stable for the whole handshake.
- **The keyboard/mouse port is remembered**, not chosen from `typ` each cycle, so the empty report the
  core sends on a connection error still reaches the Lisa and releases held keys on unplug.
- **The core's reset is ACTIVE-HIGH** (the original's was active-low), synchronised into `usbclk_core`.
- `key_0` feeds the Lisa side's single keycode; `mouse_btn` is 3 bits, zero-extended to the old 8.
- ILA kept (same IP, same five probe widths). Its two 19-bit debug probes now carry each port's **VID**
  (from `dbg_hid_regs`): non-zero means the device descriptor was read. `usb_arm_enum` triggers on it.
- XDC: `usbclk_clock_divider` (the 12MHz) added, by exact name, to the async group with `usbclk_fs*`;
  a false path into the new reset synchroniser's first stage.
- `add_usb_fs_clock.tcl` retargeted to **60MHz** (900MHz VCO / 15 expected) with the same accuracy check.

**To build and test:**
1. `source tools/vivado_scripts/add_usb_fs_clock.tcl` -- reconfigures `usb_fs_clock` from 96 to 60MHz.
   Check it reports OK.
2. Build with `USB_FULL_SPEED = 1` (and `DEBUG_USB_ILA = 1` for bring-up). Verify `usbclk_fs*` resolves at
   60MHz, `usbclk_clock_divider` exists, and no cross-domain rows appear between them.
3. Program over JTAG, **turn the Lisa on**, then test:
   - **Regression first: the low-speed Lenovo keyboard and mouse must still work** on both ports.
   - Then a **full-speed HID device** -- a gaming keyboard or mouse, or a wireless receiver; Logitech
     Unifying receivers are full speed. `usb_arm_enum` shows whether its VID is read.
4. Only then restore production directives and consider the flash.

**Build and first hardware results (2026-10-04).** Integrated build: 0 errors, WNS +0.245 / WHS +0.084, 0 failing
setup/hold endpoints, only the 10 known 1080p60 pulse-width entries. `usbclk_fs_usb_fs_clock` = 60.000MHz,
`usbclk_clock_divider` = 12.049MHz, no inter-clock rows for either. **Low-speed regression passed: the Lenovo
keyboard and mouse work on both ports.** A wired full-speed gaming keyboard (via a USB-C-to-A cable) enumerated
and typed -- the first full-speed device ever to work on this board -- but dropped keystrokes.

**Dropped keystrokes = rollover, FIXED in `usb_keyboard_interface.sv` -- confirmed on hardware 2026-10-04 (the
gaming keyboard no longer drops keys; the Lenovo is still fine).** The Lisa side
only ever looked at the first keycode slot, `key1`: pressing a second key before releasing the first sent no
release for the first and never sent the second at all. Low-speed keyboards are polled every 10ms, so a fast
typist's overlaps were often missed between polls; full speed polls every 1ms and sees nearly all of them, which
is why the Lenovo seemed fine and the gaming keyboard did not. Now:
- All six keycodes cross the CDC (`kbd_hold` is 56 bits: `{modifiers, key_5..key_0}`) into a `keys_in[47:0]` port.
- The decoder keeps `prev_keys[6]`, the set of keys the Lisa has been told are down, and compares **sets, not
  slots** (a held key can move slots between reports). `HANDLE_REGULAR_SCAN` sends releases first, then presses,
  one event at a time through the existing `lisa_keycode`/`FINISHED` handshake, re-diffing against the live
  report on every pass so a report that lands mid-sequence is merged in rather than lost.
- Reports whose first keycode is `0x01` (ErrorRollOver, too many keys) are ignored entirely; codes below `0x04`
  are never treated as keys. Modifier handling and the serial timing are unchanged.
- Verified in xsim (`xvlog`/`xelab`/`xsim` ship with Vivado; a 25ms testbench runs in seconds): rollover, a slot
  swap (no events), ErrorRollOver (ignored) and three reports 10us apart all produce the correct sequence.
- **Caps Lock was inverted -- a pre-existing upstream bug, now fixed -- confirmed on hardware 2026-10-04.**
  Seen on hardware: the first press gave lower case. The handler toggles `caps_lock_state` on its first cycle but
  rebuilt bit 7 from `~caps_lock_state` on every cycle, so once the toggle landed it sent the OPPOSITE of the new
  state (caps on -> "Caps up"). Bit 7 now uses `~caps_lock_state` on the first cycle and `caps_lock_state` after.
  The testbench shows `FD` (down) on the first press and `7D` (up) on the second.

**Key repeat starts too soon when overclocked -- upstream behaviour, NOT a USB issue, left alone.** The Lenovo and
the gaming keyboard both show it. The Lisa keyboard has no auto-repeat; the Lisa software repeats a held key and
appears to time that in vertical-retrace ticks. LisaFPGA generates the Lisa's video timing, and so `_VSIR`, on
`DOTCK` (`CPU_board.sv` ~line 1196), which the SPEED SELECT switches set to 20/40/60/75MHz -- so the retrace
interrupt runs up to 3.75x faster (~225Hz) and every tick-timed delay shrinks to match. HDMI hides this because it
has its own timing. **Confirmed: with the CPU dialled back, repeat is normal on both the Lenovo and the Keychron.** Pinning the interrupt to 60Hz would
decouple it from the video timing software expects -- the same class of overclock issue the README handles by
patching MacWorks Plus rather than the hardware.

**Keychron 2.4GHz receiver (VID 3434, PID D030) does not work, and is parked.** It is a composite device with four
interfaces: MI_00 mouse, MI_01 game/vendor, MI_02 keyboard, MI_03 vendor. The core enumerates only the first
interface, so it would find a mouse, not the keyboard; supporting it needs the microcode to pick the keyboard
interface. The fork's README also lists composite receivers (8BitDo) as not working.

**Hub support (the actual Apple-keyboard goal) remains a separate project.** It needs full speed (which
this provides), then hub enumeration: address the hub, power its ports, poll its status endpoint, reset
the port a device appears on, and enumerate that device at a second address. Either extend the microcode
for one hub and one device, or run a C USB stack on a soft CPU. If the keyboard behind an Apple hub is
**low speed**, the host must also send a PRE packet before each low-speed transaction -- neither core does
that, so it would need RTL work in the bus engine. True high speed (480Mbps) is not an option and not
needed: it requires an external ULPI PHY, and high-speed hubs fall back to full speed on a full-speed host.

### Parked: a second display, a 1920x1280 3:2 panel (10.5", HDMI driver board)

Explicitly on hold until 1024x768 is validated — do not start this until the user says so.

Discussion so far, for whenever this resumes:
- The driver board's exact input timing (pixel clock, porches, sync widths) is still unknown — unlike
  1024x768 (a universal VESA DMT standard), 1920x1280 has no standard timing table, so real
  implementation needs either the driver board's datasheet or a way to read its EDID. **First step when
  resuming: get the driver board's model/spec, and/or just try the current stock 1080p output on it —
  many of these boards have their own scaler and might already work with zero FPGA changes.**
- If it does need a custom native 1920x1280 mode, three scaling options were discussed for the H-ROM
  image (720x364 native):
  - **Stretch to fill exactly** (2.667x horiz / 3.516x vert independently): zero bars, zero cropping,
    but ~12-14% aspect distortion (image looks slightly wider/flatter than correct proportions).
  - **Uniform zoom to fill height, small side bars** (2.344x horiz / 3.516x vert, proportions
    preserved): ~116px left/right bars, 0px top/bottom. **This is the option the user picked**, over
    the stretch option, once they understood the quality tradeoff (see below).
  - **Uniform zoom to fill width, crop top/bottom**: rejected — risks clipping the Lisa's menu bar.
- Quality note (came up because the user asked): both integer and fractional nearest-neighbor scaling
  keep edges perfectly sharp (no blur/interpolation, ever) — the difference is that a true integer
  scale (like the current 2x/3x for 1080p) replicates every source pixel into an identical-sized block
  everywhere (zero irregularity), while a fractional/LUT scale (like 1024x768's 4/3 horizontal, or the
  2.344x/3.516x this panel would need on *both* axes) has some source pixels repeated one extra time
  vs. their neighbors — a mild, non-blurry unevenness, most visible (if at all) on thin lines/fine text
  strokes.
- Implementation-wise, filling-to-height for this panel needs **two** new LUTs (horizontal AND
  vertical), unlike 1024x768 which only needed one (vertical was already a clean integer 2x there).
  Not fundamentally more complex, just double the new lookup tables.
