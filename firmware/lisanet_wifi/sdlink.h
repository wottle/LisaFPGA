// sdlink -- LisaNet link client: talks to ESFloppy's SD server (docs/lisanet_link_protocol.md). Written with an AI assistant.
#pragma once
#include <Arduino.h>

namespace sdlink {

enum Status : int {
    OK = 0, NOT_FOUND, EXISTS, IO, BAD_REQUEST, NO_HANDLE, UNKNOWN_CMD, NO_CARD, NO_CONTIGUOUS,
    TIMEOUT = -1               // no valid response (ESFloppy not in WIFI mode, or not connected)
};
const char *statusName(int s);

static const size_t MAX_DATA = 4096;

struct Entry { bool dir; uint64_t size; String name; };

void begin(HardwareSerial &port, int rxPin, int txPin, uint32_t baud);
// Shared with fpgactl, which speaks the FPGA's own frames on the same link (never at the same time: one loop)
HardwareSerial *linkPort();
uint32_t crc32Update(uint32_t c, const uint8_t *p, size_t n);   // zlib CRC-32 running value (start FFFFFFFF, finish ^FFFFFFFF)

int hello(String &firmware);
int info(uint64_t &cardBytes, uint64_t &freeBytes);
// Calls fn for every entry of a directory (pages through LIST). Returns a status.
int list(const String &path, void (*fn)(const Entry &, void *), void *ctx);
int stat(const String &path, bool &isDir, uint64_t &size);
int openRead(const String &path, uint64_t &size);
int openWriteReserve(const String &path, uint64_t size);   // OPEN mode 3: contiguous, as ESFloppy requires
int read(uint64_t offset, uint8_t *buf, size_t want, size_t &got);
int write(uint64_t offset, const uint8_t *buf, size_t n);
int close(bool abandon = false);                          // abandon: discard a staged upload instead
int remove(const String &path);
int rename(const String &from, const String &to);
int mkdir(const String &path);
// On-card copy: copyStart reserves the destination (which must not exist); call copyStep until copied == total.
int copyStart(const String &from, const String &to, uint64_t &total);
// Like copyStart, but the target may exist: when the copy completes it is renamed to backup (deleted if backup is
// empty) and replaced, in one step on the server, so the target is never missing or half-written.
int copyReplace(const String &from, const String &to, const String &backup, uint64_t &total);
int copyStep(uint64_t &copied, uint64_t &total);
int mountNextSet(const String &path);                      // empty path clears it
int mountNextGet(String &path);

}  // namespace sdlink
