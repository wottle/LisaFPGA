// atmodem -- a Hayes-style command interpreter on the Lisa's Serial A, so LisaTerminal can drive the WiFi board before
// any Lisa application exists. Written with an AI assistant.
#pragma once
#include <Arduino.h>

namespace atmodem {
void begin(HardwareSerial &lisa);
void poll();   // call from loop()
}
