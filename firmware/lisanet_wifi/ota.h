// ota -- firmware updates for this board over WiFi, from the web page's Settings tab. Written with an AI assistant.
//
// The default 8 MB partition table has two app slots; an update is written to the one not running and the board
// restarts into it. Safety:
//   - an upload is only accepted if it carries this firmware's tag (FW_TAG), so ESFloppy's or ESProFile's firmware,
//     a bootloader or a merged image can't be installed by mistake (a merged image is also too big for a slot);
//   - the ESP-IDF image check (header, chip, SHA-256) runs before the slot is made bootable;
//   - a new image stays "pending" until it has been up for KEEP_AFTER_MS with the web server running. If it crashes or
//     resets before then, the bootloader goes back to the previous image by itself.
#pragma once
#include <Arduino.h>

namespace ota {

static const uint32_t KEEP_AFTER_MS = 20000;

void begin();                          // logs the running slot; call early in setup()
void poll();                           // marks a pending image good once it has proved itself; restarts when asked
String infoJson();                     // {"version","slot","pending","canRollBack","prev"}

// Upload, fed from the web server's raw-body callback
bool start(size_t size);
void write(const uint8_t *data, size_t n);
bool finish();                         // true: the new image is bootable; restart with restartSoon()
void abort();
const String &error();                 // why start/write/finish failed
const String &newVersion();            // the version found in the uploaded image's tag

bool rollBack();                       // boot the other slot next time (if it holds a valid image)
void restartSoon();                    // restart ~1 s from now, so the HTTP reply gets out first

}  // namespace ota
