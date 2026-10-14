// ---------------------------------------------------------------------------------------------
// atmodem -- AT commands on the Lisa's Serial A (9600 8N1). Written with an AI assistant.
// The same commands also work on the XIAO's USB console (115200), for setting it up from a PC; every response goes to both.
//
//   AT                       OK
//   ATI                      version information
//   ATE0 / ATE1              command echo off / on (default on: LisaTerminal does no local echo)
//   AT+HELP                  list the commands
//   AT+WSCAN                 scan for networks: index, RSSI (dBm), security, SSID
//   AT+WJOIN="ssid","pass"   join a network and remember it ("pass" may be empty for an open network)
//   AT+WJOIN                 rejoin the remembered network
//   AT+WSTATUS               connection state, SSID and signal
//   AT+WIP                   IP address, gateway, DNS and MAC
//   AT+WLEAVE                disconnect (the network stays remembered)
//   AT+WFORGET               disconnect and forget the remembered network
//   AT+WSETUP                bring up the setup network ("LisaNet-Setup") now, keeping what is saved
//   AT+WEBPASS="password"    set the web page's password (user name "lisa"); the page stays locked until one is set
//   AT+WEB                   the web page's address and whether a password is set
//   AT+SDINFO                check the link to ESFloppy: its firmware, card size and free space
//
// The remembered network and the web password are kept in NVS namespace "lisanet". NVS is not encrypted, so both are
// stored in the clear on the XIAO's flash.
// ---------------------------------------------------------------------------------------------
#include "atmodem.h"
#include "config.h"
#include "sdlink.h"
#include "fpgactl.h"
#include "wifisetup.h"
#include <WiFi.h>
#include <Preferences.h>

namespace atmodem {

#define JOIN_TIMEOUT_MS 20000
#define MAX_LINE 160

static HardwareSerial *lisa = nullptr;
static Preferences nvs;
static bool echoOn = true;

// ---- Output: everything goes to the Lisa and is mirrored on the USB console ----------------------
static void out(const char *s) {
    lisa->print(s);
    Serial.print(s);
}
static void outln(const char *s = "") { out(s); out("\r\n"); }
static void outf(const char *fmt, ...) {
    char buf[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    out(buf);
}
static void ok() { outln("OK"); }
static void error(const char *why = nullptr) {
    if (why) { out("ERROR: "); outln(why); }
    else outln("ERROR");
}

// ---- WiFi helpers ------------------------------------------------------------------------------
static const char *encName(wifi_auth_mode_t m) {
    switch (m) {
        case WIFI_AUTH_OPEN:            return "OPEN";
        case WIFI_AUTH_WEP:             return "WEP";
        case WIFI_AUTH_WPA_PSK:         return "WPA";
        case WIFI_AUTH_WPA2_PSK:        return "WPA2";
        case WIFI_AUTH_WPA_WPA2_PSK:    return "WPA/WPA2";
        case WIFI_AUTH_WPA3_PSK:        return "WPA3";
        case WIFI_AUTH_WPA2_WPA3_PSK:   return "WPA2/WPA3";
        case WIFI_AUTH_WPA2_ENTERPRISE: return "WPA2-ENT";
        default:                        return "OTHER";
    }
}

static const char *wifiStatusName(wl_status_t s) {
    switch (s) {
        case WL_CONNECTED:       return "CONNECTED";
        case WL_NO_SSID_AVAIL:   return "NETWORK NOT FOUND";
        case WL_CONNECT_FAILED:  return "CONNECT FAILED";
        case WL_CONNECTION_LOST: return "CONNECTION LOST";
        case WL_DISCONNECTED:    return "DISCONNECTED";
        case WL_IDLE_STATUS:     return "IDLE";
        default:                 return "NOT CONNECTED";
    }
}

static bool joinNetwork(const String &ssid, const String &pass) {
    WiFi.disconnect();
    WiFi.begin(ssid.c_str(), pass.length() ? pass.c_str() : nullptr);
    outf("JOINING %s\r\n", ssid.c_str());
    uint32_t start = millis();
    while (millis() - start < JOIN_TIMEOUT_MS) {
        wl_status_t s = WiFi.status();
        if (s == WL_CONNECTED) return true;
        if (s == WL_CONNECT_FAILED || s == WL_NO_SSID_AVAIL) break;
        delay(100);
    }
    return false;
}

// Parses n quoted fields separated by commas: "a","b". A backslash escapes the next character (for quotes in a name).
static bool parseQuoted(const char *p, String *fields[], int n) {
    for (int f = 0; f < n; f++) {
        while (*p == ' ') p++;
        if (f > 0) { if (*p != ',') return false; p++; while (*p == ' ') p++; }
        if (*p != '"') return false;
        p++;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) p++;
            *fields[f] += *p++;
        }
        if (*p != '"') return false;
        p++;
    }
    return true;
}

// ---- Commands ----------------------------------------------------------------------------------
static void cmdScan() {
    outln("SCANNING");
    int n = WiFi.scanNetworks();
    if (n < 0) { error("scan failed"); return; }
    for (int i = 0; i < n; i++)
        outf("%2d %4d %-9s %s\r\n", i + 1, WiFi.RSSI(i), encName(WiFi.encryptionType(i)), WiFi.SSID(i).c_str());
    outf("%d NETWORKS\r\n", n);
    WiFi.scanDelete();
    ok();
}

static void cmdJoin(const char *args) {
    String ssid, pass;
    if (*args == 0) {                          // AT+WJOIN: the remembered network
        ssid = nvs.getString("ssid", "");
        pass = nvs.getString("pass", "");
        if (!ssid.length()) { error("no remembered network"); return; }
    } else {
        String *f[2] = {&ssid, &pass};
        if (*args != '=' || !parseQuoted(args + 1, f, 2) || !ssid.length()) {
            error("use AT+WJOIN=\"ssid\",\"password\"");
            return;
        }
    }
    if (joinNetwork(ssid, pass)) {
        nvs.putString("ssid", ssid);
        nvs.putString("pass", pass);
        wifisetup::joined();
        outf("CONNECTED %s\r\n", WiFi.localIP().toString().c_str());
        ok();
    } else {
        error(wifiStatusName(WiFi.status()));
    }
}

static void cmdStatus() {
    wl_status_t s = WiFi.status();
    outf("STATUS %s\r\n", wifiStatusName(s));
    if (s == WL_CONNECTED) outf("SSID %s\r\nRSSI %d dBm\r\n", WiFi.SSID().c_str(), WiFi.RSSI());
    String saved = nvs.getString("ssid", "");
    outf("REMEMBERED %s\r\n", saved.length() ? saved.c_str() : "(none)");
    ok();
}

static void cmdIp() {
    if (WiFi.status() != WL_CONNECTED) { error("not connected"); return; }
    outf("IP %s\r\nMASK %s\r\nGATEWAY %s\r\nDNS %s\r\n", WiFi.localIP().toString().c_str(),
         WiFi.subnetMask().toString().c_str(), WiFi.gatewayIP().toString().c_str(), WiFi.dnsIP().toString().c_str());
    outf("MAC %s\r\n", WiFi.macAddress().c_str());
    ok();
}

static void cmdWebPass(const char *args) {
    String pass;
    String *f[1] = {&pass};
    if (*args != '=' || !parseQuoted(args + 1, f, 1) || pass.length() < 4) {
        error("use AT+WEBPASS=\"password\" (4 or more characters)");
        return;
    }
    nvs.putString("webpass", pass);
    outln("WEB PASSWORD SET (USER NAME: " WEB_USER ")");
    ok();
}

static void cmdWeb() {
    bool locked = nvs.getString("webpass", "").length() == 0;
    if (WiFi.status() == WL_CONNECTED)
        outf("WEB http://%s/  or  http://" MDNS_NAME ".local/\r\n", WiFi.localIP().toString().c_str());
    else
        outln("WEB not connected to a network (AT+WJOIN)");
    outln(locked ? "PASSWORD NOT SET: THE PAGE IS LOCKED (AT+WEBPASS)" : "PASSWORD SET, USER NAME: " WEB_USER);
    ok();
}

static void cmdSdInfo() {
    String fw;
    int s = sdlink::hello(fw);
    if (s != sdlink::OK) { error(sdlink::statusName(s)); return; }
    outf("ESFLOPPY %s\r\n", fw.c_str());
    uint64_t card = 0, freeBytes = 0;
    outln("READING CARD (UP TO 10 S)");
    s = sdlink::info(card, freeBytes);
    if (s != sdlink::OK) { error(sdlink::statusName(s)); return; }
    outf("CARD %llu MB, FREE %llu MB\r\n", card >> 20, freeBytes >> 20);
    ok();
}

// AT+FPGA: ask the FPGA for its status; on failure, show the request sent and every byte that came back
static void cmdFpga() {
    fpgactl::Status s;
    int st = fpgactl::status(s);
    if (st == fpgactl::OK) {
        outf("FPGA v%u MODE %u H %u/%u V %u/%u LISA %s ESP32 %u TEMP %.1f C\r\n", s.version, s.videoMode, s.hOff, s.hLim,
             s.vOff, s.vLim, s.lisaOn ? "ON" : "OFF", s.espMode, s.tempC);
        ok();
        return;
    }
    size_t n;
    const uint8_t *f = fpgactl::lastFrame(n);
    out("SENT");
    for (size_t i = 0; i < n; i++) outf(" %02X", f[i]);
    outln();
    const uint8_t *r = fpgactl::lastRaw(n);
    outf("GOT %u BYTES", (unsigned)n);
    for (size_t i = 0; i < n; i++) outf(" %02X", r[i]);
    outln();
    error(fpgactl::statusName(st));
}

static void cmdHelp() {
    outln("AT  ATI  ATE0  ATE1  AT+HELP");
    outln("AT+WSCAN  AT+WJOIN=\"ssid\",\"password\"  AT+WJOIN");
    outln("AT+WSTATUS  AT+WIP  AT+WLEAVE  AT+WFORGET  AT+WSETUP");
    outln("AT+WEBPASS=\"password\"  AT+WEB  AT+SDINFO  AT+FPGA");
    ok();
}

static void runCommand(char *cmd) {
    // Commands are case-insensitive; arguments (inside quotes) are not touched
    char *q = strchr(cmd, '"');
    for (char *c = cmd; *c && (!q || c < q); c++) *c = toupper(*c);
    // Log commands on the console, but never a password
    if (strncmp(cmd, "AT+WJOIN=", 9) == 0 || strncmp(cmd, "AT+WEBPASS=", 11) == 0) {
        Serial.printf("[cmd] %.*s... (password not logged)\r\n", (int)(strchr(cmd, '=') - cmd + 1), cmd);
    } else {
        Serial.printf("[cmd] %s\r\n", cmd);
    }

    if (*cmd == 0) return;                          // empty line: no response, like a modem
    if (strncmp(cmd, "AT", 2) != 0) { error(); return; }
    const char *c = cmd + 2;
    if      (*c == 0)                          ok();
    else if (strcmp(c, "I") == 0)              { outln("LISANET WIFI BOARD " LISANET_WIFI_VERSION " (XIAO ESP32S3)"); ok(); }
    else if (strcmp(c, "E0") == 0)             { echoOn = false; ok(); }
    else if (strcmp(c, "E1") == 0)             { echoOn = true; ok(); }
    else if (strcmp(c, "+HELP") == 0)          cmdHelp();
    else if (strcmp(c, "+WSCAN") == 0)         cmdScan();
    else if (strncmp(c, "+WJOIN", 6) == 0)     cmdJoin(c + 6);
    else if (strcmp(c, "+WSTATUS") == 0)       cmdStatus();
    else if (strcmp(c, "+WIP") == 0)           cmdIp();
    else if (strcmp(c, "+WLEAVE") == 0)        { WiFi.disconnect(); ok(); }
    else if (strcmp(c, "+WFORGET") == 0)       { WiFi.disconnect(); nvs.remove("ssid"); nvs.remove("pass"); ok(); }
    else if (strncmp(c, "+WEBPASS", 8) == 0)   cmdWebPass(c + 8);
    else if (strcmp(c, "+WEB") == 0)           cmdWeb();
    else if (strcmp(c, "+WSETUP") == 0)        { wifisetup::startAP("AT+WSETUP"); outln("SETUP NETWORK " SETUP_AP_SSID " IS UP (PASSWORD " SETUP_AP_PASS ")"); ok(); }
    else if (strcmp(c, "+SDINFO") == 0)        cmdSdInfo();
    else if (strcmp(c, "+FPGA") == 0)          cmdFpga();
    else                                       error("unknown command, try AT+HELP");
}

// Commands arrive from the Lisa and from the XIAO's own USB console (for bench setup from a PC). Each source has its own
// line buffer and gets its own echo; responses go to both.
struct Source {
    Stream *port;
    char line[MAX_LINE + 1];
    size_t len;
};
static Source fromLisa = {}, fromUsb = {};

// Line editing for one received byte; runs the command on CR (or LF, which is what a PC terminal usually sends)
static void feed(Source &src, char ch) {
    if (ch == '\r' || ch == '\n') {
        if (ch == '\n' && src.len == 0) return;      // the LF of a CR LF pair
        if (echoOn) src.port->print("\r\n");
        src.line[src.len] = 0;
        src.len = 0;
        runCommand(src.line);
        return;
    }
    if (ch == 0x08 || ch == 0x7F) {                  // backspace / delete
        if (src.len) { src.len--; if (echoOn) src.port->print("\b \b"); }
        return;
    }
    if (ch < 0x20 || src.len >= MAX_LINE) return;
    src.line[src.len++] = ch;
    if (echoOn) src.port->write((uint8_t)ch);
}

void begin(HardwareSerial &port) {
    lisa = &port;
    fromLisa.port = lisa;
    fromUsb.port = &Serial;
    lisa->setRxBufferSize(1024);                     // the loop can be busy for a while serving a web upload
    lisa->begin(LISA_BAUD, SERIAL_8N1, LISA_RX_PIN, LISA_TX_PIN);
    nvs.begin(NVS_NAMESPACE, false);
    outln("");
    outln("LISANET WIFI BOARD " LISANET_WIFI_VERSION " READY. TYPE AT+HELP");

}

void poll() {
    while (lisa->available()) feed(fromLisa, (char)lisa->read());
    while (Serial.available()) feed(fromUsb, (char)Serial.read());
}

}  // namespace atmodem
