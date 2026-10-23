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
//   POST /api/copystart?from=&to=[&replace=1&backup=]  {"total":bytes}: an on-card copy, staged and reserved
//                                   contiguously; with replace=1 an existing target is renamed to backup (or deleted)
//                                   and replaced in one step when the copy completes
//   POST /api/copystep              {"copied":bytes,"total":bytes}: up to 1 MB more; repeat until copied == total
//   GET  /api/mountnext             {"path":"..."};   POST /api/mountnext?path=   (empty clears)
//   GET  /api/fpga                  the FPGA's settings and state (fpgactl::Status as JSON)
//   POST /api/fpga/set?reg=&value=  a setting (fpgactl::Reg); 409 if the Lisa is on and reg is the ESP32 mode, a ROM
//                                   or the RAM size
//   POST /api/fpga/action?a=save|power|reset|nmi   save settings, or press the Lisa's power, reset or NMI button
//   GET  /api/fujinet               the FujiNet adapter on Serial B: {"routed","baud","tz","time","packets","naks","log"}
//                                   (Serial B itself is switched with /api/fpga/set?reg=13)
//   POST /api/fujinet?baud=&tz=     its baud rate and POSIX time zone
//   GET  /api/drive                 the floppy drive (ESFloppy's drive firmware, NORMAL mode): {"twiggy","uiBusy",
//                                   "drives":[{"n","exists","inserted","ejecting","name"},..],"fw"}; 503 if it does not answer
//   GET  /api/drive/ls?path=        folders and images that drive mode accepts, as /api/ls
//   POST /api/drive/insert?drive=&path=   insert an image (409 drive full or ESFloppy's menu open, 415 not an image
//                                   for this drive)
//   POST /api/drive/eject?drive=&force=1  eject (a Sony always force-ejects)
//   GET  /api/fw                    this board's firmware: {"version","notes","slot","pending","canRollBack","prev"}
//   POST /api/fw/update             raw body: a new lisanet_wifi.ino.bin; installed into the other slot, then a restart
//   POST /api/fw/rollback           go back to the previous firmware, then a restart
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
#include "wifisetup.h"
#include "fpgactl.h"
#include "ota.h"
#include "fujinet.h"

namespace web {

static WebServer server(WEB_PORT);
static Preferences nvs;
static bool mdnsStarted = false;
static uint8_t buf[sdlink::MAX_DATA];

extern const char PAGE[];
extern const char SETUP_PAGE[];

// ---- Helpers -----------------------------------------------------------------------------------
static bool authorized() {
    String pass = nvs.getString("webpass", "");
    if (!pass.length()) {
        server.send(403, "text/plain", "Locked: no web password yet. Set one on the setup page (join the WiFi network "
                    SETUP_AP_SSID ", password " SETUP_AP_PASS "), or from the Lisa with AT+WEBPASS=\"password\".\n");
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
    int code = s == sdlink::TIMEOUT ? 503 : s == sdlink::NOT_FOUND ? 404
             : (s == sdlink::EXISTS || s == sdlink::UI_BUSY || s == sdlink::IN_USE) ? 409 : s == sdlink::BAD_IMAGE ? 415
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

// ---- Setup network (see wifisetup.h) -------------------------------------------------------------
// Did this request arrive over the setup network rather than the home network?
static bool viaSetupNetwork() {
    return wifisetup::apActive() && server.client().localIP() == WiFi.softAPIP();
}

// Phones probe a fixed URL when they join a network; answering every unknown URL on the setup network with a
// redirect makes them pop up the setup page by themselves.
static void redirectToSetup() {
    server.sendHeader("Location", "http://" + WiFi.softAPIP().toString() + "/setup");
    server.send(302, "text/plain", "");
}

// The setup network's password is public, so once a web password exists the setup page starts with a login form for
// it -- otherwise anyone nearby could take the board over while its network is down. It is a form, not HTTP Basic
// auth, because phones' captive-portal windows never show a Basic auth prompt: they just sit on a blank page. A good
// login returns a session token that the scan and save requests must carry. A board with no web password yet (fresh,
// or reset with the B button) skips the login, which is what lets first-time setup work at all.
static String setupToken;                                     // valid until the next login or restart

static bool setupTokenOk() {
    if (!nvs.getString("webpass", "").length()) return true;
    if (setupToken.length() && server.arg("t") == setupToken) return true;
    server.send(403, "application/json", "{\"error\":\"Log in first\"}");
    return false;
}

static void handleSetupPage() {
    server.send(200, "text/html; charset=utf-8", SETUP_PAGE);
}

static void handleSetupInfo() {
    server.send(200, "application/json",
                String("{\"haveWebPass\":") + (nvs.getString("webpass", "").length() ? "true" : "false") + "}");
}

static void handleSetupLogin() {
    String current = nvs.getString("webpass", "");
    if (current.length() && server.arg("password") != current) {
        delay(1000);                                          // slows guessing
        server.send(403, "application/json", "{\"error\":\"That password is not right\"}");
        return;
    }
    char t[17];
    snprintf(t, sizeof t, "%08lx%08lx", (unsigned long)esp_random(), (unsigned long)esp_random());
    setupToken = t;
    server.send(200, "application/json", "{\"t\":\"" + setupToken + "\"}");
}

static void handleSetupScan() {
    if (!setupTokenOk()) return;
    int n = WiFi.scanNetworks();
    String o = String("{\"haveWebPass\":") + (nvs.getString("webpass", "").length() ? "true" : "false") + ",\"nets\":[";
    for (int i = 0; i < n; i++) {
        if (WiFi.SSID(i).length() == 0) continue;           // hidden networks: type the name instead
        if (o[o.length() - 1] == '}') o += ',';
        o += "{\"s\":\"" + jsonEscape(WiFi.SSID(i)) + "\",\"r\":" + String(WiFi.RSSI(i)) + ",\"l\":" +
             (WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? "0" : "1") + "}";
    }
    o += "]}";
    WiFi.scanDelete();
    server.send(200, "application/json", o);
}

static void handleSetupSave() {
    if (!setupTokenOk()) return;
    String ssid = server.arg("ssid"), pass = server.arg("pass"), webpass = server.arg("webpass");
    bool haveWebPass = nvs.getString("webpass", "").length() > 0;
    if (!ssid.length()) { server.send(400, "application/json", "{\"error\":\"Choose a network\"}"); return; }
    if (webpass.length() && webpass.length() < 4) {
        server.send(400, "application/json", "{\"error\":\"The web password needs 4 or more characters\"}");
        return;
    }
    if (!webpass.length() && !haveWebPass) {
        server.send(400, "application/json", "{\"error\":\"Set a web password: it protects the SD card manager\"}");
        return;
    }
    if (webpass.length()) nvs.putString("webpass", webpass);
    server.send(200, "application/json", "{}");
    wifisetup::requestJoin(ssid, pass);
}

static void handleSetupStatus() {
    server.send(200, "application/json", wifisetup::statusJson());
}

// ---- Handlers ----------------------------------------------------------------------------------
static void handlePage() {
    if (viaSetupNetwork()) { redirectToSetup(); return; }
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
            // The server stages uploads: a completing CLOSE moves the file into place, replacing any old one in the
            // same step; after a write error, abandon it so the old file (if any) stays as it was.
            if (up.status == sdlink::OK) up.status = sdlink::close();
            else sdlink::close(true);
            break;
        case RAW_ABORTED:
            if (!up.authed) return;
            sdlink::close(true);                               // discard the staged upload; the target is untouched
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

static void handleCopyStart() {
    if (!authorized()) return;
    if (!linkUp()) { sendError(sdlink::TIMEOUT); return; }
    uint64_t total = 0;
    // replace=1: the target may exist; on completion it is renamed to `backup` (or deleted if that is empty) and
    // replaced in one step, so it is never missing or half-written even if the copy is cut short
    int s = server.arg("replace") == "1"
                ? sdlink::copyReplace(server.arg("from"), server.arg("to"), server.arg("backup"), total)
                : sdlink::copyStart(server.arg("from"), server.arg("to"), total);
    if (s != sdlink::OK) { sendError(s); return; }
    markGood();
    server.send(200, "application/json", "{\"total\":" + String((double)total, 0) + "}");
}

static void handleCopyStep() {
    if (!authorized()) return;
    uint64_t copied = 0, total = 0;
    int s = sdlink::copyStep(copied, total);
    if (s != sdlink::OK) { sendError(s); return; }
    markGood();
    server.send(200, "application/json",
                "{\"copied\":" + String((double)copied, 0) + ",\"total\":" + String((double)total, 0) + "}");
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

// ---- The FPGA itself (fpgactl): settings, ESP32 mode, power, reset, status ----------------------------------------
static void sendFpgaResult(int s) {
    if (s == fpgactl::OK) { server.send(200, "application/json", "{}"); return; }
    int code = s == fpgactl::LOCKED ? 409 : s == fpgactl::BAD_REQUEST ? 400 : s == fpgactl::NO_REPLY ? 503 : 500;
    const char *why = s == fpgactl::LOCKED ? "The Lisa is on: the ROMs, the RAM size and managing a drive's files have to wait until it is off"
                    : s == fpgactl::NO_REPLY ? "The FPGA is not answering (it needs the control-channel build)"
                    : fpgactl::statusName(s);
    server.send(code, "application/json", String("{\"error\":\"") + why + "\"}");
}

static const char *B(bool b) { return b ? "true" : "false"; }

static void handleFpgaStatus() {
    if (!authorized()) return;
    fpgactl::Status s;
    int st = fpgactl::status(s);
    if (st != fpgactl::OK) { sendFpgaResult(st); return; }
    char o[700];
    snprintf(o, sizeof o,
             "{\"version\":%u,\"videoMode\":%u,\"has1024\":%s,\"modeUserSet\":%s,\"hOff\":%u,\"hLim\":%u,\"vOff\":%u,"
             "\"vLim\":%u,\"contrast\":%s,\"contrastJumper\":%s,\"speedUserSet\":%s,\"speedIdx\":%u,\"lisaOn\":%s,"
             "\"espMode\":%u,\"saved\":%s,\"saving\":%s,\"rom3A\":%s,\"tempC\":%.1f,\"hasMachine\":%s,"
             "\"scanlines\":%s,\"scanlinesJumper\":%s,\"inverse\":%s,\"inverseJumper\":%s,\"rom3ASwitch\":%s,"
             "\"twiggy\":%s,\"twiggySwitch\":%s,\"ram\":%u,\"ramSwitch\":%u,\"ramUserSet\":%s,\"serialB\":%u}",
             s.version, s.videoMode, s.has1024 ? "true" : "false", s.modeUserSet ? "true" : "false", s.hOff, s.hLim,
             s.vOff, s.vLim, s.contrast ? "true" : "false", s.contrastJumper ? "true" : "false",
             s.speedUserSet ? "true" : "false", s.speedIdx, s.lisaOn ? "true" : "false", s.espMode,
             s.saved ? "true" : "false", s.saving ? "true" : "false", s.rom3A ? "true" : "false", s.tempC,
             B(s.hasMachine), B(s.scanlines), B(s.scanlinesJumper), B(s.inverse), B(s.inverseJumper), B(s.rom3ASwitch),
             B(s.twiggy), B(s.twiggySwitch), s.ram, s.ramSwitch, B(s.ramUserSet), s.serialB);
    if (s.version >= 3) fujinet::noteRouted(s.serialB != 0);
    server.send(200, "application/json", o);
}

static void handleFpgaSet() {
    if (!authorized()) return;
    long reg = server.arg("reg").toInt(), value = server.arg("value").toInt();
    if (reg < 1 || reg == 7 || reg > 13 || value < 0 || value > 2047) { sendFpgaResult(fpgactl::BAD_REQUEST); return; }
    int s = fpgactl::set((uint8_t)reg, (uint16_t)value);
    if (s == fpgactl::OK && reg == fpgactl::REG_ESPMODE) lastGood = 0;   // a different SD server (or none) now
    if (s == fpgactl::OK && reg == fpgactl::REG_SERIALB) fujinet::noteRouted(value != 0);
    sendFpgaResult(s);
}

static void handleFujinetInfo() {
    if (!authorized()) return;
    server.send(200, "application/json", fujinet::infoJson());
}

static void handleFujinetSet() {
    if (!authorized()) return;
    if (server.hasArg("baud")) {
        long b = server.arg("baud").toInt();
        if (b != 1200 && b != 2400 && b != 4800 && b != 9600 && b != 19200 && b != 38400 && b != 57600 && b != 115200) {
            server.send(400, "application/json", "{\"error\":\"Unsupported baud rate\"}");
            return;
        }
        fujinet::setBaud(b);
    }
    if (server.hasArg("tz")) {
        String tz = server.arg("tz");
        tz.trim();
        if (!tz.length() || tz.length() > 60) {
            server.send(400, "application/json", "{\"error\":\"Give a POSIX time zone, such as CST6CDT,M3.2.0,M11.1.0\"}");
            return;
        }
        fujinet::setTimeZone(tz);
    }
    server.send(200, "application/json", fujinet::infoJson());
}

static void handleFpgaAction() {
    if (!authorized()) return;
    String a = server.arg("a");
    uint8_t act = a == "save" ? fpgactl::ACT_SAVE : a == "power" ? fpgactl::ACT_POWER : a == "reset" ? fpgactl::ACT_RESET : a == "nmi" ? fpgactl::ACT_NMI : 0;
    if (!act) { sendFpgaResult(fpgactl::BAD_REQUEST); return; }
    Serial.printf("[web] FPGA action: %s\r\n", a.c_str());
    if (act == fpgactl::ACT_SAVE) fujinet::save();       // Save settings keeps the FujiNet card's settings too
    sendFpgaResult(fpgactl::action(act));
}

// ---- The floppy drive's remote control (ESFloppy's drive firmware, NORMAL mode) ---------------
static void handleDriveStatus() {
    if (!authorized()) return;
    sdlink::DriveStatus s;
    int st = sdlink::driveStatus(s);
    if (st != sdlink::OK) { sendError(st); return; }
    String o = String("{\"twiggy\":") + B(s.twiggy) + ",\"uiBusy\":" + B(s.uiBusy) + ",\"emulMode\":" + s.emulMode + ",\"drives\":[";
    for (int d = 0; d < 2; d++) {
        if (d) o += ",";
        o += String("{\"n\":") + d + ",\"exists\":" + B(s.drive[d].exists) + ",\"inserted\":" + B(s.drive[d].inserted) +
             ",\"ejecting\":" + B(s.drive[d].ejecting) + ",\"name\":\"" + jsonEscape(s.drive[d].name) + "\"}";
    }
    o += "],\"fw\":\"" + jsonEscape(s.firmware) + "\"}";
    server.send(200, "application/json", o);
}

static void handleDriveLs() {
    if (!authorized()) return;
    String path = server.hasArg("path") ? server.arg("path") : "/";
    String o = "{\"path\":\"" + jsonEscape(path) + "\",\"entries\":[";
    int s = sdlink::driveList(path, listEntry, &o);
    if (s != sdlink::OK) { sendError(s); return; }
    o += "]}";
    server.send(200, "application/json", o);
}

static void handleDriveInsert() {
    if (!authorized()) return;
    long d = server.arg("drive").toInt();
    String path = server.arg("path");
    if (d < 0 || d > 1 || !path.startsWith("/")) { sendError(sdlink::BAD_REQUEST); return; }
    Serial.printf("[web] floppy remote: insert %s in drive %ld\r\n", path.c_str(), d);
    sendStatus(sdlink::driveInsert((uint8_t)d, path));
}

static void handleDriveEject() {
    if (!authorized()) return;
    long d = server.arg("drive").toInt();
    if (d < 0 || d > 1) { sendError(sdlink::BAD_REQUEST); return; }
    bool force = server.arg("force") == "1";
    Serial.printf("[web] floppy remote: %s eject of drive %ld\r\n", force ? "force" : "normal", d);
    sendStatus(sdlink::driveEject((uint8_t)d, force));
}

// ---- This board's own firmware (ota.h) -------------------------------------------------------
static void handleFwInfo() {
    if (!authorized()) return;
    server.send(200, "application/json", ota::infoJson());
}

static bool fwAuthed, fwOk;

static void handleFwBody() {
    HTTPRaw &raw = server.raw();
    switch (raw.status) {
        case RAW_START: {
            String pass = nvs.getString("webpass", "");
            fwAuthed = pass.length() && server.authenticate(WEB_USER, pass.c_str());
            fwOk = fwAuthed && ota::start(server.clientContentLength());   // nothing is written without the password
            break;
        }
        case RAW_WRITE:
            if (fwOk) ota::write(raw.buf, raw.currentSize);
            break;
        case RAW_END:
            if (fwOk) fwOk = ota::finish();
            break;
        case RAW_ABORTED:
            if (fwOk) ota::abort();
            fwOk = false;
            break;
    }
}

static void handleFwDone() {
    if (!authorized()) return;
    if (!fwOk) { server.send(400, "application/json", "{\"error\":\"" + jsonEscape(ota::error()) + "\"}"); return; }
    server.send(200, "application/json", "{\"version\":\"" + jsonEscape(ota::newVersion()) + "\"}");
    ota::restartSoon();
}

static void handleFwRollback() {
    if (!authorized()) return;
    if (!ota::rollBack()) { server.send(400, "application/json", "{\"error\":\"" + jsonEscape(ota::error()) + "\"}"); return; }
    server.send(200, "application/json", "{}");
    ota::restartSoon();
}

void begin() {
    nvs.begin(NVS_NAMESPACE, false);                // read-write: the setup page can set the web password
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
    server.on("/api/copystart", HTTP_POST, handleCopyStart);
    server.on("/api/copystep", HTTP_POST, handleCopyStep);
    server.on("/api/mv", HTTP_POST, handleMv);
    server.on("/api/mountnext", HTTP_GET, handleMountNextGet);
    server.on("/api/mountnext", HTTP_POST, handleMountNextSet);
    server.on("/api/fpga", HTTP_GET, handleFpgaStatus);
    server.on("/api/fpga/set", HTTP_POST, handleFpgaSet);
    server.on("/api/fpga/action", HTTP_POST, handleFpgaAction);
    server.on("/api/fujinet", HTTP_GET, handleFujinetInfo);
    server.on("/api/fujinet", HTTP_POST, handleFujinetSet);
    server.on("/api/drive", HTTP_GET, handleDriveStatus);
    server.on("/api/drive/ls", HTTP_GET, handleDriveLs);
    server.on("/api/drive/insert", HTTP_POST, handleDriveInsert);
    server.on("/api/drive/eject", HTTP_POST, handleDriveEject);
    server.on("/api/fw", HTTP_GET, handleFwInfo);
    server.on("/api/fw/update", HTTP_POST, handleFwDone, handleFwBody);
    server.on("/api/fw/rollback", HTTP_POST, handleFwRollback);
    server.on("/setup", HTTP_GET, handleSetupPage);
    server.on("/setup/info", HTTP_GET, handleSetupInfo);
    server.on("/setup/login", HTTP_POST, handleSetupLogin);
    server.on("/setup/scan", HTTP_GET, handleSetupScan);
    server.on("/setup/save", HTTP_POST, handleSetupSave);
    server.on("/setup/status", HTTP_GET, handleSetupStatus);
    server.onNotFound([]() {
        if (viaSetupNetwork()) { redirectToSetup(); return; }   // captive portal: phones' probe URLs land here
        server.send(404, "text/plain", "Not found\n");
    });
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
