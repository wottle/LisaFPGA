# LisaNet setup: from a bare board to WiFi

This is the whole path, in order: flash the LisaFPGA board, flash the XIAO ESP32-S3, wire the XIAO to the board, and join it to your WiFi.
Each step says what you should see before you go on. The XIAO details (tools, build, WiFi setup page, FujiNet, chat) are in
[firmware/lisanet_wifi/README.md](../firmware/lisanet_wifi/README.md); this page ties the pieces together.

## What you need

- A LisaFPGA rev 3 board, a data-capable USB-C cable, and a Mac or Linux computer for `program_board.sh`
  (the script does not run on Windows).
- A Seeed Studio **XIAO ESP32S3** with its U.FL antenna fitted, 5 or 6 female-to-female Dupont wires, and a second
  USB-C cable (or the same one, moved).
- This fork, cloned: `git clone https://github.com/wottle/LisaFPGA.git` (not upstream).

The board's own ESP32-S3s (ESFloppy and ESProFile) have no antenna connected, so they cannot do WiFi. The XIAO does the
WiFi and reaches their SD cards over a serial link that passes through the FPGA.

## 1. Flash the LisaFPGA board

Plug the board into the computer, switch the board on, and from the top of the clone run:

```bash
./program_board.sh
```

It installs what it needs, then programs the USB chips, ESProFile, ESFloppy and the FPGA bitstream. If any step fails,
switch the board off and on and run it again. When it says it is done, switch the board off and on.

Everything LisaNet needs comes from this one run:

- **The FPGA bitstream** is the committed `LisaFPGA.runs/impl_1/top.mcs`: the LisaNet build with the FujiNet (FPGA
  control version 3, built and flashed 2026-10-22). To flash it alone, without the script:

  ```bash
  openFPGALoader --cable ft232 --fpga-part xc7a100tcsg324 --write-flash LisaFPGA.runs/impl_1/top.mcs
  ```

- **ESFloppy and ESProFile** are built from this fork's own firmware, the `main` branches of
  [wottle/ESFloppy](https://github.com/wottle/ESFloppy) and [wottle/ESProFile](https://github.com/wottle/ESProFile):
  Alex's firmware plus the SD card server the Files tab uses, ESFloppy's floppy remote and its dead-OLED guard. If an
  earlier run of the script left clones of Alex's repositories in the checkout, it switches them over to these.

**You should see:** the board boots to the Lisa display as usual. Hold LEFT + RIGHT for about 3 seconds and the
on-screen menu appears. There is no ESP32 MODE row yet; it appears once the XIAO is connected.

## 2. Flash the XIAO ESP32-S3 (once, over USB)

Do this before wiring it into the board. Full details are in the
[firmware README](../firmware/lisanet_wifi/README.md#first-flash); the short version:

```bash
arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core update-index
arduino-cli core install esp32:esp32@3.3.12
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3 --output-dir firmware/lisanet_wifi/build firmware/lisanet_wifi
```

Then plug the XIAO into the computer by USB-C, put it in download mode (**hold B, tap R, release B**), and upload with
your port in place of `COM7` (Mac: `/dev/cu.usbmodem...`, Linux: `/dev/ttyACM0`):

```bash
arduino-cli upload --fqbn esp32:esp32:XIAO_ESP32S3 -p COM7 --input-dir firmware/lisanet_wifi/build firmware/lisanet_wifi
```

Press **R once** afterwards. Keep the board's default Tools options (the 8 MB partition table is needed for updates over WiFi).

**You should see:** open the XIAO's USB serial port at 115200 baud **with DTR on**; it prints
`[lisanet] LisaNet WiFi board <version>`. Typing `AT+HELP` lists the commands.

## 3. Wire the XIAO to the LisaFPGA (J21)

Switch the LisaFPGA **off** first. J21 is the 2x4 header; pin 1 is the square pad.

| J21 pin | FPGA signal | XIAO pin |
|---|---|---|
| 5 | GPIO2 | **D0** |
| 7 | GPIO3 | **D1** |
| 2 | GPIO4 | **D7** |
| 4 | GPIO5 | **D6** |
| 6 | GND | **GND** |
| 8 | 3V3 | **3V3** (only if you power the XIAO from the board) |
| 1, 3 | GPIO0, GPIO1 | leave unconnected (the board's jumper inputs) |

- **D7 must go to J21 pin 2.** It is the only line back to the XIAO.
- **Power the XIAO one way only:** either its own USB-C with pin 8 left unconnected, or the J21 pin 8 wire. Never both at
  once: unplug the pin 8 wire before you connect USB-C to the XIAO to re-flash it.
- **Never wire anything to the XIAO's 5V pin.**

## 4. Power on and check the link

1. Power the XIAO (USB-C, or just switch the LisaFPGA on if you wired 3V3).
2. Switch the LisaFPGA on.
3. **You should see:** within about 2 seconds the on-screen menu (LEFT + RIGHT, about 3 s) shows an **ESP32 MODE** row.
   That row only appears when the FPGA detects the XIAO's D6 line on J21 pin 4. If it never appears, check D6 to pin 4
   and the XIAO's power, and confirm the FPGA is running a LisaNet build (step 1).

## 5. Join your WiFi

With no network saved, the XIAO starts its own:

1. Join **`LisaNet-Setup`** (password **`lisanet-setup`**) from a phone or computer. The setup page usually opens by
   itself; otherwise browse to `http://192.168.4.1/setup`.
2. Pick your network, enter its password, and choose a web page password (4 characters or more). The user name is `lisa`.
3. Wait a minute, then browse to **`http://lisanet.local/`** (or the IP address shown on the XIAO's USB console).

**You should see:** the LisaNet page. The **Settings** tab shows the FPGA answering (temperature, resolution, CPU speed).
If it says "The FPGA is not answering", check the D7 wire and the FPGA build. Holding the XIAO's B button for 5 seconds
forgets the network and password and starts setup again.

## 6. Pick what the SD cards do

On the Settings tab (or the ESP32 MODE row in the on-screen menu), choose:

- **Normal**: ESFloppy and ESProFile are the Lisa's drives. The Settings tab, floppy remote and FujiNet work.
- **Manage ESFloppy files** / **Manage ESProFile files**: that card opens in the **Files** tab (the Lisa must be off).

For a FujiNet on Serial B (LisaFuji and similar), set **Serial B** to *This WiFi board* on the Settings tab, match the
baud rate, and set Serial Cable in the LOS Preferences. The FujiNet has only been tested at 9600 and 19200 baud.

## After the first time

- Update the XIAO over WiFi (Settings tab, **WiFi board firmware -> Install update...**, `lisanet_wifi.ino.bin`); no
  cable needed.
- Updating the FPGA again later means `top.mcs` and `program_board.sh` (or `openFPGALoader` as above). The saved menu
  settings live in a separate flash block and survive a re-flash.
- If a flash fails, switch the board off and on and retry; do not give up half-way through a bitstream write.
