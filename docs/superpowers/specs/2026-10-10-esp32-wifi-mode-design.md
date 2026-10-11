# ESP32 WiFi mode ("LisaNet") — design spec

Status: **design approved 2026-10-10. Phase 1 FPGA-side RTL written (menu row, settings bit, comm-bus pins, SCC-A mux) but
*never compiled or run* — no Vivado/HDL tools on the Mac. ESP32 firmware not started.**
Branch: `feature/esp32-wifi-mode` (off `fork/main` @ `a01fff7`).
This file is meant to be self-contained: copy the project directory to the Windows/Vivado machine and
everything needed to pick the work up is here.

## 1. Goal

The onboard ESFloppy ESP32-S3 has built-in WiFi. Let the user switch that chip between two mutually
exclusive personalities from the on-screen menu:

- **FLOPPY** (default, today's behaviour): ESFloppy floppy emulator.
- **WIFI**: the floppy emulator is shut down (any mounted disk ejected) and the ESP32 acts as a
  *virtual modem / network gateway* on the Lisa's **Serial A**.

Because the modes never run together, there is no timing conflict between WiFi and floppy emulation.

Priorities (user, 2026-10-10): **(1)** move files / disk images and manage the SD card remotely,
**(2)** network-client features (fetch text/web, time sync, telnet-style), **(3)** a real IP stack for the
Lisa (SLIP). Build toward 2 and 3, but 1 comes first. A **LisaNet** app for the Lisa Office System (the
user has Lisa Pascal Workshop) provides the UI.

Non-goals for phase 1: running floppy emulation and WiFi simultaneously; speeds above serial rates;
any change to the HDMI/USB/CPU paths.

## 2. Context discovered (all verified by reading, nothing run)

Hardware (rev 3 schematic `hardware/lisafpga_deaktop/rev_3/lisafpga_rev_3_schematic.pdf`, pages 4–5):
- ESFloppy is an **ESP32-S3 (S3FN8)**, own USB-C via the CH334 hub, own SD slot (SDIO), OLED on I2C
  (`ESFLOPPY_SCL/SDA` — **ESP32 pins only; the FPGA has no path to the OLED**), three buttons, status LED.
- FPGA ↔ ESP32 link is `ESFLOPPY_COMM_BUS[5:0]`, schematic nets `FPGA_0..FPGA_5` on ESP32 GPIO
  **34,35,36,37,38,39** (ESFloppy `types.h`: `LEFT=34, SEL=35, RIGHT=36, FPGA_3=37, FPGA_4=38, FPGA_5=39`).
  All are ordinary bidirectional GPIOs. FPGA pins (XDC): bus[0]=M13, [1]=R18, [2]=T18, [3]=N14, [4]=P14,
  [5]=N17, all LVCMOS33, declared `inout` in `top.sv`.
- Today `top.sv` (~L236–241) drives `COMM_BUS[0]=LEFT_ESFLOPPY`, `[1]=OK_ESFLOPPY`, `[2]=RIGHT_ESFLOPPY`
  (button echo to the ESP32, which reads them as `LEFT/SEL/RIGHT` with `INPUT_PULLUP`) and `[5:3]=0`.
  Whether ESFloppy firmware reads GPIO37–39 at all is **unchecked** (only the `#define`s were found).
- Serial A: SCC channel A → level shifters → MAX232 → DB25. The SCC is the Verilog core
  `naftaly_blum_scc/z8530_scc.sv`; `top.sv` exposes `TXDA/RXDA/TXDB/RXDB` (+ handshake lines on the A/B
  sides) as FPGA pins and sets `INTERNAL_SCC_EN = 0` (internal SCC in use). Serial B can be routed to the
  USB-C CP2102N by a switch; that stays untouched.

ESFloppy firmware (`github.com/alexthecat123/ESFloppy`, Arduino sketch, board "ESP32-S3 Dev Module", USB CDC on boot):
- `setup()`/`loop()` in `ESFloppy_Main.cpp`; the floppy `loop()` is a tight `Ofast`/`IRAM_ATTR` loop; UI and
  SD run in a separate pinned task (`SDTask.cpp`, which also starts `Serial` at 115200).
- It already supports **OTA update from the SD card** (`esfloppy_fw.bin` in the SD root) and
  `program_board.sh` builds/flashes it.
- Upstream states **no AI-written code** in ESFloppy/ESProFile/LisaFPGA (README "AI" section). Treat our
  fork as our own: do not offer AI-assisted changes upstream without disclosing it.

FPGA menu (fork `HDMI_Interface.sv`): on-screen menu summoned by holding **LEFT+RIGHT ~3s**; rows are
RESOLUTION, ADJUST HORIZ, ADJUST VERT, CPU SPEED, MAX CONTRAST, SAVE SETTINGS, EXIT. Settings persist in the
config flash at `0xC00000` (16-byte block "LFPG", see CLAUDE.md "Settings persistence"); `settings_data` is
80 bits, bits 71:64 are flags (bit 71 = speed valid, 70:69 speed idx, 68 resolution valid, 67:66 video mode,
65 contrast, 64 scanlines/unused). Free bits must be confirmed in `settings_flash.sv` before allocating one.

Known unrelated problem: the floppy path is currently unsolved (see CLAUDE.md "Floppy troubleshooting")
and the OLED is broken, so FLOPPY-mode behaviour can't currently be verified end to end. WiFi mode does
not depend on the floppy lines.

## 3. Architecture

### 3.1 Mode control
- New menu row **`ESP32 MODE`**: `FLOPPY` / `WIFI`. Saved in flash like CPU SPEED (new flag bit +
  "valid" bit so old blocks default to FLOPPY).
- FPGA drives a **MODE** line to the ESP32 (level; 1 = WIFI).
- **ESP32 switches personality by restarting.** Firmware reads MODE at boot; a lightweight watcher in
  both personalities calls `ESP.restart()` when MODE changes. Rationale: the floppy loop is a tight pinned
  loop, tearing it down live is risky; a restart cleanly "ejects" any disk and releases the SD card
  (check ESFloppy for state that must be flushed before restart — writes to a mounted image — and
  flush/unmount first).
- Everything is one firmware image with two personalities (fork of ESFloppy), shipped through the existing
  SD `esfloppy_fw.bin` / `program_board.sh` flow.

### 3.2 Transport: internal "virtual serial cable"
- In WIFI mode the FPGA disconnects SCC channel A from the physical Serial A pins and connects it to a UART
  on the ESP32 over the comm bus. Mux location: where `TXDA/RXDA` (and chosen handshake signals) are
  driven/sampled in `top.sv` near the SCC instantiation (~L1224 in the fork; recheck line numbers).
- Lisa software sees an ordinary RS-232 port on Serial A → standard Lisa serial driver, LisaTerminal works
  for testing, SLIP/PPP can sit on the same link later.
- Physical Serial A pins are idle in WIFI mode. Serial B / USB console unaffected.
- Baud: start at 9600 then 19200 (a 400K image ≈ 3–6 min); raise later, SCC/ESP32 UART limits to be measured.

### 3.3 Comm bus pin plan (as implemented in `top.sv`; O1 verified against the PCB netlist)
| Bus bit | FPGA pin | ESP32 GPIO | Floppy mode | WiFi mode |
|---|---|---|---|---|
| [0] | M13 | 34 (`LEFT`) | LEFT echo (FPGA→ESP) | unchanged (buttons still echoed; unused by WiFi firmware) |
| [1] | R18 | 35 (`SEL`) | OK echo | unchanged |
| [2] | T18 | 36 (`RIGHT`) | RIGHT echo | unchanged |
| [3] | N14 | 37 (`FPGA_3`) | driven 0 | **MODE** = 1 (FPGA→ESP) |
| [4] | P14 | 38 (`FPGA_4`) | driven 0 | **FPGA TX → ESP RX** (the SCC's `TXDA`) |
| [5] | N17 | 39 (`FPGA_5`) | not driven (pull-up) | **ESP TX → FPGA RX** (into the SCC's `RXDA`); never driven by the FPGA |

Rules: [3]–[5] were free in FLOPPY mode, so no existing behaviour changes. Bit [5] is **never** driven by the FPGA
(XDC pull-up instead), so a WiFi firmware still running for a moment after a switch back to FLOPPY can't fight the
FPGA over the line. ESP32 side: GPIO37 = input (MODE), GPIO38 = UART RX, GPIO39 = UART TX; none are strapping pins.
**No hardware flow control in phase 1**: CTS/DCD/DSR into the SCC are held asserted in WIFI mode (O2 stays open;
if wanted later, [0]/[1] are the only candidates and are live button echoes in FLOPPY mode).

Mode switch plumbing: menu row `ESP32 MODE` → `esp_wifi_mode` (clk_pixel) → two 2-flop synchronisers in `top.sv`
(sysclk_fabric for the MODE pin so a saved WIFI mode reaches the ESP32 even with the Lisa off; DOTCK for the SCC mux),
false-pathed in the XDC. The SCC core already 2-FF-synchronises `rxda`/`ctsa`/`dcda`/`synca` itself.

### 3.4 Protocol (phased)
1. **Phase 1 — link + WiFi setup:** Hayes-style `AT` commands over the serial link: `AT` (ok), scan
   (`AT+WSCAN`), join (`AT+WJOIN="ssid","pass"`), status, IP info. Text-only so LisaTerminal can drive it
   before any Lisa app exists.
2. **Phase 2 — files (priority 1):**
   - Request/response binary or line-framed file protocol for list / get / put on the ESP32's SD card, with
     per-block CRC and resume.
   - ESP32-hosted **web UI** (HTTP on the LAN) to upload/download/rename/delete disk images — needs no Lisa
     app. Include a **"mount next"** setting persisted on the SD card that ESFloppy applies when the user
     switches back to FLOPPY mode (this also works around the broken OLED, which is the only way ESFloppy
     picks an image today).
3. **Phase 3 — client + network (priorities 2 and 3):** `AT`-style client commands (HTTP GET to text, NTP
   time, telnet/raw TCP passthrough), then SLIP for a real IP stack.
4. **LisaNet app (Lisa Pascal Workshop):** network picker/join UI, file browser/transfer over Serial A.
   Start only once Phase 1/2 work from LisaTerminal.

Security note: the web UI and any listener give LAN clients write access to the SD card — add a configurable
password or at least an "enabled only in WIFI mode / explicit toggle", never default-open.

## 4. Files to change

FPGA (this repo):
- `LisaFPGA.srcs/sources_1/imports/lisaStuff/top.sv` — mode register + synchronisers, comm-bus pin plan,
  SCC-A mux, persisting the new flag.
- `LisaFPGA.srcs/sources_1/imports/lisaStuff/HDMI_Interface.sv` — new menu row, output `esp_mode`.
- `LisaFPGA.srcs/sources_1/imports/lisaStuff/settings_flash.sv` (and wherever `settings_data` is laid out) —
  new flag bit(s).
- `LisaFPGA.srcs/constrs_1/imports/lisaStuff/LisaFPGA.xdc` — only if a pin's role changes (constraints
  exist already); remember **XDC rejects `if`/`proc`** (CLAUDE.md gotchas) and constrain new CDC crossings at
  clock level.
- `README.md`, `FAQ.md`, `CLAUDE.md` — document the mode and add a continuity pointer.

ESP32 (separate repo, to be forked as `wottle/ESFloppy`): mode watcher, WiFi personality, AT command
handler, file protocol, web UI. Not in this repo.

## 5. Build and flash (Windows/Vivado machine)

Same flow as the HDMI work (details in CLAUDE.md): Vivado 2026.1; synthesis takes ~85 minutes (do not kill
the silent phase), implementation ~50; `top.mcs` needs a separate `write_cfgmem` (`-format mcs -interface spix4
-size 16`, part `w25q128jvq-spi-x1_x2_x4`); flash with JTAG clock **3MHz** and `PROGRAM.ADDRESS_RANGE use_file`
so the settings block at `0xC00000` survives. Check **WHS as well as WNS**, and use `xvlog` as a seconds-long
syntax pre-check. Copy `top.mcs` back to the Mac for `program_board.sh` / openFPGALoader if preferred.
ESP32 firmware is built with Arduino (ESP32-S3 Dev Module, USB CDC on boot enabled) or installed via the SD
`esfloppy_fw.bin` mechanism.

## 6. Test plan

1. **Bench, no Lisa:** UART loopback — with the FPGA mux in WIFI mode, confirm bytes written by the ESP32
   appear on `RXDA` (ILA or scope) and vice versa.
2. Menu: toggle `ESP32 MODE` → ESP32 restarts into the other personality (check via its USB serial log);
   toggle back; setting survives power cycle after SAVE SETTINGS.
3. From LisaTerminal on the Lisa (Serial A): `AT`, scan, join, status.
4. Phase 2: upload an image from the web UI → appears on the SD card; set "mount next", switch to FLOPPY →
   ESFloppy mounts it; Lisa-side get/put round-trip with CRC check.
5. Regression: Serial B + USB console, physical Serial A in FLOPPY mode, HDMI, USB keyboard/mouse, timing
   summary (WNS/WHS, 0 failing endpoints other than the known 10 1080p60 pulse-width entries).

## 7. Open questions (resolve before/while implementing)

- **O1. RESOLVED (2026-10-10).** PCB netlist (`.epro2` is a zip; `PAD_NET` records) confirms FPGA M13/R18/T18/N14/P14/N17
  = `FPGA_0..5_ESFLOPPY` = ESP32-S3 pads 39–44 = GPIO34–39. ESFloppy's source only `#define`s `FPGA_3..5` (GPIO37–39) and
  never uses them. (Its `types.h` also lists stale `FPGA_6/7` = GPIO40/41, which are the SD pins.)
- **O2.** Open. Flow control: none in phase 1 (CTS/DCD/DSR tied asserted). Decide software (XON/XOFF) vs hardware later.
- **O3. RESOLVED.** The 80-bit payload is block bytes 4..13; byte 13 (bits 79:72) is reserved, written as 0 and covered
  by the checksum. **Bit 72 = ESP32 MODE (1 = WIFI)**; old blocks load as FLOPPY and still pass the checksum.
- **O4. RESOLVED.** All SCC-A signals are plain ports of `IO_board`, so the mux lives in `top.sv` without touching the SCC.
  Muxed: `RXDA` (from the ESP32), `CTSA`/`DCDA`/`SYNCA` (held asserted). `TXDA` goes to the ESP32 and the physical pin is
  parked at mark. `RTSA`/`DTRA`/`TRXCA`/`RTXCA` are left alone. Still to confirm on the Lisa: that the Office System's serial
  driver is happy with DCD/DSR/CTS permanently asserted.
- **O5.** ESFloppy teardown before restart: any pending SD writes to a mounted image must be flushed.
- **O6.** Achievable baud rate through the SCC core and ESP32 UART; whether the Office System serial driver
  tolerates > 19200.
- **O7.** ESP32 firmware home: new fork `wottle/ESFloppy` vs. patching in this repo's `ESFloppy_stub/`.
