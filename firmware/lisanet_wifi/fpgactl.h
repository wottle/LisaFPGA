// fpgactl -- the FPGA's own control channel: on-screen-menu settings, ESP32 mode, the Lisa's power and reset buttons,
// and status (including the die temperature). Written with an AI assistant. Frames share the SD link (J21 GPIO4/5) and
// are described in docs/lisanet_link_protocol.md, "FPGA control frames".
#pragma once
#include <Arduino.h>

namespace fpgactl {

enum : int { OK = 0, BAD_REQUEST = 1, LOCKED = 2, BUSY = 3, UNKNOWN_CMD = 4, NO_REPLY = -1 };
const char *statusName(int s);

enum Reg : uint8_t { REG_VIDEO = 1, REG_HOFF = 2, REG_VOFF = 3, REG_CONTRAST = 4, REG_SPEED = 5, REG_ESPMODE = 6 };
enum Action : uint8_t { ACT_SAVE = 1, ACT_POWER = 2, ACT_RESET = 3 };

struct Status {
    uint8_t version, videoMode, speedIdx, espMode;      // espMode: 0 NORMAL, 1 WIFI FDD, 2 WIFI HDD
    bool contrast, lisaOn, boardPresent, saved, saving, speedUserSet, has1024, modeUserSet, rom3A, contrastJumper;
    uint16_t hOff, hLim, vOff, vLim;
    float tempC;
};

int status(Status &s);
int set(uint8_t reg, uint16_t value);
int action(uint8_t a);      // not retried: a repeated power press would undo itself
// Diagnostics (AT+FPGA): the last request sent, and every byte received while waiting for its reply
const uint8_t *lastRaw(size_t &n);
const uint8_t *lastFrame(size_t &n);

}  // namespace fpgactl
