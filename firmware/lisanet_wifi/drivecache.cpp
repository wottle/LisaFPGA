// drivecache -- see drivecache.h. Written with an AI assistant.
#include "drivecache.h"
#include "sdlink.h"
#include "fujinet.h"
#include <vector>
#include <algorithm>

namespace drivecache {

static const size_t MAX_IMAGES = 400;          // ~30 KB of JSON at most
static const int MAX_DEPTH = 4;                // folder levels below the root, as the page always walked
static const uint32_t QUIET_MS = 3000;         // the Lisa's FujiNet must have been idle this long

struct Img { String path; uint64_t size; };
struct Folder { String path; int depth; };

static std::vector<Img> images;
static std::vector<Folder> todo;               // folders still to read
static int folders = 0;
static uint8_t mode = 255;                     // 255: no FPGA status yet (or an FPGA that cannot say): try anyway
static int driveType = -1;                     // emulMode * 2 + twiggy, from the last drive status
static enum { WAITING, SCANNING, READY } state = WAITING;
static uint32_t nextTry = 0;
static uint32_t backoff = 15000;               // grows while ESFloppy's drive firmware does not answer

static void clear() {
    images.clear();
    todo.clear();
    folders = 0;
    state = WAITING;
}

void rescan() {
    clear();
    nextTry = 0;
    backoff = 15000;
    Serial.println("[drives] rescan requested");
}

void noteMode(uint8_t m) {
    if (m == mode) return;
    uint8_t old = mode;
    mode = m;
    if (m != 0 && m != 255) { clear(); return; }   // a card's files are being managed: they may change
    if (old != 255 && old != 0) {                   // back to Normal: ESFloppy restarts as the drive (~10 s)
        clear();
        nextTry = millis() + 12000;
        backoff = 15000;
    }
}

void noteDriveType(uint8_t emulMode, bool twiggy) {
    int t = emulMode * 2 + (twiggy ? 1 : 0);
    if (driveType != -1 && t != driveType) {
        Serial.println("[drives] the drive type changed: reading the card again");
        clear();
        nextTry = 0;
    }
    driveType = t;
}

static String join(const String &dir, const String &name) { return dir == "/" ? "/" + name : dir + "/" + name; }

struct Ctx { const Folder *f; };
static void onEntry(const sdlink::Entry &e, void *vctx) {
    const Folder &f = *static_cast<Ctx *>(vctx)->f;
    if (e.name.startsWith(".")) return;            // hidden, as on ESFloppy's own picker
    String full = join(f.path, e.name);
    if (e.dir) { if (f.depth < MAX_DEPTH) todo.push_back({full, f.depth + 1}); }
    else if (images.size() < MAX_IMAGES) images.push_back({full, e.size});
}

void poll() {
    if (mode != 0 && mode != 255) return;          // not the drive right now
    if (state == READY) return;
    uint32_t now = millis();
    if ((int32_t)(now - nextTry) < 0) return;
    if (now - fujinet::lastActivityMs() < QUIET_MS) return;   // the Lisa is using the FujiNet: don't hold it up
    if (state == WAITING) {
        images.clear();
        todo.clear();
        todo.push_back({"/", 0});
        folders = 0;
        state = SCANNING;
    }
    Folder f = todo.back();
    todo.pop_back();
    Ctx ctx{&f};
    uint32_t t0 = millis();
    int s = sdlink::driveList(f.path, onEntry, &ctx);
    if (s != sdlink::OK) {
        // Older drive firmware, ESFloppy restarting, or no link: wait, longer each time, so a board without the floppy
        // remote is not kept busy with time-outs
        clear();
        if (s == sdlink::UNKNOWN_CMD) backoff = 600000;
        nextTry = millis() + backoff;
        Serial.printf("[drives] ESFloppy did not list %s (%s); trying again in %lu s\r\n", f.path.c_str(),
                      sdlink::statusName(s), (unsigned long)(backoff / 1000));
        if (backoff < 600000) backoff *= 2;
        return;
    }
    folders++;
    backoff = 15000;
    nextTry = millis() + 50;
    if (millis() - t0 > 2000) Serial.printf("[drives] %s took %lu ms\r\n", f.path.c_str(), (unsigned long)(millis() - t0));
    if (todo.empty()) {
        std::sort(images.begin(), images.end(), [](const Img &a, const Img &b) { return a.path < b.path; });
        state = READY;
        Serial.printf("[drives] %u disk images in %d folders, kept until the drives leave Normal\r\n",
                      (unsigned)images.size(), folders);
    }
}

static void esc(String &o, const String &s) {
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if ((uint8_t)c < 0x20) o += ' ';
        else o += c;
    }
}

String json() {
    const char *st = (mode != 0 && mode != 255) ? "off" : state == READY ? "ready" : state == SCANNING ? "scanning" : "waiting";
    String o;
    o.reserve(64 + (state == READY ? images.size() * 64 : 0));
    o += "{\"state\":\"";
    o += st;
    o += "\",\"folders\":";
    o += folders;
    o += ",\"full\":";
    o += images.size() >= MAX_IMAGES ? "true" : "false";
    o += ",\"images\":[";
    if (state == READY) {
        for (size_t i = 0; i < images.size(); i++) {
            if (i) o += ',';
            o += "{\"p\":\"";
            esc(o, images[i].path);
            o += "\",\"s\":";
            o += String((double)images[i].size, 0);
            o += '}';
        }
    }
    o += "]}";
    return o;
}

}  // namespace drivecache
