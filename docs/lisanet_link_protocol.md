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
