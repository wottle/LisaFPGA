# USB host on a soft CPU — design

Branch `feature/usb-hub-support`. Status: **phase 0 done in simulation** (2026-10-05).

## Progress log
- **Phase 0 (2026-10-05):** toolchain = xPack riscv-none-elf-gcc 15.2.0-1 (sha256 verified), unpacked to
  `tools/toolchain/` (git-ignored). PicoRV32 vendored from YosysHQ/picorv32 at `ef203c2` into
  `LisaFPGA.srcs/sources_1/imports/picorv32/` with its ISC `COPYING`. `usb_softcpu.sv` (CPU + 32 KB RAM +
  MMIO) boots `tools/usb_fw` firmware in xsim (`build.ps1`, then `sh tools/usb_fw/sim/run.sh`): console output
  and the µs timer both work. Out-of-context synth + route on the real part: **1259 LUTs, 558 FFs, 8 RAMB36
  (RAM inferred as block RAM), WNS +7.1 ns at 60 MHz**, 0 critical warnings. Not yet in `top.sv` or the
  `.xpr`. `updatemem` can only be tried once it is in a full bitstream.
  Gotcha already hit: the linker must 4-byte-align `__bss_start`; PicoRV32 with `CATCH_MISALIGN` traps on the
  start-up zeroing loop otherwise.

## Goal

Make the Apple keyboards with built-in hubs work, and stop needing per-device VID/PID entries, by replacing
the m1nl microcode core with a small RISC-V CPU running a C USB host stack over a new packet engine.

Parity with today is the floor: everything that works on the flashed build must keep working —
Lenovo keyboard and mouse (low speed), the wired gaming keyboard and G815 (full speed), the Keychron and
Logitech receivers, the Mighty Mouse.

## What the target devices need (measured 2026-10-05 from their descriptors on Windows)

| Device | Hub | Keyboard behind it | Notes |
|---|---|---|---|
| Older Apple keyboard | 05AC:1001, full speed, 3 ports, **ganged** power, 100 ms power-good | 05AC:0201, **full speed**, **hub port 1**, boot keyboard on EP `0x81`, 8 B / 10 ms | ports 2-3 are the external sockets |
| Aluminium Apple keyboard | 05AC:1006, USB 2.0 hub running at full speed, 3 ports, **per-port** power, 100 ms power-good | 05AC:0220, **full speed**, **hub port 2**, boot keyboard on EP `0x81` (IF0); IF1 = 1-byte vendor/consumer on `0x82` | per-port overcurrent and indicators: ignorable |
| Logitech G815 | none — its "USB port" is a passthrough cable, not a hub | 046D:C33F, full speed, boot keyboard IF0 EP `0x81`, 1 ms | asks for 500 mA |

Consequences:
- **No PRE packets needed for either Apple keyboard** — the keyboards themselves are full speed. PRE is only
  needed to reach a *low-speed* device plugged into a keyboard's socket (e.g. the Lenovo mouse). It is a later
  phase, but the engine is designed so it can be added without rework.
- The keyboard's hub port differs (1 vs 2), so the host must discover it at runtime from the hub's
  status-change endpoint. Powering every port individually works for both ganged and per-port hubs.

## Architecture

```
            usbclk_core (60 MHz, existing usb_fs_clock — no new clock, BUFGCTRL stays 28/32)
 ┌────────────────────────────────────────────────────────────────────────────┐
 │  PicoRV32 (RV32IC) ── 32 KB BRAM (code+data, $readmemh firmware.mem)        │
 │       │ native mem bus                                                       │
 │       ├── usb_sie port 0 ── MOUSE_DP/DN                                      │
 │       ├── usb_sie port 1 ── KBD_DP/DN                                        │
 │       ├── report regs: keyboard {mods, keys[6]} + strobe, mouse {btn,dx,dy}  │
 │       ├── timer (µs counter), debug word, optional debug UART               │
 └───────┼─────────────────────────────────────────────────────────────────────┘
         └── existing xpm_cdc_handshake ──► usb_keyboard_interface / usb_mouse_interface (12 MHz, UNCHANGED)
```

### CPU: PicoRV32
- ISC licence (permissive), single Verilog file, well proven on Artix-7, ~1.5k LUTs as RV32IC with no
  multiplier. At 60 MHz it gives roughly 15 MIPS, far more than USB control needs once the packet engine
  owns all bit-level timing.
- Runs on `usbclk_core` itself, so the CPU, the engine and the report registers share one domain; the only
  clock crossing is the existing one into the 12 MHz Lisa side.
- No interrupts: one polling main loop.

### Packet engine: `usb_sie` (new RTL, one instance per root port)
Everything with microsecond deadlines lives here; the CPU only deals in whole transactions.
- **Line handling:** connect/disconnect and speed detection from idle polarity, bus reset (timed in absolute
  µs, the lesson from the spike), SOF every 1 ms at full speed / keep-alive EOP at low speed, generated
  automatically with a frame counter.
- **Transactions:** the CPU writes PID, address, endpoint, data toggle, speed and an optional OUT payload into
  a small buffer, then sets GO. The engine sends the token (CRC5 in hardware), the DATA packet (CRC16),
  receives the response with a turnaround timeout, checks CRC16 and toggle, **sends the ACK itself** (the
  7.5-bit-time deadline is far too short for software), and posts a result: ACK / NAK / STALL / TIMEOUT /
  CRC_ERR / BABBLE, plus a received byte count.
- **Frame guard:** refuses to start a transaction that could collide with the next SOF.
- **Speed per transaction**, not per port, and a PRE flag reserved in the command register for phase 4.
- Bit timing at 60 MHz: 5 clocks/bit at full speed, 40 at low speed; receive resynchronises on every edge.
  Written fresh (not derived from the microcode core), with the m1nl receiver as a reference for the sampling.

### Firmware: a small custom C stack (no libc, no RTOS)
Porting TinyUSB was considered and rejected: its host side expects an interrupt-driven controller and a
scheduler, and pulls in far more than three device classes need. The custom stack is roughly 1.5-2k lines:
- `sie.c` — register access, control transfers (SETUP/DATA/STATUS with retries), interrupt-IN polling.
- `enum.c` — reset, GET_DESCRIPTOR(device, 8), SET_ADDRESS, full device and configuration descriptors,
  SET_CONFIGURATION. Device table of up to 8 devices, hub depth limit 2.
- `hub.c` — GET_HUB_DESCRIPTOR, SET_PORT_FEATURE(POWER) on every port, wait bPwrOn2PwrGood, poll the
  status-change endpoint, GET_PORT_STATUS, clear change bits, reset a port, read the child's speed,
  enumerate it; detach tears down the subtree.
- `hid.c` — **picks interfaces by their HID report descriptor**, not by class codes: an interface is a keyboard
  if it has a Generic Desktop / Keyboard application collection, a mouse if Generic Desktop / Mouse. This is
  what makes the Keychron work without a table (its interface 1 *claims* boot keyboard but is a barcode reader
  and gamepad). Then SET_PROTOCOL(boot) and SET_IDLE on the chosen interface, and poll its IN endpoint at
  its bInterval. Reports are boot-format, so they feed the existing Lisa-side decoders unchanged.
- `out.c` — writes keyboard/mouse reports to the report registers. On detach, an empty report releases held
  keys (same behaviour as today).

Keyboards and mice become **channels, not ports**: any keyboard anywhere in the tree drives the keyboard
channel, any mouse drives the mouse channel. That replaces `top.sv`'s per-port `typ` selection and is what lets
a Mighty Mouse in the keyboard's socket work.

Later, cheaply, because it is just firmware: the Caps Lock LED via SET_REPORT.

### Fallback
A `USB_HOST_SOFTCPU` build constant in `top.sv` chooses between the new path and the current m1nl core, so the
proven build is one constant away until the new one reaches parity.

## Resources (estimates)
~1.5k LUTs CPU + ~1k per engine + glue ≈ 4k LUTs (33% → ~40%); 8 RAMB36 for firmware memory (32 → 40 of 135);
no new clocks or BUFGs; 60 MHz is undemanding for PicoRV32 on a -2 part.

## Toolchain and iteration speed
- **Compiler:** xPack GNU RISC-V Embedded GCC (`riscv-none-elf-gcc`), a Windows zip, no installer. None is
  installed on this machine. A PowerShell build script compiles, links with a small linker script, and
  converts the binary to `firmware.mem` (no Python here).
- **Simulation is the main debugging tool.** xsim runs PicoRV32 + `usb_sie` + the firmware against a
  behavioural USB device model in SystemVerilog (descriptors, NAK/STALL, a hub model with one child). That
  covers enumeration and hub logic without a 20-100 minute build per experiment.
- **Firmware-only changes without a rebuild:** `updatemem` patches BRAM contents into an existing bitstream in
  about a minute, given an MMI file generated from the placed design by a Tcl script. Worth getting working in
  phase 0; otherwise every firmware edit costs a resynthesis.
- **Hardware debug:** a debug word in the ILA, and possibly a **debug UART to the CP2102N**. The netlist
  shows the FPGA's `TXDB` (G3) reaching `RXD_CP2102` through a buffer gated by `INTERNAL_SCC_EN` (B1), which
  is tied off today. Before using it, confirm from the schematic that enabling it cannot fight the external
  SCC's driver on the same net, and use it only in debug builds with SERIAL B SOURCE in the USB position.

## Phases and exit criteria
0. **Toolchain and CPU in simulation:** firmware builds; PicoRV32 runs it in xsim and writes a debug register.
   Decide whether `updatemem` works.
1. **`usb_sie` in simulation** against the device model: SOF/keep-alive cadence, SETUP/IN/OUT, NAK, STALL,
   timeout, CRC errors, both speeds.
2. **Parity, directly attached:** firmware enumerates the sim device, then on hardware every device in the
   list above works **with no VID/PID tables**.
3. **Hubs:** both Apple keyboards; then a Mighty Mouse in an Apple keyboard's socket.
4. **PRE:** a low-speed device (the Lenovo mouse) behind a hub.
5. **Production:** default the constant to the new path, production build, flash.

## Open questions
- Exact behaviour on unplugging a hub mid-report (firmware: empty reports on both channels).
- Whether two keyboards at once should merge their key sets (first version: the most recent report wins).
- LisaFPGA has no LICENSE file in the repo root; PicoRV32 (ISC) and our own code are permissive either way,
  and the m1nl core (Apache-2.0) stays only in the fallback path.
