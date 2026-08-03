# LisaFPGA — Project Notes for Claude

## Current work: adding a selectable 1024x768@60Hz HDMI output mode

**Branch:** `feature/1024x768-hdmi-output` (created off `main`, not yet merged or pushed)

**Why:** The user has a 1024x768 display and wants LisaFPGA's HDMI output to support it natively
(properly scaled/centered) instead of relying on the display's own upscaling of the stock 1080p signal.

### What's implemented (uncommitted changes on the branch)

A single build-time constant, `localparam logic OUTPUT_1024X768` near the top of
`LisaFPGA.srcs/sources_1/imports/lisaStuff/top.sv` (default `1'b0`), controls everything. Flip it to
`1'b1` and rebuild to get the new mode — no other source edits needed for a rebuild.

**Key design point — the HDMI FRAMERATE jumper does double duty:**
- Jumper's "first" position (`framerate_sel = 0`): **always** 1080p30, regardless of `OUTPUT_1024X768`.
  This is a deliberate fallback — an `OUTPUT_1024X768` build can still show a working 1080p30 picture
  if you need to temporarily plug into a 1080p-capable display.
- Jumper's "second" position (`framerate_sel = 1`): 1080p60 in a stock build, or the new fixed
  1024x768@60Hz VESA output when `OUTPUT_1024X768 = 1'b1`.
- The BUFGMUX-based clock mux is always instantiated (not synthesis-time-bypassed); only its second
  input, and what `video_id_code`/frame timing that maps to, changes based on the constant.

**Files touched:**
- `top.sv` — the `OUTPUT_1024X768` constant, passed down to `HDMI_Interface`.
- `HDMI_Interface.sv` — clocking (BUFGMUX with a build-time-selected second input), video_id_code
  selection, the H-ROM scaling/centering logic for 1024x768 (960x728 image, 32px L/R + 20px T/B
  borders, via an exact 2x vertical line-double + a `hscale_lut` 4/3 horizontal repeating-pattern LUT),
  and a 3A-ROM stopgap (simple centered 1:1, **not** properly scaled — flagged as a follow-on).
  Clocking-wise, there are now **two** MMCMs here: the original `hdmi_clock_divider` (stock 1080p30/
  1080p60 clocks, untouched) and a new dedicated `hdmi_clock_divider_1024x768` (65MHz pixel / 325MHz
  5x TMDS), each with its own external feedback BUFG loop. See "A subtlety worth remembering" below
  for why the 1024x768 clocks couldn't just be two more taps on the existing IP.
- `LisaFPGA.srcs/sources_1/imports/hdmi/hdmi.sv` — frame timing (`frame_width`/`screen_width`/sync
  pulses/etc.) is now derived at runtime from `video_id_code` (16=1080p60, 34=1080p30, 0=1024x768 VESA
  DMT "no CEA data" sentinel) rather than hardcoded — this is what makes the jumper-runtime-switch work.
- `LisaFPGA.srcs/constrs_1/imports/lisaStuff/LisaFPGA.xdc` — pixel-clock group exclusivity, a `clk_audio`
  generated-clock constraint, and a `CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN` relaxation on the 1024x768
  MMCM's output nets (it isn't explicitly LOC'd near the OSERDES the way `hdmi_clock_divider` is).
  **Read "Vivado/XDC gotchas" below before touching this file** — several constraints here were silently
  not applying for a long time, and the XDC has real restrictions that fail quietly.
- `tools/vivado_scripts/add_1024x768_clocks.tcl` — **required one-time manual step**, see below.
- `README.md` / `FAQ.md` — updated to document `OUTPUT_1024X768` and the jumper's new dual meaning.

**A subtlety worth remembering (audio clock):** 74.25MHz (1080p30) and 148.5MHz (1080p60) share a clean 2x ratio,
which is why the stock audio-clock divider can use one fixed threshold (772) clocked off a fixed
74.25MHz reference regardless of which framerate is live. 65MHz (1024x768) has no such clean ratio to
74.25MHz, so in an `OUTPUT_1024X768` build the audio counter instead runs off the actual muxed
`clk_pixel` and dynamically switches its threshold (772 vs. 677) based on the synchronized jumper
state — see `gen_audio_clk_stock` vs. `gen_audio_clk_1024x768_fallback` in `HDMI_Interface.sv`.

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
frequencies are meaningfully off 65.000/325.000MHz, or the ratio isn't exactly 5, the audio-divider
threshold (`12'd677` in `HDMI_Interface.sv`) and the XDC's `-divide_by 1354` would need recomputing to
match. **Already confirmed correct on this project's actual build**: VCO = 125MHz × 39.000/5 =
975MHz, giving CLKOUT1 (`MMCM_CLKOUT0_DIVIDE_F=15.000`) = 975/15 = exactly 65.000MHz, and CLKOUT2
(`MMCM_CLKOUT1_DIVIDE=3`) = 975/3 = exactly 325.000MHz — a perfect, error-free 5:1 ratio. That's what
justified changing the audio threshold from an earlier "676-ish" guess to the exact `677`
(65000000/(2×48000) = 677.08) above.

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

**Still untested on hardware:** the 1080p30 fallback jumper position, and audio in either position.

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
- One last pre-existing hold violation (`SPEED_SEL_dotck_reg[1]` -> `dotck_final_mux/CE0`, ~-0.23ns) was
  cleared by false-pathing the three DOTCK clock muxes' CE pins, mirroring what the XDC already did for
  the HDMI framerate mux. This is unrelated to 1024x768 and applies to stock builds too.

**Test plan:**
1. Run `tools/vivado_scripts/add_1024x768_clocks.tcl` (one-time) and verify the achieved frequencies/
   ratio as described above.
2. Flip `OUTPUT_1024X768` to `1'b1` in `top.sv`, and swap the `clk_audio` constraint in the XDC to the
   1024x768 variant (see the comment block on it — this is manual, XDC can't branch).
3. Synthesis → Implementation → Bitstream, then generate `top.mcs` — note the bitstream run does NOT
   produce the .mcs, that needs a separate `write_cfgmem` (flash size not yet confirmed; `program_board.sh`
   expects the result at `LisaFPGA.runs/impl_1/top.mcs`). Check the Timing Summary as described above.
4. Copy `top.mcs` back to the Mac, program via `program_board.sh` or
   `openFPGALoader --cable ft232 --fpga-part xc7a100tcsg324 --write-flash <path>/top.mcs`.
5. Test **both** jumper positions against the 1024x768 display: first position should show 1080p30
   (fallback works), second position should show 1024x768@60Hz, centered, with ~32px/~20px borders, no
   rolling/tearing. **Check audio in both positions** — that's the main functional risk introduced by
   the dynamic audio-clock-threshold rework.

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
