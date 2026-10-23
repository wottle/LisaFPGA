// fujinet -- a FujiNet adapter on the Lisa's Serial B, for Lisa programs written for an RS-232 FujiNet (LisaFuji and
// friends). Written with an AI assistant, from the FujiBus protocol as implemented in fujinet-firmware (lib/bus/
// FujiBusPacket.cpp, lib/bus/rs232/rs232.cpp, lib/device/NDevice); none of that code is copied here.
//
// The FPGA puts Serial B on the same two J21 wires as the Serial A modem (SET reg 13, the web page's FujiNet setting),
// so this module and atmodem share one UART: while the FPGA reports Serial B routed here, this module owns the port and
// the modem is cut off from it (its USB console still works).
//
// What is answered: the FujiNet device (0x70: WiFi status and enabled, adapter config, SSID, status, device test,
// reset), the clock (0x45: every read format, setting the time zone) and network units N1-N8 (0x71-0x78: HTTP and
// HTTPS GET, POST, PUT and DELETE; status, read, write, close; translation; the JSON parser with JSON-pointer queries;
// login and password). Anything else is NAKed and logged, so a Lisa program's needs show up on the web page.
#pragma once
#include <Arduino.h>

namespace fujinet {

void begin(HardwareSerial &port);   // the UART atmodem also uses (D0/D1), already started
void poll();                        // call from loop()

bool routed();                      // the FPGA reports Serial B on J21: this module owns the port
void noteRouted(bool on);           // from a fresh FPGA status (web page, or this module's own check)

uint32_t baud();
void setBaud(uint32_t b);           // applies at once; kept only by save()
String timeZone();
void setTimeZone(const String &tz); // POSIX TZ for the clock device; applies at once, kept only by save()
void save();                        // keep the baud rate and time zone in NVS: the web page's Save settings
bool unsaved();                     // either differs from what is kept

String infoJson();                  // {"routed","baud","tz","unsaved","time","packets","naks","log":[...]}

}  // namespace fujinet
