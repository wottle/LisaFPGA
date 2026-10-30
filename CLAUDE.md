# LisaFPGA — Project Notes for Claude

## Current state (2026-10-25) -- read this first

**Git:** `fork/main` = `feature/lisanet-control` = `0720258` plus the commit adding this status (pushed to `mine` =
github.com/wottle/LisaFPGA). Alex's
upstream untouched. ESFloppy fork `main` = `bc71bad`, ESProFile fork `main` = `81f33f3` (both pushed, unchanged since
2026-10-16).

**On the board (all in flash, cold-booted):**
- FPGA: the FujiNet build (control version 3) -- `fpga_fujinet_2026-10-22.{bit,mcs}` in `tools/esp32_wifi_test/backup/`,
  and now also the COMMITTED `LisaFPGA.runs/impl_1/top.{bit,mcs}` (commit `9a3119d`). WNS +0.589 / WHS +0.048.
- ESFloppy: LisaNet firmware (OLED guard + floppy remote), `bc71bad`. ESProFile: LisaNet firmware, `81f33f3`.
- XIAO: **0.18 installed and working** (user, 2026-10-30), matching the source. 0.18: the AI chat's reply timeout
  was really ~4.5 s -- `HTTPClient::setTimeout()` takes a **uint16_t** of ms, so the old 70000 wrapped to 4464; now a
  web setting *Reply timeout* (NVS "tmo", default 60, 10-65 s, 65535 ms being the ceiling) and a clear
  `[error: no answer within N s ...]` message. Long answers confirmed working. **Any `setTimeout` on this core's
  HTTPClient must stay <= 65535 ms** (fujinet.cpp uses 10000, fine). 0.17: `drivecache.cpp` reads the
  floppy images ESFloppy's drive accepts in the background (Normal mode only, one folder per step, only after 3 s with
  no FujiNet traffic, growing backoff when ESFloppy does not answer) and keeps them; `/api/drive/images` (GET; POST =
  Rescan) feeds the Insert a disk dialog instantly. Dropped when the drives leave Normal (re-read ~12 s after returning)
  or the drive type changes. NOTE: after git checkout these sources have CRLF line endings, so `perl -0pi` patterns
  ending in `\n` silently fail to match -- use the Edit tool (or `\r?\n`) and check that each change applied.
  0.16: Lisa programs can set the FujiNet
  speed (LisaFuji 1.2 and siblings POST `serial_baud=` then `resetfuji=` to `http://<adapter IP>/config`, the real FujiNet
  web form; `fujinet.cpp` answers its OWN /config itself, since the XIAO's single-task web server cannot answer a
  request the same task is making; the speed switches after the reset's CLOSE reply; not saved until Save settings),
  plus NET_SET_HTTP_MODE (0x4D, param 1: mode 4 post data, 3 headers). The user's XIAO came from the *Seeed Studio XIAO
  ESP32S3 & Wio-SX1262 Meshtastic LoRa Dev Kit* (Amazon a.co/d/00z6Lj4b): only the XIAO is used, with the kit's 2.4 GHz
  antenna (the LARGER of its two, shipped on the XIAO; the small rectangular one is the LoRa board's); it ships pre-flashed with Meshtastic (hence the manual B+R download mode on the first flash). Noted in
  `firmware/lisanet_wifi/README.md`'s parts list.

**Done 2026-10-25:**
- Committed the production bitstream (the repo had been shipping the 10-07 build to `program_board.sh` users).
- `program_board.sh` now builds ESProFile/ESFloppy from wottle's forks (`ESPROFILE_REPO` / `ESFLOPPY_REPO` at the top;
  `get_firmware_repo()` repoints an existing clone of Alex's and resets it to the fork's `main` -- tested on a fresh
  Alex clone; Windows "Filename too long" errors in that test came from Alex's Gerber paths, the script runs on
  macOS/Linux only).
- Docs: the user's `docs/lisanet_setup.md` (bare board -> WiFi, end to end) lost its two manual workarounds; README
  "About This Fork" and the Programming section name the forks; `firmware/lisanet_wifi/README.md` says the LisaFPGA
  power switch powers the XIAO through J21 pin 8 (with a USB-C alternative), and that the FujiNet is tested at **9600
  and 19200 baud only** (the card offers up to 115200).

**AI chat (XIAO 0.12-0.15, 2026-10-22, written in another session; documented in `firmware/lisanet_wifi/README.md`,
"AI chat for Lisa programs"):** `chat.cpp` / `chatcore.cpp` / `chat_roots.h`. A Lisa program OPENs `chat://claude`,
`chat://openai` or `chat://` on any N: unit, WRITEs a question, and STATUS/READs the answer (errors come back as
`[error: ...]` text). API keys live on the XIAO (Settings tab "AI chat" card); **off by default** (0.14), certificates
verified against pinned roots (0.13, needs NTP time), a STATUS straight after OPEN waits for the WRITE (0.15, for
LisaFuji's FnNOpen). Host test: `firmware/lisanet_wifi/test/test_chatcore.cpp` (needs g++, not on this machine).

**Open / next:** nothing in progress. Possible: suggest the OLED guard to
Alex (user's OK pending); test the FujiNet above 19200 if wanted; the pre-existing `frame_width` 1-bit bug and the
thermal margin (85-86 C without a fan, fan planned) below.

## LisaNet history (ESP32 WiFi mode) -- FPGA side built 2026-10-11, the XIAO firmware since; kept for the reasoning

**Status (2026-10-25): LisaNet is built and merged into `fork/main`; the board runs the FujiNet build.** The original
`feature/esp32-wifi-mode` branch (menu toggle on the ESFloppy ESP32, spec
`docs/superpowers/specs/2026-10-10-esp32-wifi-mode-design.md`) was fully merged; its local branch and worktree are gone.
The rev 3 ESP32s have no antenna (see BLOCKER below), so the shipped design is an external XIAO ESP32-S3 on header J21.
**To set up a board from scratch (flash the FPGA with `program_board.sh`, flash and wire the XIAO, join WiFi), follow
`docs/lisanet_setup.md`;** XIAO details are in `firmware/lisanet_wifi/README.md`. Since 2026-10-25 the committed
`LisaFPGA.runs/impl_1/top.mcs` / `top.bit` are the flashed FujiNet build (byte-identical to
`tools/esp32_wifi_test/backup/fpga_fujinet_2026-10-22.{bit,mcs}`), and `program_board.sh` builds ESProFile/ESFloppy from
wottle's forks (`ESPROFILE_REPO` / `ESFLOPPY_REPO`; an existing clone of Alex's is repointed and reset to the fork's
`main`). **Rule: whenever an FPGA build is flashed and confirmed on the board, commit its `top.bit`, `top.mcs`, `top.prm`
and the tracked impl_1 reports** (`git add -u LisaFPGA.runs`) -- `program_board.sh` flashes the committed `top.mcs`, and
for most of October it silently shipped the 10-07 build while the source had moved on. Vivado's `reset_run` deletes
`top.mcs` (it is made by `write_cfgmem`, not the run), so regenerate or copy it from the backup before committing.
The history below is kept for the reasoning.

**Windows progress (2026-10-10).** Built in the main checkout (`LisaFPGA` dir, branch checked out there), not a fresh
clone: its IP state from the earlier USB/HDMI builds is already in place, so the one-time `tools/vivado_scripts` setup
was not needed. `xvlog` on `top.sv` and `HDMI_Interface.sv`: **clean, no edits needed**. A full-project RTL elaboration
(`synth_design -rtl` in batch, ~2 min -- a cheap check of every cross-file port, width and driver before an 85-min
synthesis) was also clean apart from pre-existing warnings. `ESFLOPPY_COMM_BUS` is `inout` in `top.sv`, so reading [5]
undriven is legal (input buffer only). Production build launched in batch Vivado (runs detached; build results below
once in).
**Build result (2026-10-11, production settings, ~1.5 h): WNS +0.125 / WHS +0.060, 0 failing setup/hold endpoints,
only the 10 known 1080p60 pulse-width entries; 22367 LUTs (the WiFi logic is ~36 LUTs), 41 BRAM.** 30 critical
warnings, the same pre-existing set (24 are unused-pin `set_property` lines 6-13 / 587-602); none on the new XDC lines.
Verified BY EFFECT on `top_routed.dcp`: the paths into `esp_mode_sys_int_reg` and `esp_mode_dot_int_reg` come from
`clk_pixel_1080p60` with EXCEPTION = False Path (no slack computed); `ESFLOPPY_COMM_BUS[5]` has PULLTYPE PULLUP and its
only cell is an IBUF (nothing in the FPGA can drive it); [3]/[4] are plain OBUFs. `report_power`: **1.53 W** (MMCM
0.55 W for five) vs upstream's 1.18 W.
**JTAG hardware test (2026-10-11): PASSED.** The menu shows all 8 rows, ESP32 MODE toggles FLOPPY/WIFI, and the other
menu items behave as before. Still to do: flash, then SAVE SETTINGS with WIFI + power-cycle to prove bit 72 persists.
**WiFi serial link: WORKS END TO END (2026-10-11).** `tools/esp32_wifi_test/` is a small AI-written ESP32 test program
(MODE watcher + 9600 8N1 UART on GPIO38 RX / GPIO39 TX + echo; see its README) flashed on the ESFloppy ESP32 in place of
ESFloppy, after a full 8 MB flash backup (read twice, identical, SHA-256 `0e075415...`; `tools/esp32_wifi_test/backup/`,
git-ignored; restore = one `esptool write-flash 0` command). With the JTAG-loaded WiFi build, selecting WIFI produced
`[mode] WIFI` on the ESP32 console (bus[3]), LisaTerminal on Serial A showed the ESP32's banner (bus[5] via the pull-up),
and 28 typed bytes arrived clean and were echoed back to LisaTerminal (bus[4] and the SCC RXD mux) -- no framing errors.
Tooling now on the Windows machine: arduino-cli 1.5.1 (`tools/toolchain/arduino-cli`, digest-verified) and the ESP32
Arduino core 3.3.12 with esptool 5.3.1 (`%LOCALAPPDATA%\Arduino15`). ESP32 ports on this machine: **COM4 = ESFloppy**
(MAC ac:a7:04:04:78:94), **COM3 = ESProFile** (ac:a7:04:04:78:98) -- identified from firmware strings; recheck, numbers
can move. **Lesson: do not read ESProFile's flash with esptool unless you mean to.** A read resets the chip; one aborted
read ("Packet content transfer stopped") left ESProFile unresponsive and the Lisa then hung at boot until ESProFile was
reset by hand. ESFloppy is identified safely the same way, but leave ESProFile alone.
**ESFloppy restored and the WiFi build flashed (2026-10-11).** ESFloppy: the 8 MB backup written back with esptool, hash
verified. FPGA: `top.mcs` from this build written at 3 MHz JTAG with `use_file` (erase + program/verify OK), driven from
batch Vivado on this machine -- no GUI needed. After a flash write the FPGA is running Vivado's flash loader, so a cold
power cycle is needed to boot the new design. **Cold boot from flash: PASSED** -- the saved settings came back (so
`use_file` left `0xC00000` alone), and **ESP32 MODE persists across a power cycle** (settings bit 72 works). Every FPGA-side
step of the WiFi-mode brief is now done on hardware; what remains is the ESP32 WiFi firmware (open), flow control (O2)
and the LisaNet Lisa app.
**BLOCKER FOUND (2026-10-11): the rev 3 board's ESP32s have NO ANTENNA.** The phase-1 WiFi firmware (local repo
`Development\ESFloppy`, upstream clone + `wifiMode.cpp/.h` + hooks in `ESFloppy_Main.cpp` and `SDTask.cpp`; uncommitted)
works -- boot-time personality choice, MODE watcher with safe disk-image close, AT command set on Serial A -- and `AT`
answers `OK` from LisaTerminal. But `AT+WSCAN` finds 0 networks, and the PCB netlist explains it: **pin 1 (`LNA_IN`, the
ESP32-S3's only RF pin) has no net on either ESP32** -- U19 (ESFloppy, PCB id `e500`; its pins 39-44 are
`FPGA_0..5_ESFLOPPY`) and U16 (ESProFile, `e497`). No antenna, no matching network, no trace: the radio cannot work on
this board as built. Everything else in the WiFi-mode design (menu row, MODE line, Serial A mux, firmware personalities)
is proven; only the RF path is missing. Options being considered: an external antenna-equipped ESP32 board on a spare
header, an RS-232 WiFi modem on the physical Serial A, a bodge antenna on U19 pin 1, or an antenna on a future board rev.
**Decision (2026-10-11): option B** -- an external XIAO ESP32S3 (antenna) on J21 does WiFi; ESFloppy's ESP32 becomes its
SD-card server over a fast link wired through the FPGA (no SCC). J21 = 2x4: pin1 GPIO0, 2 GPIO4, 3 GPIO1, 4 GPIO5, 5 GPIO2,
6 GND, 7 GPIO3, 8 3V3 (no 5V). WIFI-mode routing in `top.sv`: GPIO2 = SCC TXDA out, GPIO3 = into SCC RXDA (pull-up),
GPIO4 = ESFLOPPY_COMM_BUS[5] passed out, GPIO5 = passed onto ESFLOPPY_COMM_BUS[4] (pull-up); none driven in FLOPPY mode.
Protocol: `docs/lisanet_link_protocol.md` (framed, CRC-32, 4 KB blocks, LIST/STAT/OPEN/READ/WRITE/CLOSE/DELETE/RENAME/MKDIR/
MOUNT_NEXT). ESFloppy side (`sdServer.cpp`, `lisanet.cpp/.h`, local repo only) serves it on the link UART (2 Mbaud) AND on
its USB port; `tools/lisanet_client/lisanet.ps1` is a PC client. **Tested over USB on the real card:** download ~430 KB/s,
upload ~160 KB/s, round trip byte-identical, every command works. Bugs found and fixed: USB TX and RX buffers too small for
4 KB frames; receiver could stay stuck after a damaged frame (now resets after 100 ms of silence). Uploads use OPEN mode 3,
which reserves contiguous space -- ESFloppy refuses fragmented images. **Mount-next works:** ESFloppy mounts the named
image in drive 1 at every FLOPPY start-up until cleared (`/LISANET/MOUNTNXT.TXT`), and the Lisa saw the disk.
**Floppy-path evidence from that test (the known floppy problem, not LisaNet):** the Lisa showed the disk named "I"; ejecting
made LOS complain and hang (recovered by reset). Comparing the used copy with the original: the DC42 checksum (header
72-75) plus 6 data sectors changed by 1-5 bytes each -- sector 28 (+312: 00->01), and sectors 39/41/42/43/44 all got the same
4 bytes at +50..53 (-> `94 97 F1 00`, looks like a timestamp; +76 00->01 in 39/41); no tags changed. **So writes arrive
intact and consistent.** Sector 28 is the volume record; its name field (offset 12) is "AOS 3.0"; "1000 Miles" is a
directory entry in sector 43. "I" matches neither, and neither was damaged. The copy is kept on the card as
`/LISANET/1000-miles-copy.dc42`; the original `/1000-miles.dc42` is untouched.
**J21 routing build (2026-10-11): WNS +0.274 / WHS +0.058, 0 failing setup/hold endpoints, only the 10 known pulse-width
entries.** Verified on `top_routed.dcp`: GPIO2/GPIO4 are OBUFT with PULLDOWN, GPIO3/GPIO5 IBUF with PULLUP, GPIO0/1 IBUF
with PULLDOWN, ESFLOPPY_COMM_BUS[5] still IBUF-only with PULLUP, [3]/[4] OBUF; both esp_mode false paths bind.
**JTAG-loaded, Serial A loopback PASSED:** a jumper from J21 pin 5 (GPIO2) to pin 7 (GPIO3) echoed LisaTerminal's typing
in WIFI mode, and the echo stopped in FLOPPY. LisaTerminal's local echo is off, so a working loop shows each letter
ONCE -- test by flipping to FLOPPY, not by counting letters. Not yet in flash; the GPIO4/5 link path will be tested by
the XIAO itself.
**XIAO firmware (`firmware/lisanet_wifi`, 2026-10-11): written and compiles clean for `esp32:esp32:XIAO_ESP32S3`;
untested (no XIAO yet).** `atmodem` (AT commands on Serial A, ported from the phase-1 draft, plus AT+WEBPASS / AT+WEB /
AT+SDINFO -- the last is the first link test), `web` + `page.cpp` (Basic-auth SD manager at lisanet.local: list,
download, contiguous upload, rename, delete, mkdir, mount-next), `sdlink` (link client). Everything runs from `loop()`
on one task, so the link is never shared. ESP32 WebServer gotchas: a raw (streamed) body is only offered to POST
handlers registered with an upload function, and the QUERY STRING IS PARSED AFTER the body -- so the upload path travels
in an `X-Path` header (registered with `collectHeaders`) and the size comes from `clientContentLength()`. The password
is checked at RAW_START, before anything touches the card. The XIAO cannot see the MODE line: in FLOPPY mode link calls
simply time out (the page reports 503).
**XIAO bring-up (2026-10-12): firmware runs, WiFi + link to ESFloppy WORK.** XIAO ESP32S3 (MAC 68:ee:8f:62:f5:e4, 8 MB
PSRAM) on COM7 (Seeed factory firmware enumerated as VID 2886 on COM6). First flash needed manual download mode
(hold B, tap R); afterwards the chip kept rebooting into the ROM loader (`boot:0x0 (DOWNLOAD)`, "waiting for download")
until R was pressed once by itself -- after that, arduino-cli's automatic reset works. Its USB console (hardware CDC)
sends NOTHING until the host sets DTR, and opening the port restarts the chip. The AT commands also work on the USB
console now (`tools/lisanet_client/xiao_term.ps1` is a PowerShell terminal for it; arduino-cli `monitor` could not
find its serial monitor from Git Bash). AT+WSCAN saw 17 networks; joined `Joshua`; web page answers 401 without the
password, at lisanet.local = 192.168.0.128. Wired to J21 (D0->GPIO2 green, D1->GPIO3 yellow, D7->GPIO4 orange,
D6->GPIO5 red, GND brown; 3V3 unconnected, XIAO on its own USB) with the J21 build JTAG-loaded: **AT+SDINFO returned
ESFloppy's firmware string and card size through the FPGA at 2 Mbaud** -- the whole option-B data path works.
**WIFI HDD: managing ESProFile's card too (2026-10-12, in progress).** ESP32 MODE is now FLOPPY -> WIFI FDD -> WIFI HDD
(`esp_wifi_mode` + new `esp_target_hdd`, settings bits 72/73). ESProFile has three FPGA lines, `ESPROFILE_COMM_BUS[2:0]`
(FPGA C15/D15/E16 -> its GPIO36/37/38, found in the netlist's PAD_NET entries for U16 pins 41-43), which were a hard-coded
`3'b101` that its firmware never read. They now carry MODE / link in / link out exactly like ESFloppy's [5:3], and the
J21 link is muxed to whichever ESP32 is serving. The Lisa has no hard disk in WIFI HDD. ESProFile firmware: local clone
`Development\ESProFile`, branch `lisanet` (sdServer ported from ESFloppy; boot check in `setup()`; `lisanetIdlePoll()`
in the emulator's idle wait, timed with the CPU cycle counter because the emulator runs with interrupts OFF). **Because
old bitstreams hold MODE high (`3'b101`), a request also needs the link input seen high** -- the real WIFI HDD path
always idles high; the old constant holds it low. **Regression PASSED on hardware: with the new ESProFile firmware on an
old bitstream, the LED goes green and the Lisa boots from the hard disk.**
**ESProFile flash reads fail on ONE block: `0x87000` always gives esptool's "Packet content transfer stopped"** (the
stub's fast read path; data-dependent). Every other block reads fine, and `--no-stub` (ROM loader) reads 0x87000
reliably. So back it up in 512 KB pieces, falling back to 4 KB pieces and then `--no-stub` for a failing piece. This is
almost certainly what "hung" ESProFile in October: its reads were aborting, not the chip failing. Backup:
`tools/esp32_wifi_test/backup/esprofile_flash_backup.bin`, two passes identical, SHA-256 `16f890c0...`. Each esptool call
resets ESProFile, so its LED flashes red during a backup; that is expected.
**WIFI HDD build: WNS +0.326 / WHS +0.049, JTAG-tested.** FDD/HDD switching, the card label and mount-next hiding
all behave. **ESP32 MODE lock (2026-10-12): WNS +0.405 / WHS +0.077, JTAG-tested and working; NOT yet in flash.** The row
reads NORMAL / WIFI FDD / WIFI HDD with the Lisa off and DISABLED with it on (`lisa_on` = `~blank_video_sync`, the
Lisa's ON signal already synchronised for video blanking -- no new CDC). Switching the Lisa on in WIFI HDD drops to
NORMAL; WIFI FDD is kept so the Serial A modem works from the running Lisa. The Lisa's self-test outlasts ESProFile's
~3 s restart: it boots from the hard disk fine.
**Menu: ESP32 MODE first, and hidden without a WiFi board -- built (WNS +0.081 / WHS +0.085; worst path is now the menu draw, video_mode -> menu_pixel, 9 levels at 1080p60: pipeline m_item first if the menu grows), hardware-tested 2026-10-13 (row first; vanishes ~2 s after unplugging the XIAO, returns as NORMAL), FLASHED and cold-booted with saved settings intact.** Row order is now ESP32 MODE,
RESOLUTION, ADJUST HORIZ, ADJUST VERT, CPU SPEED, MAX CONTRAST, SAVE SETTINGS, EXIT; `m_item = m_row + (present?0:1)`
maps display rows to items, so with no board the box is 7 rows (`menu_h` 112). Presence: J21 GPIO5 (the XIAO's link
TX) is now PULLED DOWN, and a powered XIAO holds it high (UART idle), so "seen high within ~2 s" = board present. Both
MODE lines are gated on presence in top.sv; after a 3 s power-up grace (so a saved WIFI mode waits for the XIAO), an
absent board drops the mode to NORMAL, and it stays NORMAL if the board returns. **Patch-script lesson:** a Perl helper
taking the replacement as an ordinary string interpolates `$1` BEFORE the match, silently deleting the anchored lines
-- caught by xvlog. Use an inline `s~~$1~` or a placeholder substituted after the match.
**FPGA control channel (2026-10-13, branch `feature/lisanet-control`): built (WNS +0.182 / WHS +0.049, 23030 LUTs
36%), simulated, JTAG-tested -- WORKS; FLASHED 2026-10-14 (3 MHz, use_file; cold-boot check pending).** The web page's Settings tab changes the on-screen menu's
settings (resolution with a 15 s auto-revert, H/V position, max contrast, CPU speed, ESP32 mode with the same Lisa-off
lock, save), presses the Lisa's power and reset buttons, and shows Lisa on/off and the **die temperature** (an XADC in
`lisanet_ctrl`, single-channel temp mode, ADCCLK 25 MHz). No extra wires: `lisanet_ctrl.sv` (sysclk) listens on J21
GPIO5 in EVERY mode for `C3 3C 96 69` + CRC-32 frames and replies on GPIO4 after the serving ESP32's TX has been idle
20 us (GPIO4 is now driven idle-high in NORMAL when a board is present). Writes reach HDMI_Interface as `web_req`
{toggle, reg, value} applied on a frame tick (same block as the menu, so no multiple drivers); status comes back as
`ctrl_status` (88 bits) through the existing clock-level set_max_delay. Power/reset are 250 ms virtual presses ANDed
into `_PWRSW_int` / `_RSTSW_int` through COPCK_2x synchronisers (false paths, verified by effect). Rejected design: masking
the ESP32's RX during a control frame -- the FPGA sees ALL traffic, so file data containing the marker would be corrupted
on every retry; instead the 4-byte marker + CRC make false matches negligible and the XIAO picks seq so a control frame
never contains A5. xsim testbench (scratchpad) covered STATUS, SET, bad CRC, LOCKED, the reply guard and ACTION; it also
caught a double driver on `tx_en` (initial block + always_ff) that synthesis might have tolerated. XIAO: `fpgactl.cpp`,
`/api/fpga*`, the Settings tab, `AT+FPGA` (prints the frame sent and every byte received -- that is how the bring-up
fault was found). **Bring-up "FPGA not answering" was a misplaced orange wire (XIAO D7 must go to J21 pin 2 / GPIO4)**:
SD link and control replies both died, since GPIO4 is the only line back to the XIAO. Check that wire first.
**Lesson: never connect a USB-powered XIAO's VBUS/5V pin to anything.** A GND jumper slipped onto it shorted the PC's USB
5 V, tripping its overcurrent protection: the PC's ports then gave power but no data (XIAO and board both "vanished"),
until a PC reboot. Nothing on the board was damaged. The XIAO can instead be powered from J21 pin 8 (3V3; the board's TI
regulators are rated 2-4 A) -- but never with its USB plugged in at the same time.
**Web overrides of jumpers/switches + NMI (control version 2, 2026-10-14): built (WNS +0.206 / WHS +0.055, 0 failing
setup/hold, only the 10 known pulse-width entries; 23239 LUTs 36.7%, 41 BRAM), simulated; NOT yet hardware-tested or
flashed.** Web page only (no menu rows): SET regs 8 scanlines, 9 inverse video, 10 CPU ROM, 11 I/O ROM, 12 RAM size
(0 = jumpers, 1-4); 10-12 LOCKED while the Lisa is on (FPGA-enforced in lisanet_ctrl AND HDMI_Interface); ACTION 4 = NMI
(250 ms press, COPCK_2x synchroniser `ctrl_nmi_int/sync` ORed into `_NMI`). Toggles XOR onto the pins like MAX CONTRAST
(web asks for the effective value); RAM is follow-or-override like CPU SPEED. HDMI_Interface holds them
(`lnet_cfg_*`, `cfg_pins` in / `cfg_ovr` out); top.sv derives `invid_eff` / `cpu_rom_eff` / `io_rom_eff` / `ram_sel_eff`
and feeds them everywhere the pins went (HDMI gets the EFFECTIVE CPU_ROM_SEL, so framing follows). Saved in settings
bits 64 (scanlines, now honoured on load) and 74-79 -- the last spare bits of the flags. Status grew to 13 bytes, the
two new ones sent AFTER the temperature so older XIAO firmware still parses the reply; VERSION = 2. The override
registers drive DOTCK/C16M logic combinationally exactly like the jumpers, so they are false-pathed by name
(`get_cells -hierarchical -filter {NAME =~ *lnet_cfg_*_reg*}`): **verified by effect, all 1039 paths into non-pixel
clocks report EXCEPTION = False Path.** INVID is active low at the pin (CPU_board gets `~INVID`), so "inverse on" =
pin^override == 0 -- derived from the code, CHECK ON HARDWARE that the page's Inverse video matches the screen. XIAO 0.5
shows the new controls only when the FPGA reports version 2. Gotcha: `.row{display:flex}` beat the `hidden` attribute
(`#nosd` never hid); page.cpp now has `[hidden]{display:none!important}`.
**Board state 2026-10-16 ~00:30 (current):** the 10-14 control-channel build is back IN FLASH (from the readback,
`tools/esp32_wifi_test/backup/fpga_flash_10-14_control.{bin,mcs}`), cold-booted: saved alignment and USB soft-CPU host
work again. ESFloppy runs our firmware with the OLED guard + floppy remote (committed in the ESFloppy repo as f3df891 /
bc71bad on `lisanet`, not pushed; the remote is dormant on this build). ESProFile is back on its LisaNet firmware
(`lisanet` branch HEAD 81f33f3, rebuilt and flashed 2026-10-16). ESFloppy card: `/hd` renamed back (done). XIAO back
on J21. The MMCM-merge build below was FLASHED 2026-10-16 morning; it settles at 89-90 C with no case fan (logged
20 min, flat; the Lisa's state makes no visible difference -- the heat is always-on infrastructure).
**USB on the 1080p MMCM + 1024x768 DROPPED -- built 2026-10-16 10:49, uncommitted, not yet on hardware:
WNS +0.163 / WHS +0.065, 0 failing setup/hold, 9 pulse-width entries (one fewer BUFGMUX on the 742 MHz path);
3 MMCMs (= upstream), BRAM 26 tiles (was 42: the 1024x768 AA path's framebuffer copy is gone), 22738 LUTs, power
estimate 1.212 W (upstream ~1.18).** `OUTPUT_1024X768 = 0`; in HDMI_Interface the 1024x768 MMCM and the stage-B
BUFGMUXes are now inside `generate if (OUTPUT_1024X768)` (g_clk_1024x768 / g_mux_1024x768), so a build without it
carries NEITHER (an MMCM runs whether or not its clocks are selected). `hdmi_clock_divider` now has 5 outputs:
usbclk_fs on CLKOUT0 = 742.1875 / 12.375 = 59.975 MHz (-0.042%, inside full speed's +-0.05%), BUFG; the 1080p clocks
unchanged on CLKOUT1-4 (742.1875 / 371.09 / 148.4375 / 74.21875, dividers 1/2/5/10). **The IP is in OVERRIDE_MMCM mode with
M = 11.875, D = 2 pinned: asked for 60.000 the wizard chose a 750 MHz VCO, putting both 1080p modes 1% off** -- caught by
the script's exact-frequency check. usb_sie/usb_softcpu gained `FRAME_CLKS` (top.sv passes 59975) so the SOF interval
is exactly 1.000 ms. hdmi_clock_divider_1024x768.xci restored to its pre-merge two outputs (from b7fc3d5). XDC:
`clk_audio` -source moved to `bufgmux_clk_pixel_a/O` (the stage-B mux is gone -- a 1024x768 build must point it back),
1024x768-only lines made -quiet/wildcarded, the dead fdcram_q line removed. Verified on top_routed.dcp:
`usbclk_fs_hdmi_clock_divider` 16.674 ns from hdmi_clock_generator CLKOUT0, all its crossings Asynchronous Clock Groups,
intra slack +5.700; 1080p30<->60 still Logically Exclusive (the empty 1024x768 group does NOT cancel the command);
clk_audio exists; zero *1024x768* cells. Expected critical warnings: the two unused IPs' XDC files (1024x768,
usb_fs_clock) and the 1024x768 group/CE lines matching nothing. **JTAG-tested 2026-10-16 (bitstream saved as
`tools/esp32_wifi_test/backup/fpga_no1024_2026-10-16.bit`): 1024x768 gone from the OSD (greyed on the web page),
wireless keyboard + mouse work at 59.975 MHz, saved screen position correct, and the FLOPPY REMOTE works end to end
-- insert and eject from the web page while LOS runs (with XIAO 0.8's dropdown).** Hub keyboard not yet tried.
A follow-on build (2026-10-16) lets ESP32 MODE go back to NORMAL while the Lisa is on (menu OK, web reg 6 value 0;
lisanet_ctrl only LOCKs reg 6 for non-zero values -- testbench updated) -- its first build MISSED timing by 107 ps on
`wifi_seen_cnt -> menu_pixel` (11 levels at 1080p60, the menu-draw path flagged above), fixed by registering
`wifi_board_present`. **Rebuilt 2026-10-16 14:05: WNS +0.296 / WHS +0.054, 0 failing setup/hold, 9 pulse-width entries; 3 MMCMs, 26 BRAM, 22633 LUTs, 1.238 W estimate; same by-effect checks pass (usbclk_fs 16.674 ns, async crossings, 1080p exclusive, clk_audio, no 1024x768 cells).** **FLASHED 2026-10-16 (copy: `tools/esp32_wifi_test/backup/fpga_unlock_2026-10-16.bit`) and cold-booted: back to NORMAL from WIFI FDD with the Lisa running works (web and menu), screen position, wireless USB and the floppy dropdown all fine. This was the board's build until 2026-10-22 (FujiNet build below).** Hub keyboard ALSO works at 59.975 MHz (user, 2026-10-16), so USB is fully confirmed on this build. Merged into the fork's `main` the same day. No-1024 build temperature (JTAG, no fan, Lisa on): settles at 85-86 C, ~4 C below the MMCM-merge build's 89-90 C.
**FujiNet adapter on Serial B (2026-10-22, branch `feature/lisanet-control`, uncommitted): built, JTAG-tested, LisaFuji WORKS on the Lisa, FLASHED (copy `tools/esp32_wifi_test/backup/fpga_fujinet_2026-10-22.{bit,mcs}`) and cold-booted fine (user, 2026-10-22). This is now the board's build.** Control version 3: SET reg 13 = Serial B (0 its own port, 1 the SCC's channel B to J21 GPIO2/3 for the XIAO, 2 a bench test wiring the REAL Serial B port to the XIAO instead). It shares GPIO2/3 with the Serial A modem and wins (`esp_mode_dot` now means "Serial A to the XIAO"); CTSB held asserted, physical TXDB parked at mark; never locked (Lisa on is fine); value 1 saved in settings bit 63 (v_offset_1024's top spare bit), the bench test never saved; status byte 12 bits 5/6. Build: WNS +0.589 / WHS +0.048, 0 failing setup/hold, 9 pulse-width entries, 22648 LUTs, 26 BRAM; `serb_dot_int_reg[*]` false path verified by effect. XIAO 0.9 (`fujinet.cpp`, OTA-installed and kept): a FujiBus (SLIP + end-around-carry checksum) responder written from fujinet-firmware's protocol (GPL-3.0; no code copied) -- FujiNet device 70 (WiFi status, adapter config, SSID, status, 512-A device test, reset), clock 45 (all read formats; POSIX TZ set on the web card, SNTP), N1-N8 71-78 (HTTP/HTTPS GET/POST/PUT/DELETE streamed through a 4 KB buffer since PSRAM is off in this build; translation; cJSON parser + JSON-pointer QUERY; login/password); unknown commands NAKed and logged on the web card. It owns the shared UART while the FPGA reports Serial B routed (polled every 10 s with 1 attempt, and from the web page), and `atmodem::setLisaAttached(false)` keeps the modem off the wires. LisaFuji 1.1 (github.com/GyroPilot/Apple-LisaFuji) uses only 70/00, 70/FA, 70/E8, 45/93 (one param byte), and N1 OPEN mode 4 / STATUS / READ <= 256 / CLOSE; it waits 25 s for the first STATUS after OPEN (the fetch happens then). **Bench-test gotcha:** the board's SERIAL B SOURCE switch (e481) drives a 2:1 mux (e520) that feeds RXDB from EITHER the DB-25 port OR the CP2102N (COM5), so `tools/lisanet_client/fujinet_test.ps1` on COM5 only works with that switch at USB -- the first run got no replies at all. The real test (LisaFuji on the Lisa) does not depend on the switch. XIAO 0.10 (installed over WiFi and working, user 2026-10-22): the FujiNet baud rate and time zone apply at once but go to NVS only on Save settings (`fujinet::save()`, called from the web's save action); the card shows "not saved yet". Setup and wiring guide for users: `firmware/lisanet_wifi/README.md`. XIAO 0.11 (installed and working, user 2026-10-22): the web page calls the modes Normal / Manage ESFloppy files / Manage ESProFile files (the OSD keeps NORMAL / WIFI FDD / WIFI HDD: too long for its font), and the Files tab exists only in the two manage modes (it opens ~4 s after choosing one, and closes itself if the mode returns to Normal; an FPGA that cannot report its mode keeps the tab). Page JavaScript syntax-checked before release by serving it from a PowerShell HttpListener to the browser pane (`new Function` on the script text) -- no Node on this machine, and a broken script would also disable the page's own Go-back button.
**MMCM-merge build DONE (2026-10-16 00:52, commit ef8d38b): WNS +0.376 / WHS +0.056, 0 failing setup/hold,
only the 10 known pulse-width entries; 4 MMCMs; 23095 LUTs; power estimate 1.383 W (was 1.527).** Verified on
top_routed.dcp: `usbclk_fs_hdmi_clock_divider_1024x768` = 16.667 ns (60.000 MHz) from the merged MMCM's CLKOUT0, the
1024x768 pixel clocks unchanged (CLKOUT1/2), every usbclk_fs crossing reports Asynchronous Clock Groups, intra slack
+5.677. New critical warnings are benign: the unused usb_fs_clock IP's own XDC finds no module (like the ILA IPs), and the
FDC-RAM `fdcram_q_reg*` set_max_delay binds nothing (the RAM became RAMB18 with its read register inside) -- drop that
line next time the XDC is touched. Next: flash it (Lisa off, user's go-ahead), cold boot, XIAO 0.7, test the Floppy
drive card, measure the temperature.
**Board state at end of 2026-10-15 (superseded):** running CLEAN UPSTREAM -- v1.6 `top.mcs` in
the config flash, Alex's ESFloppy and ESProFile firmware (from the 8 MB backups), XIAO unplugged; ESFloppy's card has
`/hd` renamed `/.hd`, a pristine `/.LISANET/1000-miles-pristine.dc42`, `/LisaCalc.image`; the saved settings block at
0xC00000 is untouched. Upstream v1.6 settles at 80-82 C with no fan; our builds ran 88-92 C (a fan on the heatsink gave
60 C). A build was launched ~23:20 with: (1) the MMCM MERGE -- `hdmi_clock_divider_1024x768` now has 3 outputs
(usbclk_fs 60.000 = 975/16.25 on CLKOUT0, the only fractional output, BUFG; clk_pixel_1024x768 65 = 975/15 and
clk_pixel_x5_1024x768 325 = 975/3, No_buffer), exported from HDMI_Interface as `usbclk_fs`; the `usb_fs_clock` IP is no
longer instantiated (4 MMCMs, ~0.12 W less; Vivado estimated our build at 1.53 W vs upstream ~1.18 W, the two extra MMCMs
being ~0.23 W of it, the on-screen menu only ~0.01-0.02 W); the IP's OOC run had to be re-run before elaboration saw the
new port; (2) the INVERSE VIDEO polarity fix (inverse on = pin ^ override == 1, from the user's test); (3) the FDC RAM
C16M change. All uncommitted. Next: check that build's timing and the usbclk_fs clock/groups by effect, then (user's
go-ahead) restore our setup -- flash it, ESFloppy/ESProFile LisaNet firmware, XIAO back on J21, `/.hd` -> `/hd` -- and
measure the temperature. Floppy reads remain an open, probably HARDWARE, fault (see below); next test there is the
user's spare ESFloppy on the EXT floppy connector.
**FLOPPY PROBLEM SOLVED (2026-10-15): it was the DEAD OLED.** With the broken OLED UNPLUGGED, floppies read RELIABLY
(repeated inserts, both images, Lisa reboots) on the same clean-upstream setup that failed ~3 times in 4 with it
plugged in. Everything in the long bisect -- FPGA builds, JTAG vs flash, the FDC RAM timing, heat, CPU speed,
ESProFile, our firmware -- was a red herring; the apparent patterns were chance. Mechanism below. A replacement OLED is
on order. **OLED GUARD written and CONFIRMED on hardware (2026-10-16):** ESFloppy `lisanetOled.cpp` (lisanet branch,
uncommitted, built together with the floppy-remote code): `lisanetOledGuardInit()` right after `Wire.begin()` sets a
5 ms Wire timeout, probes 0x3C and installs a wrapper on u8g2's byte callback (`u8g2_GetU8x8(...)->byte_cb`), so EVERY
OLED transfer is dropped if the display did not ACK at start-up or once any transfer takes > 5 ms (logged once). With
the dead OLED plugged back in (wired correctly) it logged "OLED not answering ... (I2C result 2)" and floppies loaded
fine. The display is genuinely dead (no ACK even wired right); the user saw its Dupont wires twisted when unplugging it,
so SCL/SDA may have been swapped at some point -- unknown. Safe on upstream bitstreams too (they hold ESFLOPPY_COMM_BUS
[5:3] = 0: MODE low, and the remote's link never starts). Still to do: suggest the guard to Alex (user's OK). The FDC RAM change (IO_RAM_444C_3 on C16M) is still a correct
timing improvement and stays in, but it did NOT fix this.
**The dead-OLED mechanism (was "strongest lead", now confirmed by unplugging):** ESFloppy drives the OLED over I2C (SDA 46 / SCL 2) from
the SAME SD task that feeds tracks to the floppy core; `sendOneOLEDPage()` (uiHelpers.cpp) is called every loop and
Alex's own comment says one page must stay ~3 ms or the SD task can't keep up with the Lisa. The status screen redraws
"Track xx Side x" on every head step, so I2C traffic happens exactly during disk reads; a dead display that NACKs or
holds the bus low could make each transfer wait for the Wire timeout -> late tracks -> read retries. The OLED died in
the 10-04 overvoltage, and floppy was never tested between then and 10-11. Test firmware ready:
`tools/esp32_wifi_test/backup/esfloppy_70cd08e_tracklog_oledprobe.ino.bin` (+ `.patch`, applies to ESFloppy 70cd08e):
track log + probes I2C 0x3C at the first page send ("[oled] probe 0x3C: ..."), disables OLED updates if no ACK, logs any
page > 5 ms. Flash with arduino-cli upload --input-dir or esptool at 0x10000 (bootloader/partitions copies alongside),
then watch the console while LOS reads a disk. If it is the cause, the cure is that check in the real firmware (or
replacing/removing the dead OLED).
**UPDATE 2026-10-15 late (SUPERSEDED -- the cause was the dead OLED, see "FLOPPY PROBLEM SOLVED" above): the build theory below is WRONG -- floppy reads are flaky on this board even fully
upstream.** With Alex's v1.6 `top.mcs` flashed (from `origin/main`, copies in `tools/esp32_wifi_test/backup/upstream_v1.6/`),
Alex's ESFloppy 1.0 and ESProFile firmware restored from the 8 MB backups, the XIAO unplugged and a cold boot, LOS still
says "not in the standard Lisa Office System format". It also fails for a second image (TOSEC LisaCalc, 400K DC42), at
5 MHz, and at 60 C with a fan; ESFloppy has never saved settings (NVS has no `configStruct`), so it is in its default
Sony-Lisa mode. Track-logging ESFloppy firmware (70cd08e + the commented-out debugPrint lines in SDTask.cpp re-enabled)
showed LOS re-requesting the same tracks (e.g. 3,0,6,2 x3) and giving up = read RETRIES: ESFloppy delivers every track,
the Lisa decodes garbage. Successes (~3 of ~12) are intermittent and earlier "patterns" (first boot after power-up,
JTAG vs flash, ESProFile reset) were chance. Prime suspect: hardware damage from the 10-04 overvoltage (same event
killed D5 and ESFloppy's OLED); floppy was never tested between 10-04 and 10-11 (no screen). Next: an external ESFloppy
on the EXT floppy connector (FLOPPY SOURCE = EXT) to split onboard ESP32/traces from the FPGA side, or a GPIO
self-test. The FDC RAM change (IO_RAM_444C_3 on C16M) is still a real timing improvement but did not cure this; it
is uncommitted in the working tree. To restore our setup: flash a LisaNet bitstream, ESFloppy/ESProFile LisaNet
firmware, plug the XIAO back, rename ESFloppy's `/.hd` to `/hd`.
**FLOPPY READS DEPEND ON THE BUILD -- root cause found (2026-10-15), NOT FIXED YET.** (Superseded by the update above.) Symptom: LOS says "The micro
diskette is not in the standard Lisa Office System format" (10-11: a disk named "I", hang on eject) for a good image.
Bisected on hardware: same pristine `1000-miles.dc42` (SHA-256 `0c00f225...`, checksums verified), same ESFloppy
firmware (`70cd08e`, whose drive code is byte-identical to Alex's), same settings -- the FLASHED 10-14 control-channel
bitstream reads it fine (game copied off), the JTAG-loaded 10-15 build fails every time. The 10-14b/10-15 RTL changes are
logically neutral for the floppy (I/O ROM override off, `io_rom_eff` == the switch), so it is placement. Cause, in
upstream code: `IO_RAM_444C_3` (the FDC's shared RAM, 2 x 1024x4; every floppy sector byte passes through it) is
written/read on `negedge _CS`, where `_CS` = `io_board/_FDC_RAM_CS_processed_reg` -- a fabric register used as a clock,
on general routing, with the address (`RA` muxed between the 68K bus and the 6504's MA), data and R_W arriving through
logic, and NO clock defined, so nothing is timed. check_timing: 217,721 no_clock pins, incl. 137 on
`_FDC_RAM_CS_processed_reg` and 231 on `io_board/clock_divider_reg[1]` (C4M; C2M likewise -- divided in fabric, BUFG'd,
never declared). "Timing met" therefore says nothing about the floppy path. Fix to make: run the RAM on C16M with an
enable from the falling edge of the chip select (and constrain the 68K-bus -> C16M crossing deliberately), plus
create_generated_clock for C4M/C2M; prove it by TIMING (paths constrained, positive slack), not by one lucky build.
Until then: a build that reads floppies is the flashed 10-14 one. Bisect side notes: opening ESFloppy's USB console
RESETS it (rst 0x15 USB_UART_CHIP_RESET) -- never (re)open it while the Lisa uses a disk; the LOS selector ejects the
floppy when a hard disk is chosen (ESFloppy RESET re-inserts via mount-next); ESFloppy's card has `/hd` renamed to
`/.hd` for the blind-SEL test (rename back).
**XIAO FIRMWARE CHANGES: SHIP EVERY ONE AS A NEW, VERSIONED FILE FOR A WIRELESS UPDATE. The user updates the XIAO over
WiFi only from now on -- do NOT flash it over USB (COM7) unless WiFi updating itself is broken.** For every change to
`firmware/lisanet_wifi`:
1. Bump `LISANET_WIFI_VERSION` in `config.h` (source is 0.2, but 0.3 and 0.3-crashtest were OTA TEST builds, so releases go 0.4 (wireless firmware updates), then 0.5...; never reuse a number -- the page tells versions
   apart only by this string, and "Go back to x" names the previous one). Also rewrite `LISANET_WIFI_NOTES` (a few words on what the version brought; the card shows it in brackets after the version, with the flash slot app0/app1 only as a tooltip).
2. Compile: `tools/toolchain/arduino-cli/arduino-cli.exe compile --fqbn esp32:esp32:XIAO_ESP32S3 --output-dir
   firmware/lisanet_wifi/build firmware/lisanet_wifi`.
3. Check the tag is in the image: `grep -ao "LISANET-WIFI-FW/[ -~]*" firmware/lisanet_wifi/build/lisanet_wifi.ino.bin`
   must print `LISANET-WIFI-FW/<new version>` (the bare `LISANET-WIFI-FW/` line is the search string; ignore it).
   Without it the board refuses the upload.
4. Copy it to a fresh, versioned file for the user: `firmware/lisanet_wifi/build/releases/lisanet_wifi-<version>.ino.bin`
   (build/ is git-ignored; the plain `lisanet_wifi.ino.bin` is overwritten by every compile, so the versioned copy is
   the one to hand over). Give the user its full Windows path. NEVER hand over `.merged.bin` (refused: too big).
   **When the version is committed, also refresh the COMMITTED prebuilt images in `firmware/lisanet_wifi/release/`**
   (added 2026-10-29 so a first flash needs no build): `lisanet_wifi.ino.bin` = the build's app image, and
   `lisanet_wifi_factory.bin` = the build's `.merged.bin` cut at the first 4 KB boundary after the app, i.e.
   `head -c $(( ((65536 + appsize + 4095) / 4096) * 4096 ))`; check that the bytes cut off are all 0xFF and that both
   files carry the new tag.
5. The user installs it from lisanet.local -> Settings -> "WiFi board firmware" -> Install update. The new version
   is on trial for 20 s; ask the user what the card shows afterwards before recording a result.
6. Commit the source with the version bump (only when the user asks).
Keep each change able to boot and bring up WiFi + the web server: a version that boots but breaks the page or WiFi is
NOT rolled back automatically (only crashes in the first 20 s are). If the page still loads, its "Go back to x" button recovers; if it does not, only a USB flash does (the B button wipes the network and password, not the firmware).
**XIAO firmware updates over WiFi (2026-10-14): WORK on hardware -- all four tests passed** (0.2 -> 0.3 over WiFi;
a crash-test build rolled back to 0.3 by itself; manual "Go back to 0.2"; a .merged.bin refused). `ota.cpp`, the
"WiFi board firmware" card on the Settings tab (which is now the FIRST tab; `#files` keeps Files across a reload),
`/api/fw`, `/api/fw/update` (raw body, password checked at RAW_START), `/api/fw/rollback`. The default 8 MB partition
table already has two 3.2 MB app slots (the app is ~1 MB), so no repartitioning; the XIAO needed one last USB flash.
Safety: an upload must contain `LISANET-WIFI-FW/<version>` (so ESFloppy/ESProFile builds, bootloaders and merged images
are refused; a merged image is also too big for a slot), ESP-IDF verifies the image before it becomes bootable, and the
core's rollback (`CONFIG_APP_ROLLBACK_ENABLE=y` in this core) is kept pending by overriding `verifyRollbackLater()`
until the image has run 20 s -- a crash before then reverts to the previous slot at the next reset. A pending image
refuses a further update until it is kept. Gotchas: (1) `__attribute__((used))` does NOT survive `--gc-sections` --
the tag was silently missing from the binary until boot code printed it; grep the .bin for the tag. (2) The search
string is itself in the image, followed by a NUL, so a match only counts with a printable version after it. (3) Inside
`namespace ota`, a bare `abort()` calls `ota::abort()` -- the crash hook needs `::abort()`. Test builds:
`--build-property 'compiler.cpp.extra_flags=-DLISANET_WIFI_VERSION="0.3"'` (config.h's version is `#ifndef`-guarded;
`-DLISANET_TEST_CRASH` adds a deliberate crash 5 s after boot); changing flags rebuilds the whole core (~5 min each).
**Data safety across mode switches.** The servers check MODE only between requests, so single operations are atomic;
the risk was MULTI-request operations. Uploads (OPEN mode 3) and copies are now STAGED in `/.LISANET/UPLOAD.PRT` /
`COPY.PRT` and moved into place in one request (the completing CLOSE, or the last COPY_STEP), which also does the
replace-with-backup for Copy to profile.image. Verified over USB: an upload killed halfway left the target byte-identical
and the temp file was discarded by the next request. Verified on hardware: Lisa switched on mid-copy booted the OLD
profile.image intact.
**ESProFile stuck-in-emulator bug, found and fixed (2026-10-12):** after that test, selecting WIFI HDD again did
nothing -- COM3 answered "semaphore timeout" (USB dead = emulator running with interrupts off). Three emulator transfer
loops (`receiveCommand`, `receiveMultiData`, `sendMultiData`) exit only on CMD low or PRES low, with no timeout and no
MODE watch, so a bus the Lisa abandoned at power-off can hold the drive there for good. Fix: those loops also exit when
MODE goes high (tested in the SAME GPIO_IN1 read as PRES, so no extra cost at 75 MHz), the emulator then skips the
half-received command, and the switch no longer prints to USB before restarting. Safe because the menu lock means MODE
can only rise while the Lisa is off. Which loop actually caught it was not proven (nothing can be observed once stuck);
**CONFIRMED on hardware 2026-10-13: the repeat of the scenario (copy, Lisa on mid-copy, power off, WIFI HDD again) went to amber with no reflash.** ESProFile's LED is now AMBER in server mode, GREEN as the hard disk.
**Copy to profile.image** (ESProFile card, `.image`/`.img`): COPY_START / COPY_STEP on-card copy, 1 MB per step, with
the dialog's rename (default `profile-backup-N.image`) or discard of the old file done by the server at the commit.
**XIAO setup network:** `wifisetup.cpp`, WPA2 `LisaNet-Setup` / `lisanet-setup`, captive DNS; comes up with no saved
network, after 60 s without the saved one (then rescans every 3 min), or on AT+WSETUP; the B button held 5 s wipes the
network and web password. Phones' captive-portal windows never show HTTP Basic auth prompts (blank white page), so the
setup page uses its own login form + session token. Tested on a phone: it pops up, logs in, joins. WiFi startup must
precede `server.begin()` (crash loop `xQueueSemaphoreTake ... pxQueue` otherwise). Windows' `netsh wlan show networks`
is a stale cache -- check for the setup network from a phone.
**"ESFloppy's button doesn't mount a disk" -- SOLVED (2026-10-11), not a button or FPGA problem.** With the OLED dead,
a "virtual OLED" build of ESFloppy (local `lisanet` branch, uncommitted: `lisanetLogUi()` in `ui.cpp` plus
`filePickerDescribe()` in `uiFilePicker.cpp`) logs button presses, screen changes, the file picker highlight, error
text and drive contents on the USB console. It showed two things. First, `/1000-miles.dc42` was **fragmented on the card**
(copied from a Mac), so ESFloppy's `contiguousRange()` check refused it with "Image file is not contiguous!". Fixed by
downloading it, deleting it and re-uploading with OPEN mode 3 via `lisanet.ps1` (SHA-256 identical, `0c00f225...`; backup
in `tools/esp32_wifi_test/backup/`); it then mounted. Second, the picker sorts folders before files, so the
`/LISANET` folder came first and blind SEL, SEL entered it. Fixed by renaming it **`/.LISANET`** (the picker hides
names starting with `.`; firmware paths in `SDTask.cpp`/`sdServer.cpp` and the protocol doc updated): the image is now
`[1/1]` and SEL, SEL mounts it, confirmed. **Gotchas:** SEL is the FPGA
menu's OK too, so with the on-screen menu still open a SEL press also toggles the highlighted row (it flipped ESP32
MODE back to WIFI once) -- close the menu before using ESFloppy. SEL within 5 s of ESFloppy starting opens its
settings screen, which only a reboot leaves. In Git Bash, paths like `/1000-miles.dc42` passed to `lisanet.ps1` get
rewritten to Windows paths (server says NOT_FOUND): set `MSYS_NO_PATHCONV=1`.
**Pre-existing bug found, NOT fixed here (it is on `main` too):** `frame_width` is never declared in
`HDMI_Interface.sv`, so its first use (the `cx_adj_comb` line-wrap compare) makes it an implicit **1-bit** net, and the
`hdmi` core's 12-bit `frame_width` output connects only bit 0 (Synth 8-689). The pipeline-latency wrap therefore never
happens; the first ~6 pixels of each line are computed wrongly, which is hidden by the border in every mode used so far
but would show with the image flush left. Fix is `logic [11:0] frame_width;` -- but that restores a real 12-bit compare
on the already tight 1080p60 `cx` path, so it needs its own branch, build and timing check. A `default_nettype none`
at the top of the HDL files would have caught it.
**THERMAL (2026-10-10): the die runs ABOVE ITS RATING.** Read over JTAG from the XADC (`get_hw_sysmons`, read-only, no
reprogramming): **87.9 C now, 88.6 C peak**, with the flashed CPU-SPEED build (`6a3a1b9`) and the board in its case. The
`xc7a100tcsg324-2` is commercial grade, **85 C max junction** -- and every timing sign-off in this file assumes <= 85 C.
VCCINT 0.972 V (in spec), VCCAUX 1.759 V. **It is just as hot with the Lisa switched off**, so the heat is always-on
infrastructure (five MMCMs now vs upstream's three, HDMI serializer clocks and TMDS drivers, clock trees), not the
Lisa core or the CPU SPEED setting. Upstream's own June estimate was 1.18 W (MMCM 0.32 W for three); ours is likely
~1.4-1.6 W. **Planned next, after the WiFi build is tested:** an A/B on the same board and case, Lisa off, same
resolution: read the temperature on our build, JTAG-load upstream's committed bitstream (temporary), let it settle
10-15 min, read again. Similar result -> the fix is a heatsink/airflow; much cooler -> trim what we added (e.g. share
MMCMs). A small 15x15 mm stick-on heatsink on the package is the likely cure either way.

## Parked: unreviewed security findings in `tools/usb_fw/usb_xfer.c` (2026-10-10)

An automated review flagged two issues in `tools/usb_fw/usb_xfer.c` (soft-CPU USB host firmware, commit `e3038b5`, not
touched by the WiFi work): a possible **unbounded loop** and a possible **stack overflow**. **Neither has been verified**;
the file was not read, so either may be a false positive. Both need a hostile or malformed USB device on a keyboard/mouse
port, so the risk is local. The user deferred it. If resumed: read the file, confirm each finding, fix on a separate
branch off `fork/main`, and re-test USB on hardware.

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
  **After a build that drops a debug core, clear the probes file before flashing**: reopening the target at 3MHz
  makes Vivado re-point `PROBES.FILE` at a stale `top.ltx`, and `refresh_hw_device` then fails with
  `[Common 17-48] File not found: ...top.ltx`. Harmless (the SPI loader is already in), but clear it:
  `set_property PROBES.FILE {} [current_hw_device]` and the same for `FULL_PROBES.FILE`, then refresh.
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

Menu items: `RESOLUTION` (1080P30 / 1080P60 / 1024X768), `ADJUST HORIZ`, `ADJUST VERT`, `SCANLINES`, `MAX CONTRAST`,
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
- **Reworked 2026-10-06, CONFIRMED on hardware the same day** (build WNS +0.060 / WHS +0.043, only the 10 known
  1080p60 pulse-width entries): `ADJUST IMAGE` became two rows,
  `ADJUST HORIZ` and `ADJUST VERT` (7 rows now; `ADJUST VERT` shows `NO ROOM` and does nothing where
  `v_limit` is 0, i.e. 1080p with the H ROM). Selecting either closes the menu and drops straight into
  adjusting that axis. **In adjust mode, OK saves the settings and brings the menu back** (highlight still on
  the ADJUST row); LEFT+RIGHT held ~3s goes back to the menu WITHOUT saving. Step size is no longer a mode --
  a held direction accelerates: a tap is 1px, repeat at 1px/frame after ~0.33s, 8px/frame after ~0.83s
  (frame counts scale with the 30/60Hz frame rate, like the summon timer). The axis/step cycling that OK used
  to do is gone. The save snapshot lives in a `start_save()` task shared by the SAVE SETTINGS row and adjust
  mode's OK. Also moved the `btn_sync` declaration above its first use: xvlog rejected the file before
  (Vivado synthesis tolerated it), so `HDMI_Interface.sv` can now be syntax-checked with xvlog.
- **CPU SPEED replaced SCANLINES in the menu (2026-10-06) -- FULLY CONFIRMED on hardware 2026-10-07 and FLASHED:**
  speed changes, the saved speed surviving a power cycle, and the SCANLINES jumper still working. Production
  build of `7419f0f`: WNS +0.343 / WHS +0.073, only the 10 known pulse-width entries. The build before it missed timing by 27 ps on ONE path,
  `video_mode_reg` -> `h_offset_1080p_reg` (the adjust arithmetic, 11 levels / 4 carry chains at 1080p60), now
  pipelined: `active_value_q`, `active_limit_q`, `next_value_q` -- see the comment above `next_value`. The new
  `speed_menu_int_reg[*]` false path was verified BY EFFECT: its paths are listed with slack inf.
  Row 3
  cycles SWITCHES -> 5 -> 10 -> 15 -> 18.75MHZ -> SWITCHES; like RESOLUTION, it follows the physical switches until
  the menu picks a speed. HDMI_Interface outputs `cpu_speed` = {menu owns it, index}; top.sv synchronises it into
  dotck_20M (`speed_menu_int`/`speed_menu_sync`, false path on `speed_menu_int_reg[*]` in the XDC) and folds it
  into `SPEED_SEL_dotck` as `~index` (switch polarity: both OFF = 2'b11 = 5MHz). `SPEED_SEL_dotck` now feeds BOTH
  the clock muxes and CPU_board's status register, so Lisa software reads the speed actually running.
  Saved in the settings flags byte: bits 70:69 index, bit 71 "speed valid" (older blocks have it clear and keep
  the switches). Scanlines are now jumper-only; bit 64 is always saved as 0 and ignored on load. Added a `.`
  glyph (slot 38) for "18.75MHZ".
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
nand2mario (2023) and Mateusz Nalewajski (2026); imported at commit `e492176` (since modified for the Keychron receiver, below). One
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

**Keychron 2.4GHz receiver (VID 3434, PID D030): WORKS (hardware-confirmed 2026-10-05: typing, media keys correctly ignored, Lenovo regression passed) via a per-device override.**
Its configuration descriptor, read from the real device on Windows through the hub driver's
`IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION` (USBView's method; no viewer was installed):

| Interface | Class/sub/proto | Contents | IN endpoint |
|---|---|---|---|
| 0 | 03/01/02 | boot mouse | `0x82` |
| 1 | 03/01/01 | claims boot keyboard, but is a barcode reader + game controller | `0x84` (+ OUT `0x05`) |
| 2 | 03/01/01 | **the keyboard**, plus consumer and system control | `0x87`, 32-byte max packet |
| 3 | 03/00/00 | vendor-defined | `0x83` |

Why it did nothing at all: the core classifies a device from interface 0 only (it reads just 18 bytes of the
configuration descriptor), always polls **endpoint 1, which this receiver does not have**, and sends its HID
setup requests to interface 0. The fix follows the fork's own VID/PID override pattern (its 8BitDo Ultimate 2C
entry), all marked "LisaFPGA" in `usb_hid_host.v`:
- `typ` forced to keyboard and the IN token set to endpoint 7 (`81 23`).
- **SET_PROTOCOL(boot) sent to interface 2.** The microcode's SET_PROTOCOL now takes wIndex and CRC16 from
  `proto_payload`, via the previously unused load addresses 14, 15 and 7 (`regs[7]` is never written: `save 15`
  is diverted to the `connected` flag). Every other device gets the original constant bytes `00` / `C6 E0`.
- **`strict_boot`** drops packets that put fewer than 8 bytes into `dat[]`, because interface 2 also carries
  consumer/system reports that would decode as phantom modifiers. Byte counting is exact: an 8-byte report strobes
  exactly 8 (data byte k is strobed at `wk = 72 - 8k`; the first CRC byte arrives at `wk = 8`, below the `>= 15`
  cut-off), while a 3-byte report strobes data + both CRC bytes = 5.
- New CRCs computed in PowerShell and validated against every token/setup packet the fork already sends
  (CRC5 `00 10`, `01 E8`, `81 58`, `01 BA`, `81 0A`; CRC16 `C6 E0`, `D6 20`, `EE 0F`) before use.
- **Microcode source and assembler now live in `tools/usb_ucode/`**: `ukp.s` (from the fork, with the change
  above) and `asukp.ps1`, a PowerShell port of the fork's `asukp.py` (no Python on the Windows machine). The port
  reproduces the fork's shipped `.mem` byte-identically from the unmodified source. Its default output is the
  build's ROM image. **The ROM is 1012 of 1024 nibbles** -- jump targets are `addr >> 2` in two nibbles, so it
  can never grow past 1024; any further microcode work has very little room.

The receiver's mouse (interface 0) is not exposed: a port carries one device type. Adding another composite
device means another VID/PID entry: read its descriptor the same way, compute the IN token CRC5 and the
SET_PROTOCOL CRC16, and decide whether it needs `strict_boot`.

**Logitech nano mouse receiver (VID 046D, PID C542; M185/M190 class) -- WORKS (hardware-confirmed 2026-10-05,
in the flashed production build).** Full speed, one interface (03/01/02 boot mouse), whose only IN endpoint is **`0x82`** -- so the same
endpoint-1 assumption broke it. Interface 0 is already classified as a mouse and already receives SET_PROTOCOL, so
the entry only sets the IN token to `01 C1` (endpoint 2). The interface also has a vendor collection (Logitech
HID++); if HID++ notifications share the endpoint they would decode as a stray mouse movement. No filter was added
blind -- add one only if that is actually seen.

**Production build (2026-10-05):** `DEBUG_USB_ILA = 0` and the `.xpr` back on default synthesis settings (Vivado
rewrote `<Step Id="synth_design"/>` itself after `set_property ... FLATTEN_HIERARCHY rebuilt` / `DIRECTIVE
Default`). **Flashed 2026-10-05** at 3MHz JTAG and cold-booted from flash with the saved settings intact (WNS +0.302 / WHS
+0.079, 0 failing setup/hold endpoints; LUTs 33.2% without the ILA).

**Next: runtime detection vs. a soft CPU (decided: a soft CPU, on a new feature branch for hub support).**
Discovering the interface and endpoint at attach time on the current core would mean reading the full configuration
descriptor (the core reads at most 31 bytes per transfer; the Keychron's is 116), an RTL descriptor walker, checking
each candidate's HID report descriptor for a Keyboard/Mouse application collection (the Keychron's interface 1 claims
boot keyboard but is a barcode reader -- class codes alone pick the wrong one), CRC5/CRC16 in hardware, and room in a
ROM with 12 nibbles free (removing the unused gamepad/X-Input code would buy some). It still could not do hubs. A soft
CPU running a C USB host stack gets runtime detection, combo receivers and hubs from one design, so per-device entries
remain the stopgap until then.

**UPDATE 2026-10-05: superseded by the soft-CPU USB host on `feature/usb-hub-support` -- hubs WORK on
hardware.** `USB_HOST_SOFTCPU = 1'b1` in `top.sv` replaces both m1nl cores with PicoRV32 + `usb_sie` packet
engines + C firmware (`tools/usb_fw`). No VID/PID tables: interfaces are chosen from HID report descriptors.
Hardware-confirmed: Lenovo keyboard/mouse, Keychron and Logitech receivers, wired Apple mouse, older Apple
keyboard with a mouse in its socket, aluminium Apple keyboard. **Production build (`36316ad`, WNS +0.360 /
WHS +0.076) flashed 2026-10-05 and cold-booted with saved settings intact.** Also confirmed: a low-speed
mouse in an Apple keyboard's socket (PRE through the hub) and hot-unplug from a hub socket. **The aluminium keyboard browns out the board on a weak USB-C supply** (whole FPGA
resets on plug-in) and is fine on a stronger one. Everything -- design, simulation, results, gotchas -- is in
`docs/usb_softcpu_host_design.md`; read that, not the paragraph below, before touching USB. Reverting to the
m1nl core is `USB_HOST_SOFTCPU = 1'b0` plus a rebuild (the m1nl production bitstream is not in git).

**Hub support (the actual Apple-keyboard goal) remains a separate project.** (Historical -- see above.) It needs full speed (which
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
