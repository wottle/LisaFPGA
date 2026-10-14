# LisaNet link protocol (v1)

The file protocol spoken by ESFloppy's **SD-server personality**. Clients: the external WiFi board (over the FPGA
link) and a PC (over ESFloppy's USB port, for development). Part of ESP32 WiFi mode; see
`docs/superpowers/specs/2026-10-10-esp32-wifi-mode-design.md`.

## Transports

| Transport | Where | Settings |
|---|---|---|
| Link UART | ESFloppy GPIO38 (RX) / GPIO39 (TX), passed by the FPGA to J21 GPIO5 (into ESFloppy) / GPIO4 (out of ESFloppy) in ESP32 MODE = WIFI | 2,000,000 baud, 8N1 |
| USB CDC | ESFloppy's native USB port (development, PC client) | any baud |

The server answers on whichever transport a request arrived on. It may also print human-readable log lines on USB;
clients skip any bytes that are not part of a frame (log text never contains the sync byte 0xA5).

## Frames

```
offset  size  field
0       2     sync: 0xA5 0x5A
2       1     cmd   (requests 0x01-0x7F; a response sets bit 7: cmd | 0x80)
3       1     seq   (chosen by the client; echoed in the response)
4       2     len   payload length, little-endian, 0..4160
6       len   payload
6+len   4     crc   CRC-32 (IEEE 802.3, as zlib's crc32) of bytes 2 .. 5+len, little-endian
```

All integers are little-endian. Every response payload starts with a **status** byte. A frame with a bad CRC or an
impossible length is discarded without a response: the client times out (500 ms, longer for INFO and LIST) and
resends the same request with the same seq. Requests are designed to be safe to repeat: reads and writes carry
explicit offsets.

## Status codes

| Code | Name | Meaning |
|---|---|---|
| 0 | OK | |
| 1 | NOT_FOUND | no such file or directory |
| 2 | EXISTS | target already exists |
| 3 | IO | SD card read/write failed |
| 4 | BAD_REQUEST | malformed payload |
| 5 | NO_HANDLE | no file is open (or wrong handle) |
| 6 | UNKNOWN_CMD | |
| 7 | NO_CARD | the SD card could not be mounted |
| 8 | NO_CONTIGUOUS | OPEN mode 3: the card has no unbroken free run that large |

## Commands

Paths are UTF-8, absolute (`/images/LOS.dc42`), not NUL-terminated unless stated.

| Cmd | Name | Request payload | Response payload (after status) |
|---|---|---|---|
| 0x01 | HELLO | — | `u8 version (1)`, `u16 max_data (4096)`, firmware string |
| 0x02 | INFO | — | `u64 card_bytes`, `u64 free_bytes` (free space needs a FAT scan: allow ~10 s) |
| 0x10 | LIST | `u16 start_index`, path | `u16 next_index` (0xFFFF = end), then entries: `u8 flags` (bit0 = directory), `u64 size`, `u8 name_len`, name |
| 0x11 | STAT | path | `u8 flags`, `u64 size` |
| 0x20 | OPEN | `u8 mode` (0 read, 1 write: create + truncate, 2 write: create, keep contents, 3 write: create + truncate + reserve), for mode 3 a `u64 size`, then path | `u8 handle`, `u64 size` |
| 0x21 | READ | `u8 handle`, `u64 offset`, `u16 count` (<= max_data) | data (shorter at end of file) |
| 0x22 | WRITE | `u8 handle`, `u64 offset`, data (<= max_data) | `u16 written` |
| 0x23 | CLOSE | `u8 handle`, optional `u8 abandon` | — Completes the file: synced, and for a mode 3 upload moved onto its real name (replacing any old file there). `abandon` = 1 instead discards a mode 3 upload, leaving its target untouched. |
| 0x30 | DELETE | path (file or empty directory) | — |
| 0x31 | RENAME | old path, `0x00`, new path | — |
| 0x32 | MKDIR | path | — |
| 0x33 | COPY_START | source path, `0x00`, destination path, optionally `0x00` + backup path | `u64 size`. Copies on the card, into a reserved contiguous temporary file (NO_CONTIGUOUS if impossible). Without the backup field the destination must not exist. With it, the destination may exist: when the copy completes it is renamed to the backup path, or deleted if that is empty, and replaced -- in the same request. Starting a copy abandons any copy in progress. |
| 0x34 | COPY_STEP | — | `u64 copied`, `u64 total`. Copies up to 1 MB (about a second); repeat until copied = total, at which point the destination is synced and closed. NO_HANDLE if no copy is in progress. A failed or abandoned copy deletes its partial destination. |
| 0x40 | MOUNT_NEXT_SET | path (empty = clear) | — |
| 0x41 | MOUNT_NEXT_GET | — | path (empty = none) |

**Staging.** Mode 3 uploads and copies are written to temporary files in the hidden `/.LISANET` folder and moved onto their real names only when complete, inside one request (the completing CLOSE, or the last COPY_STEP). The server checks the MODE line only between requests, so a mode change -- such as the Lisa being switched on in WIFI HDD -- lands either before or after that move: the target is always the old file or the complete new one, never half-written. Opening another file, or a mode change, abandons an unfinished upload; temporary files left behind are deleted when the server next starts.

One file can be open at a time; OPEN closes any file already open. OPEN abandons an unfinished mode 3 upload rather than completing it. **Upload disk images with mode 3:** ESFloppy only
mounts an image stored in one unbroken run of sectors (it writes tracks straight to raw sectors), and mode 3 reserves
the whole size contiguously up front (SdFat `preAllocate`), failing with NO_CONTIGUOUS rather than storing it
fragmented. LIST pages: send `start_index` 0, then the
returned `next_index` until it is 0xFFFF. MOUNT_NEXT stores an image in `/.LISANET/MOUNTNXT.TXT` (a dot folder, so the file picker hides it); ESFloppy
mounts it in drive 1 (the Sony drive, or the lower Twiggy) **every** time it starts in FLOPPY mode, until cleared.

## FPGA control frames

The FPGA itself also listens on the WiFi board's link TX (J21 GPIO5), in every ESP32 mode, for frames addressed to it.
It answers on J21 GPIO4, the line back to the WiFi board. Implemented in `LisaFPGA.srcs/sources_1/new/lisanet_ctrl.sv`
(FPGA) and `firmware/lisanet_wifi/fpgactl.cpp` (WiFi board).

```
offset  size  field
0       4     marker: C3 3C 96 69
4       1     cmd   (requests 0x01-0x7F; the reply sets bit 7)
5       1     seq   (echoed in the reply)
6       1     len   payload length (requests at most 8)
7       len   payload
7+len   4     CRC-32 (zlib) of bytes 4 .. 6+len, little-endian
```

Same 2 Mbaud 8N1 as the SD link. The SD servers skip anything that is not their own `A5 5A` frame, so control frames pass
them by -- **the sender must choose seq so that no byte of the frame is `A5`**. The 4-byte marker plus the CRC mean SD
traffic, even uploaded file data, effectively never parses as a control frame. In the WiFi modes GPIO4 normally carries
the serving ESP32's TX, so the FPGA starts a reply only after that line has been idle for 20 us; the WiFi board sends a
control frame only while it has no SD request outstanding, so the ESP32 is silent. A frame with a bad CRC gets no reply.

| Cmd | Name | Request payload | Reply payload (after status) |
|---|---|---|---|
| 0x01 | STATUS | — | `u8 version (1)`, 11-byte status block, `u16` XADC temperature code (degrees C = code x 503.975 / 65536 - 273.15) |
| 0x02 | SET | `u8 reg`, `u16 value` | — |
| 0x03 | ACTION | `u8 action`: 1 save settings, 2 press the Lisa's power button, 3 press reset (each press lasts 250 ms) | — |

Status: 0 OK, 1 BAD_REQUEST, 2 LOCKED (ESP32 mode while the Lisa is on), 3 BUSY (the FPGA did not take the write within
200 ms), 4 UNKNOWN_CMD.

SET registers, applied on the next video frame with the on-screen menu's limits and locks: 1 resolution (0 1080p30,
1 1080p60, 2 1024x768 where built), 2 H offset and 3 V offset of the live mode (clamped to its room), 4 max contrast
(the effective setting; the jumper is folded in), 5 CPU speed (0 follow the switches, 1-4 = 5 / 10 / 15 / 18.75 MHz),
6 ESP32 mode (0 NORMAL, 1 WIFI FDD, 2 WIFI HDD; only with the Lisa off). Like the menu, changes last until power-off
unless saved.

Status block (little-endian): 0 resolution; 1 flags (bit 0 max contrast, 1 Lisa on, 2 WiFi board present, 3 ESP32 WIFI,
4 target HDD, 5 a saved block exists, 6 saving, 7 CPU speed chosen); 2 bits 0-1 CPU speed index, 2 1024x768 built in,
3 resolution chosen, 4 3A ROM, 5 MAX CONTRAST jumper; 3-4 H offset, 5-6 H limit, 7-8 V offset, 9-10 V limit.
