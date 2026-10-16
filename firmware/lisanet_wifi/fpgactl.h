// fpgactl -- the FPGA's own control channel: on-screen-menu settings, ESP32 mode, the Lisa's power and reset buttons,
// and status (including the die temperature). Written with an AI assistant. Frames share the SD link (J21 GPIO4/5) and
// are described in docs/lisanet_link_protocol.md, "FPGA control frames".
#pragma once
#include <Arduino.h>

namespace fpgactl {

enum : int { OK = 0, BAD_REQUEST = 1, LOCKED = 2, BUSY = 3, UNKNOWN_CMD = 4, NO_REPLY = -1 };
const char *statusName(int s);

enum Reg : uint8_t { REG_VIDEO = 1, REG_HOFF = 2, REG_VOFF = 3, REG_CONTRAST = 4, REG_SPEED = 5, REG_ESPMODE = 6,
                    // FPGA control version 2 and later; 10-12 only while the Lisa is off
                    REG_SCANLINES = 8, REG_INVERSE = 9, REG_CPUROM = 10, REG_IOROM = 11, REG_RAM = 12 };
enum Action : uint8_t { ACT_SAVE = 1, ACT_POWER = 2, ACT_RESET = 3, ACT_NMI = 4 };

struct Status {
    uint8_t version, videoMode, speedIdx, espMode;      // espMode: 0 NORMAL, 1 WIFI FDD, 2 WIFI HDD
    bool contrast, lisaOn, boardPresent, saved, saving, speedUserSet, has1024, modeUserSet, rom3A, contrastJumper;
    uint16_t hOff, hLim, vOff, vLim;
    float tempC;
    // Version 2 and later (hasMachine): the effective setting and what the jumper/switch itself says
    bool hasMachine;
    bool scanlines, scanlinesJumper, inverse, inverseJumper, rom3ASwitch, twiggy, twiggySwitch, ramUserSet;
    uint8_t ram, ramSwitch;                             // 0-3 = 512K / 1M / 1.5M / 2M
};

int status(Status &s);
int set(uint8_t reg, uint16_t value);
int action(uint8_t a);      // not retried: a repeated power press would undo itself
// Diagnostics (AT+FPGA): the last request sent, and every byte received while waiting for its reply
const uint8_t *lastRaw(size_t &n);
const uint8_t *lastFrame(size_t &n);

}  // namespace fpgactl
