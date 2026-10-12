// ---------------------------------------------------------------------------------------------
// web -- the SD card manager page at http://lisanet.local/ (or the board's IP). Written with an AI assistant.
//
// Every request needs HTTP Basic auth: user "lisa", password set from the Lisa with AT+WEBPASS. Until a password is set
// the page refuses everything. Basic auth over plain HTTP is readable by anyone on the same network, so this is meant
// for a home LAN, not the internet.
//
// API (all paths absolute, as in docs/lisanet_link_protocol.md):
//   GET  /                          the page
//   GET  /api/hello                 {"fw":"..."}: which board's card this is (ESFloppy or ESProFile, from the
//                                   LisaFPGA menu's WIFI FDD / WIFI HDD)
//   GET  /api/info                  {"card":bytes,"free":bytes,"fw":"..."}  (free space needs a FAT scan: ~10 s)
//   GET  /api/ls?path=/             {"path":"/","entries":[{"n":name,"d":0|1,"s":size},...]}
//   GET  /api/get?path=/x.dc42      the file
//   POST /api/put                   raw body, header X-Path: URL-encoded destination. Space is reserved contiguously
//                                   first (OPEN mode 3), because ESFloppy only mounts unfragmented images.
//   POST /api/rm?path=  /api/mkdir?path=  /api/mv?from=&to=
//   GET  /api/mountnext             {"path":"..."};   POST /api/mountnext?path=   (empty clears)
// Errors are {"error":"..."} with 503 when ESFloppy can't be reached (ESP32 MODE not set to WIFI).
//
// Everything runs from loop() on one task, so the link to ESFloppy is never used by two things at once.
// ---------------------------------------------------------------------------------------------
#include "web.h"
#include "config.h"
#include "sdlink.h"
#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <Preferences.h>

namespace web {

static WebServer server(WEB_PORT);
static Preferences nvs;
static bool mdnsStarted = false;
static uint8_t buf[sdlink::MAX_DATA];

extern const char PAGE[];

// ---- Helpers -----------------------------------------------------------------------------------
static bool authorized() {
    String pass = nvs.getString("webpass", "");
    if (!pass.length()) {
        server.send(403, "text/plain", "Locked: set a password first from the Lisa with AT+WEBPASS=\"password\"\n");
        return false;
    }
    if (!server.authenticate(WEB_USER, pass.c_str())) {
        server.requestAuthentication(BASIC_AUTH, "LisaNet");
        return false;
    }
    return true;
}

static String jsonEscape(const String &s) {
    String o;
    o.reserve(s.length() + 8);
    for (size_t i = 0; i < s.length(); i++) {
        char c = s[i];
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if ((uint8_t)c < 0x20) { char e[8]; snprintf(e, sizeof e, "\\u%04x", c); o += e; }
        else o += c;
    }
    return o;
}

static void sendError(int s) {
    int code = s == sdlink::TIMEOUT ? 503 : s == sdlink::NOT_FOUND ? 404 : s == sdlink::EXISTS ? 409
             : s == sdlink::NO_CONTIGUOUS ? 507 : s == sdlink::BAD_REQUEST ? 400 : 500;
    server.send(code, "application/json", String("{\"error\":\"") + jsonEscape(sdlink::statusName(s)) + "\"}");
}

static void sendStatus(int s) {
    if (s == sdlink::OK) server.send(200, "application/json", "{}");
    else sendError(s);
}

// A quick reachability check, so a request made in FLOPPY mode fails in ~2 s rather than after a long LIST timeout.
static uint32_t lastGood = 0;
static bool linkUp() {
    if (lastGood && millis() - lastGood < 5000) return true;
    String fw;
    if (sdlink::hello(fw) != sdlink::OK) { lastGood = 0; return false; }
    lastGood = millis();
    return true;
}
static void markGood() { lastGood = millis(); }

static String baseName(const String &path) {
    int i = path.lastIndexOf('/');
    return i >= 0 ? path.substring(i + 1) : path;
}

// ---- Handlers ----------------------------------------------------------------------------------
static void handlePage() {
    if (!authorized()) return;
    server.send(200, "text/html; charset=utf-8", PAGE);
}

static void handleHello() {
    if (!authorized()) return;
    String fw;
    int s = sdlink::hello(fw);
    if (s != sdlink::OK) { sendError(s); return; }
    markGood();
    server.send(200, "application/json", "{\"fw\":\"" + jsonEscape(fw) + "\"}");
}

static void handleInfo() {
    if (!authorized()) return;
    String fw;
    int s = sdlink::hello(fw);
    if (s != sdlink::OK) { sendError(s); return; }
    uint64_t card = 0, freeBytes = 0;
    s = sdlink::info(card, freeBytes);
    if (s != sdlink::OK) { sendError(s); return; }
    markGood();
    char out[200];
    snprintf(out, sizeof out, "{\"card\":%llu,\"free\":%llu,\"fw\":\"%s\"}", card, freeBytes, jsonEscape(fw).c_str());
    server.send(200, "application/json", out);
}

static void listEntry(const sdlink::Entry &e, void *ctx) {
    String &o = *(String *)ctx;
    if (o[o.length() - 1] == '}') o += ',';
    o += "{\"n\":\"" + jsonEscape(e.name) + "\",\"d\":" + (e.dir ? "1" : "0") + ",\"s\":" + String((double)e.size, 0) + "}";
}

static void handleLs() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    String path = server.hasArg("path") ? server.arg("path") : "/";
    String o = "{\"path\":\"" + jsonEscape(path) + "\",\"entries\":[";
    int s = sdlink::list(path, listEntry, &o);
    if (s != sdlink::OK) { sendError(s); return; }
    markGood();
    o += "]}";
    server.send(200, "application/json", o);
}

static void handleGet() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    String path = server.arg("path");
    uint64_t size = 0;
    int s = sdlink::openRead(path, size);
    if (s != sdlink::OK) { sendError(s); return; }
    server.setContentLength(size);
    server.sendHeader("Content-Disposition", "attachment; filename=\"" + baseName(path) + "\"");
    server.send(200, "application/octet-stream", "");
    uint64_t off = 0;
    while (off < size) {
        size_t got = 0;
        s = sdlink::read(off, buf, sdlink::MAX_DATA, got);
        if (s != sdlink::OK || got == 0) break;    // the browser sees a short download
        server.sendContent((const char *)buf, got);
        off += got;
    }
    sdlink::close();
    markGood();
}

// Upload: the body streams through in 1436-byte pieces; collect them into 4 KB link writes.
static struct {
    bool authed;
    int status;            // first error, or OK
    uint64_t off;
    size_t fill;
    String path;
} up;

static void flushUpload() {
    if (up.status == sdlink::OK && up.fill) {
        up.status = sdlink::write(up.off, buf, up.fill);
        up.off += up.fill;
    }
    up.fill = 0;
}

static void handlePutBody() {
    HTTPRaw &raw = server.raw();
    switch (raw.status) {
        case RAW_START: {
            up = {};
            up.status = sdlink::OK;
            String pass = nvs.getString("webpass", "");
            up.authed = pass.length() && server.authenticate(WEB_USER, pass.c_str());
            if (!up.authed) return;                       // the body is read and discarded; nothing touches the card
            up.path = WebServer::urlDecode(server.header("X-Path"));
            if (!up.path.startsWith("/")) { up.status = sdlink::BAD_REQUEST; return; }
            up.status = sdlink::openWriteReserve(up.path, (uint64_t)server.clientContentLength());
            Serial.printf("[web] upload %s, %d bytes: %s\r\n", up.path.c_str(), server.clientContentLength(),
                          sdlink::statusName(up.status));
            break;
        }
        case RAW_WRITE:
            if (!up.authed || up.status != sdlink::OK) return;
            for (size_t i = 0; i < raw.currentSize;) {
                size_t n = min(raw.currentSize - i, sizeof buf - up.fill);
                memcpy(buf + up.fill, raw.buf + i, n);
                up.fill += n;
                i += n;
                if (up.fill == sizeof buf) flushUpload();
            }
            break;
        case RAW_END:
            if (!up.authed) return;
            flushUpload();
            if (up.status == sdlink::OK) up.status = sdlink::close();
            break;
        case RAW_ABORTED:
            if (!up.authed) return;
            sdlink::close();
            if (up.status == sdlink::OK) sdlink::remove(up.path);   // don't leave a partly written image behind
            up.status = sdlink::IO;
            break;
    }
}

static void handlePutDone() {
    if (!authorized()) return;
    if (!server.hasHeader("X-Path")) { server.send(400, "application/json", "{\"error\":\"missing X-Path\"}"); return; }
    if (up.status == sdlink::OK) markGood();
    sendStatus(up.status);
}

static void handleRm() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    sendStatus(sdlink::remove(server.arg("path")));
}

static void handleMkdir() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    sendStatus(sdlink::mkdir(server.arg("path")));
}

static void handleMv() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    sendStatus(sdlink::rename(server.arg("from"), server.arg("to")));
}

static void handleMountNextGet() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    String path;
    int s = sdlink::mountNextGet(path);
    if (s != sdlink::OK) { sendError(s); return; }
    server.send(200, "application/json", "{\"path\":\"" + jsonEscape(path) + "\"}");
}

static void handleMountNextSet() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    sendStatus(sdlink::mountNextSet(server.arg("path")));
}

void begin() {
    nvs.begin(NVS_NAMESPACE, true);
    const char *keep[] = {"X-Path"};
    server.collectHeaders(keep, 1);
    server.on("/", HTTP_GET, handlePage);
    server.on("/api/hello", HTTP_GET, handleHello);
    server.on("/api/info", HTTP_GET, handleInfo);
    server.on("/api/ls", HTTP_GET, handleLs);
    server.on("/api/get", HTTP_GET, handleGet);
    server.on("/api/put", HTTP_POST, handlePutDone, handlePutBody);
    server.on("/api/rm", HTTP_POST, handleRm);
    server.on("/api/mkdir", HTTP_POST, handleMkdir);
    server.on("/api/mv", HTTP_POST, handleMv);
    server.on("/api/mountnext", HTTP_GET, handleMountNextGet);
    server.on("/api/mountnext", HTTP_POST, handleMountNextSet);
    server.onNotFound([]() { server.send(404, "text/plain", "Not found\n"); });
    server.begin();
}

void poll() {
    if (!mdnsStarted && WiFi.status() == WL_CONNECTED) {
        if (MDNS.begin(MDNS_NAME)) {
            MDNS.addService("http", "tcp", WEB_PORT);
            Serial.printf("[web] http://%s/ and http://" MDNS_NAME ".local/\r\n", WiFi.localIP().toString().c_str());
        }
        mdnsStarted = true;
    }
    server.handleClient();
}

}  // namespace web
