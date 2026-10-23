// atmodem -- a Hayes-style command interpreter on the Lisa's Serial A, so LisaTerminal can drive the WiFi board before
// any Lisa application exists. Written with an AI assistant.
#pragma once
#include <Arduino.h>

namespace atmodem {
void begin(HardwareSerial &lisa);
void poll();   // call from loop()
// false while the FPGA has Serial B on these wires (fujinet owns the port then): the modem neither reads nor writes
// the Lisa side; its USB console keeps working
void setLisaAttached(bool attached);
}
