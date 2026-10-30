# LisaNet: the LisaFPGA WiFi board

LisaNet adds WiFi to a LisaFPGA (rev 3) board with a small, cheap ESP32 board plugged into the spare **J21** header.
Through a web page at `http://lisanet.local/` it lets you:

- **Manage the SD cards** of the onboard floppy and hard disk emulators: list, upload, download, rename, delete,
  copy to `profile.image`, and choose the floppy ESFloppy mounts at start-up (**Files** tab, with the Lisa off).
- **Change the LisaFPGA's settings** that the on-screen menu has: resolution, image position, CPU speed, contrast,
  plus scanlines, inverse video, the ROM switches and the RAM size; save them; press the Lisa's power, reset and NMI
  buttons; and watch the FPGA's temperature (**Settings** tab).
- **Insert and eject floppies** while the Lisa is running.
- **Act as a FujiNet** on the Lisa's Serial B, for Lisa programs written for an RS-232 FujiNet, such as
  [LisaFuji](https://github.com/GyroPilot/Apple-LisaFuji) (news, Wikipedia, weather, the network clock).
- **Act as a Hayes-style modem** on the Lisa's Serial A (AT commands, for LisaTerminal) while ESFloppy's files are being managed (Manage ESFloppy files; WIFI FDD in the menu).
- **Update itself over WiFi.**

Why an external board: the rev 3 board's own ESP32-S3s (ESFloppy and ESProFile) have no antenna -- their RF pin is
not connected on the PCB -- so they cannot use WiFi. The WiFi board does the WiFi and asks ESFloppy or ESProFile to
serve its SD card over a fast serial link that passes through the FPGA.

## What you need

| Part | Notes |
|---|---|
| **Seeed Studio XIAO ESP32S3** | The plain XIAO ESP32S3 (the "Sense" version with the camera also works). It has 8 MB of flash, which the firmware needs for over-the-air updates. **Fit the antenna that comes with it** (the small U.FL patch antenna): without it WiFi range is a few centimetres. Known to work: the *Seeed Studio XIAO ESP32S3 & Wio-SX1262 Meshtastic LoRa Dev Kit*. Only its XIAO is used (not the Wio-SX1262 LoRa board); keep the XIAO's own 2.4 GHz WiFi antenna on it (the larger of the kit's two; the small rectangular one belongs to the LoRa board). It arrives running Meshtastic, which the first flash replaces. |
| 5 or 6 female-to-female Dupont wires | To J21. |
| A USB-C cable | For the first flash, and optionally to power the XIAO. |
| LisaFPGA FPGA firmware with LisaNet | This fork's `main` (the LisaNet builds: ESP32 MODE in the on-screen menu). The FujiNet needs the 2026-10-22 build or later (FPGA control version 3). |
| ESFloppy and ESProFile LisaNet firmware | For SD card management and the floppy remote: the `main` branches of [wottle/ESFloppy](https://github.com/wottle/ESFloppy) and [wottle/ESProFile](https://github.com/wottle/ESProFile). This fork's `program_board.sh` installs them. Without them the Settings tab and the FujiNet still work, but the Files tab cannot reach the cards. |

## Wiring

J21 is a 2x4 header (2.54 mm). Pin 1 is the square pad / the one marked on the silkscreen; odd pins are in one row and
even pins in the other:

```
            J21 (looking at the pins)
         +-----------+-----------+
  pin 1  |  GPIO0    |  GPIO4    |  pin 2   -> XIAO D7
  pin 3  |  GPIO1    |  GPIO5    |  pin 4   -> XIAO D6
  pin 5  |  GPIO2    |  GND      |  pin 6   -> XIAO GND
  pin 7  |  GPIO3    |  3V3      |  pin 8   -> XIAO 3V3 (optional, see Power)
         +-----------+-----------+
   pin 5 -> XIAO D0        pin 7 -> XIAO D1
```

| J21 pin | FPGA signal | XIAO pin | Direction | Carries |
|---|---|---|---|---|
| 5 | GPIO2 | **D0** (GPIO1) | board -> XIAO | the Lisa's Serial A (modem) or Serial B (FujiNet) transmit data |
| 7 | GPIO3 | **D1** (GPIO2) | XIAO -> board | into the Lisa's Serial A or B receive |
| 2 | GPIO4 | **D7** (GPIO44, RX) | board -> XIAO | from the SD card server and from the FPGA itself |
| 4 | GPIO5 | **D6** (GPIO43, TX) | XIAO -> board | to the SD card server and to the FPGA itself |
| 6 | GND | **GND** | | |
| 8 | 3V3 | **3V3** | | optional power, see below |
| 1, 3 | GPIO0, GPIO1 | -- | | leave unconnected: they are the board's spare jumper inputs |

Notes:
- **D7 must go to pin 2.** It is the only line back to the XIAO: if it is wrong, the web page says the FPGA is not
  answering *and* the SD cards are unreachable.
- The FPGA only drives J21 when it sees a WiFi board there (a powered XIAO holds pin 4 high), so the header is safe
  with nothing plugged in, and the ESP32 MODE menu row only appears once the board is detected (about 2 s).

### Power

Power the XIAO **one** way:

- **From its own USB-C** (a phone charger or a computer). Leave J21 pin 8 unconnected. Easiest while setting up.
- **From J21 pin 8 (3V3)**, so nothing else is needed once it is installed. The board's 3.3 V regulators have plenty of
  headroom for the XIAO's WiFi bursts.

**Never both at once**: with 3V3 wired from J21, unplug the J21 pin 8 wire before plugging a USB-C cable into the XIAO
(for example to re-flash it), or the XIAO's regulator and the board's 3.3 V rail fight each other.

**Never connect anything to the XIAO's 5V pin.** On a USB-powered XIAO that pin is the computer's USB 5 V: a wire
slipping onto it can short the computer's USB port (it trips the port's protection; a reboot brings it back).

## First flash

This is done once, over USB. After it, updates go over WiFi (see below). You do not need to build anything: the
repository holds a ready-made image, `firmware/lisanet_wifi/release/lisanet_wifi_factory.bin`.

### 1. Install esptool

```bash
pip install esptool
```

(or `brew install esptool` on a Mac).

### 2. Put the XIAO in download mode and flash

1. Plug the XIAO into the computer by USB-C (with J21 pin 8 unconnected, see Power).
2. A new XIAO runs Seeed's demo firmware, which cannot be uploaded to automatically: **hold the B (BOOT) button, tap
   R (RESET), release B.** A new port appears: `COMn` on Windows, `/dev/cu.usbmodem...` on a Mac, `/dev/ttyACM0` on Linux.
3. Erase and flash (use your port in place of `COM7`), running both commands straight away, because a reset leaves
   download mode:

   ```bash
   esptool --chip esp32s3 -p COM7 --after no-reset erase-flash
   esptool --chip esp32s3 -p COM7 --before no-reset write-flash 0x0 firmware/lisanet_wifi/release/lisanet_wifi_factory.bin
   ```

4. **Press R once** by itself. After a manual download mode the chip can otherwise keep restarting into the loader
   ("waiting for download").

### Building it yourself (developers)

Only needed if you change the firmware. Use [arduino-cli](https://arduino.github.io/arduino-cli/) or the Arduino IDE 2
with the ESP32 Arduino core **3.3.12**:

```bash
arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core update-index
arduino-cli core install esp32:esp32@3.3.12
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3 --output-dir firmware/lisanet_wifi/build firmware/lisanet_wifi
```

Keep the board's default options (they include the 8 MB partition table with the two firmware slots that WiFi updates
need). To upload a build directly, use `arduino-cli upload --fqbn esp32:esp32:XIAO_ESP32S3 -p COM7 --input-dir
firmware/lisanet_wifi/build firmware/lisanet_wifi`. Every time the version changes, refresh `release/`:
`lisanet_wifi.ino.bin` is the build's app image, and `lisanet_wifi_factory.bin` is the build's `.merged.bin` with the
trailing empty padding removed (it ends at the first 4 KB boundary after the app).

### 4. Check that it runs

Open the XIAO's USB serial port at 115200 baud **with DTR on** (it sends nothing until DTR is set; opening the port
restarts it). It prints `[lisanet] LisaNet WiFi board <version>` and then what WiFi is doing. Any terminal works;
`tools/lisanet_client/xiao_term.ps1 -Port COM7` is a small PowerShell one. The same port takes AT commands: type
`AT+HELP`.

## Getting it onto your WiFi

With no network saved, the XIAO starts its own network:

1. On a phone or computer, join **`LisaNet-Setup`**, password **`lisanet-setup`**. A phone usually pops up the setup page
   by itself; otherwise browse to `http://192.168.4.1/setup`.
2. Pick your network, type its password, and choose a **web page password** (4 characters or more). The web page's
   user name is **`lisa`**.
3. The XIAO joins your network and turns the setup network off a minute later.

Then browse to **`http://lisanet.local/`** (or the XIAO's IP address, shown on the USB console and by `AT+WIP`).

- If the saved network cannot be found for a minute, the setup network comes back, and the XIAO keeps looking for the
  saved one every few minutes.
- **Holding the B button for 5 seconds** forgets the network and the web password and starts setup from scratch.
- The same can be done with AT commands, on the USB console, or from LisaTerminal on Serial A while managing ESFloppy files:
  `AT+WSCAN`, `AT+WJOIN="network","password"`, `AT+WEBPASS="password"`.

The web page uses HTTP Basic authentication over plain HTTP: fine on a home network, not for the internet.

## Installing it in the LisaFPGA

1. With the LisaFPGA switched off, wire the XIAO to J21 as above. Then supply power to the LisaFPGA and flip the
   LisaFPGA's power switch on: that powers both the LisaFPGA and the XIAO ESP32-S3, through J21's 3V3 pin. (If you
   power the XIAO from its own USB-C instead, see Power above, plug that in as well.)
2. Within a couple of seconds the on-screen menu (hold LEFT + RIGHT for about 3 s) shows **ESP32 MODE** as its first
   row, and the web page's **Settings** tab answers.
3. The **ESP32 mode** card on the Settings tab (ESP32 MODE in the on-screen menu) picks what the SD cards are doing:
   - **Normal** (menu: NORMAL): both emulators are the Lisa's drives, as usual. The Settings tab, the floppy remote and
     the FujiNet work; Serial A is its own port.
   - **Manage ESFloppy files** / **Manage ESProFile files** (menu: WIFI FDD / WIFI HDD): that drive's SD card opens in
     the **Files** tab, which only appears in these two modes, and the drive is offline meanwhile; the Lisa's Serial A
     goes to the XIAO's AT modem. These can only be chosen with the Lisa off. Switching the Lisa on drops Manage
     ESProFile files back to Normal (the Lisa needs its hard disk) and the Files tab closes; Manage ESFloppy files
     stays, so the modem can be used from a running Lisa.
   Press **Save settings** to keep any setting across a power cycle.

## Using the FujiNet (Serial B)

1. On the Settings tab's **FujiNet (Serial B)** card, set **Serial B** to **This WiFi board (FujiNet adapter)**. The
   Lisa's Serial B then goes to the XIAO instead of its own connector; no cable is needed. It shares the XIAO's two
   serial wires with the Serial A modem, so while it is on, Serial A is its own port in every mode.
2. Set the **baud rate** to what the Lisa program uses (LisaFuji: 9600 or 19200, from its Speed menu) and your **time
   zone** in POSIX form, for example `EST5EDT,M3.2.0,M11.1.0` (US Eastern) or `CET-1CEST,M3.5.0,M10.5.0/3`
   (Central Europe). The network clock comes from internet time.
   The FujiNet has only been tested at **9600 and 19200 baud**. The card offers rates up to 115200, but higher ones are
   untested.
   Lisa programs can also change the speed themselves (LisaFuji 1.2 and its sibling tools: the Speed or Network menu).
   They do it the way a real FujiNet's web page does, a POST of `serial_baud=` and then `resetfuji` to the adapter's
   `/config`, which this board answers itself; the speed changes once the reset is answered. A speed set from the Lisa
   applies at once but, like the card's own settings, is only kept across a restart by **Save settings**. Those
   programs look for the adapter at 9600 and at 19200 when they start, so they find it either way.
3. Press **Save settings** to keep all three.
4. In Lisa Office System, set Serial B to **Serial Cable** in the Preferences tool, then run the program.

The card shows how many requests the Lisa made and a log of them, including anything the adapter does not support.
It answers HTTP and HTTPS (GET, POST, PUT, DELETE), the JSON parser, the network clock, and the FujiNet's status and
adapter information. HTTPS certificates are not checked.

**Bench test**: the Serial B setting's third choice wires the board's *own* Serial B port to the XIAO instead, so a PC
can stand in for the Lisa: `tools/lisanet_client/fujinet_test.ps1 -Port COMn` on the board's "LisaFPGA Serial B" USB
port. The board's SERIAL B SOURCE switch must be at USB for that, since it chooses where Serial B's receive line comes
from.

## AI chat for Lisa programs (chat://)

On the FujiNet's network units the board also offers a chat endpoint, so a Lisa program can talk to Claude or ChatGPT with
the same calls it uses to fetch a web page. The board keeps the API keys; the Lisa never sees them.

**Setting it up:** AI chat is **off by default**: while it is off nothing is ever sent to an AI service, and a Lisa program that opens `chat://` gets `[error: AI chat is turned off ...]`. On the Settings tab, in the *AI chat* card, tick *Enable AI chat*, then enter an API key for Claude and/or OpenAI, check the model
names (Claude defaults to `claude-sonnet-5-5`; the OpenAI default `gpt-4o-mini` is only a placeholder, so use a model your
account has), and press *Save chat settings*. These are kept at once. *Try it* asks one question outside the Lisa's
conversation, which is the quickest way to check a key and model.

*Reply timeout* (default 60 s, 10 to 65 s) is how long the board waits for the AI service's answer. A hard question with a
long *Reply length* can take a while; if one comes back as `[error: no answer within N s ...]`, raise the timeout or
lower the reply length. 65 s is the most the ESP32's HTTP client can wait (before 0.18 the board meant to wait 70 s but
actually gave up after about 4.5 s). The Lisa program must also be willing to wait that long for its answer.

**What a Lisa program does** (N: unit, any of N1-N8):

| Step | FujiNet call | Notes |
|---|---|---|
| open | `OPEN` with the URL `chat://claude`, `chat://openai` or `chat://` (the default provider) | any open mode. A STATUS straight after the OPEN, as LisaFuji's FnNOpen sends, is fine: it reports connected, 0 bytes, and sends nothing |
| ask | `WRITE` the question as text | one or more writes; trailing CR/LF is ignored |
| wait | `STATUS` until bytes are waiting | the first STATUS (or READ) sends the question. While the model thinks, STATUS says 0 bytes waiting and *connected*; an answer ends with *not connected* and the bytes waiting. Expect 2-30 s. |
| read | `READ` | plain ASCII; line ends follow the unit's translation setting (SET_EOL / TRANSLATION), `\n` with none |
| close | `CLOSE` | ask the next question with a new `OPEN` |

`chat://reset` forgets the conversation: open it, read `OK`, close. Each provider has its own conversation, kept in RAM
(the last *Memory* messages, 6000 bytes at most) and lost on a restart. Only one question runs at a time; a second one gets
`[error: the chat is busy with another question]`.

Errors come back as the answer text, in square brackets, so a Lisa program needs no separate error path: `[error: no
Claude API key set ...]`, `[error: HTTP 401, check the API key]`, `[error: no connection (...)]`, and so on.

The answer is converted to ASCII: curly quotes, dashes, bullets and accented Latin letters become plain ones, emoji and other
scripts are dropped, markdown marks (`**`, `` ` ``, `#`, `* `) are removed. The default instructions also ask the model for
short plain text; change them on the page. The HTTPS connection checks the provider's certificate against two built-in roots (Google Trust Services R1 and R4, which both
APIs chain to; see `chat_roots.h`), so the board's clock must be set (it learns the time over NTP shortly after joining WiFi). If a
provider ever moves to another certificate authority, calls fail with a "no connection" error: untick *Verify certificates*
on the page and add the new root to `chat_roots.h`.

Host tests for the conversion, history and request code: `g++ -std=c++17 -Wall -I.. test/test_chatcore.cpp chatcore.cpp -o
/tmp/test_chatcore && /tmp/test_chatcore` from this folder (`chat.cpp` is the part that needs the board).

## Updating over WiFi

On the Settings tab, **WiFi board firmware -> Install update...**, and choose `lisanet_wifi.ino.bin` from the build
folder (**not** `lisanet_wifi.ino.merged.bin`, which is refused). The XIAO restarts into the new version, which has to
run for 20 seconds before it is kept: if it crashes sooner, the XIAO goes back to the previous version by itself, and
**Go back to** on the card returns to the previous version by hand. Only images of this firmware are accepted.

If an update ever leaves the web page unreachable, flash over USB again as in First flash.

## Troubleshooting

| Symptom | Look at |
|---|---|
| "The FPGA is not answering" | The D7 -> J21 pin 2 wire; and that the FPGA runs a LisaNet build. |
| No Files tab | It only appears in Manage ESFloppy files or Manage ESProFile files (Settings tab). |
| Files tab: "No SD card server is reachable" | The drive takes a few seconds to restart as the server; if it persists, ESFloppy / ESProFile must run the LisaNet firmware. |
| No ESP32 MODE row in the menu | The XIAO is not powered, or D6 is not on J21 pin 4 (that is how the board detects it). |
| The XIAO keeps saying "waiting for download" | Press R once by itself. |
| The USB console shows nothing | Turn DTR on in the terminal. |
| The FujiNet card is missing | The FPGA build predates the FujiNet (control version 3). |
| A Lisa FujiNet program gets no answer | Serial B set to This WiFi board, matching baud rates, and Serial Cable in the LOS Preferences. |

## For developers

- `lisanet_wifi.ino` -- start-up and the main loop. Everything runs from `loop()` on one task, so the serial link is
  never used by two things at once.
- `web.cpp`, `page.cpp`, `setup_page.cpp` -- the web server, the page and the setup page.
- `sdlink.cpp` -- the SD card link to ESFloppy / ESProFile; `fpgactl.cpp` -- the FPGA's own control frames on the same
  link. Both are described in [docs/lisanet_link_protocol.md](../../docs/lisanet_link_protocol.md).
- `fujinet.cpp` -- the FujiNet adapter (FujiBus over SLIP, written from the protocol as fujinet-firmware implements it).
- `atmodem.cpp` -- the AT modem; `wifisetup.cpp` -- the setup network; `ota.cpp` -- updates over WiFi.
- `config.h` -- pins, baud rates, and `LISANET_WIFI_VERSION`: bump it for every release, because the web page tells
  versions apart by that string.
