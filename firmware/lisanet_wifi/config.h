// ---------------------------------------------------------------------------------------------
// LisaNet WiFi board firmware -- runs on a Seeed XIAO ESP32S3 plugged into the LisaFPGA board's J21 header.
// Written with an AI assistant. See docs/superpowers/specs/2026-10-10-esp32-wifi-mode-design.md and
// docs/lisanet_link_protocol.md.
//
// In the LisaFPGA menu's ESP32 MODE = WIFI, the FPGA connects:
//   - the Lisa's Serial A to this board (an AT-command modem, 9600 8N1), and
//   - ESFloppy's ESP32 to this board (the LisaNet file protocol, 2 Mbaud), so its SD card can be managed over WiFi.
// In FLOPPY mode both are disconnected: the modem goes quiet and the web page reports ESFloppy as unreachable.
// With the web page's FujiNet setting on, the FPGA puts the Lisa's Serial B on the D0/D1 wires instead (in any mode),
// and this board answers there as an RS-232 FujiNet (fujinet.cpp); the modem is off the wires meanwhile.
//
// Wiring (XIAO pin -> J21 pin):
//   D0 (GPIO1)  <- J21 pin 5  GPIO2  the Lisa's Serial A (or B) transmit data
//   D1 (GPIO2)  -> J21 pin 7  GPIO3  into the Lisa's Serial A (or B) receive
//   D7 (GPIO44) <- J21 pin 2  GPIO4  from ESFloppy
//   D6 (GPIO43) -> J21 pin 4  GPIO5  to ESFloppy
//   GND         -- J21 pin 6
//   3V3         -- J21 pin 8  (only once the board's 3.3 V rail is known to handle WiFi bursts; until then power the
//                              XIAO from its own USB-C and leave pin 8 unconnected)
// ---------------------------------------------------------------------------------------------
#pragma once

#ifndef LISANET_WIFI_VERSION         // a test build can override it with -D
#define LISANET_WIFI_VERSION "0.15"
#endif
// What this version brought, shown next to the version on the web page. Rewrite it with every new version.
#ifndef LISANET_WIFI_NOTES
#define LISANET_WIFI_NOTES   "AI chat works with the STATUS that follows an OPEN"
#endif

#define LISA_RX_PIN   1        // D0
#define LISA_TX_PIN   2        // D1
#define LISA_BAUD     9600

#define LINK_RX_PIN   44       // D7
#define LINK_TX_PIN   43       // D6
#define LINK_BAUD     2000000

#define MDNS_NAME     "lisanet"   // http://lisanet.local/
#define NVS_NAMESPACE "lisanet"
#define WEB_PORT      80
#define WEB_USER      "lisa"      // the web page's user name; the password is set with AT+WEBPASS
