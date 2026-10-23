// fujinet -- see fujinet.h. Written with an AI assistant.
//
// FujiBus framing, as fujinet-firmware sends and expects it on RS-232:
//   SLIP: C0 <packet, with C0 sent as DB DC and DB as DB DD> C0
//   packet: device, command, length (u16 LE, the whole decoded packet), checksum, descriptor, [more descriptors],
//           parameters (LE), data
//   checksum: 8-bit sum with end-around carry over the whole decoded packet, taken with the checksum byte at 0
//   descriptor: low 3 bits pick the parameters (0 none, 1-4 that many u8, 5 one u16, 6 two u16, 7 one u32); bit 7 set
//           means another descriptor byte follows the header
//   reply: the same device, command 06 (ACK, optionally with data) or 15 (NAK, never with data), no parameters
#include "fujinet.h"
#include "config.h"
#include "fpgactl.h"
#include "atmodem.h"
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <Preferences.h>
#include <time.h>
#include <sys/time.h>
#include "cJSON.h"
#include "chat.h"
#include "chatcore.h"

namespace fujinet {

// ---- Protocol constants -------------------------------------------------------------------------
enum : uint8_t { SLIP_END = 0xC0, SLIP_ESC = 0xDB, SLIP_ESC_END = 0xDC, SLIP_ESC_ESC = 0xDD };
enum : uint8_t { DEV_FUJINET = 0x70, DEV_CLOCK = 0x45, DEV_NET_FIRST = 0x71, DEV_NET_LAST = 0x78 };
enum : uint8_t { REPLY_ACK = 0x06, REPLY_NAK = 0x15 };
// NET_STATUS error codes (fujinet-firmware's NDEV_STATUS, Atari CIO numbering)
enum : uint8_t { ST_SUCCESS = 1, ST_EOF = 136, ST_GENERAL = 144, ST_NOT_IMPLEMENTED = 146, ST_INVALID_SPEC = 165,
                 ST_ACCESS_DENIED = 167, ST_NOT_FOUND = 170, ST_NOT_CONNECTED = 207, ST_BAD_JSON = 213,
                 ST_CLIENT_GENERAL = 214, ST_SERVER_GENERAL = 215 };

static const size_t MAX_PACKET = 1100;      // a header, a few parameters and up to ~1 KB of data
static const size_t RX_CHUNK   = 4096;      // what a STATUS pulls from the network into a unit's read buffer
static const size_t JSON_MAX   = 64 * 1024; // the most a JSON PARSE will collect (no PSRAM in this build)

static HardwareSerial *port = nullptr;
static Preferences nvs;
static bool isRouted = false;
static uint32_t curBaud = 9600;
static String tzMain = "UTC0", tzAlt;
static uint32_t packets = 0, naks = 0;
static uint32_t lastByteMs = 0, lastCheckMs = 0, checkEvery = 3000;

// A short log of what the Lisa asked for, newest last, for the web page (and the USB console)
static String logLines[12];
static int logCount = 0;
static void logf(const char *fmt, ...) {
    char buf[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    Serial.printf("[fuji] %s\r\n", buf);
    if (logCount == 12) { for (int i = 1; i < 12; i++) logLines[i - 1] = logLines[i]; logCount = 11; }
    char stamp[16];
    snprintf(stamp, sizeof stamp, "%lu ", (unsigned long)(millis() / 1000));
    logLines[logCount++] = String(stamp) + buf;
}

// ---- Packets ------------------------------------------------------------------------------------
struct Packet {
    uint8_t device, command;
    uint32_t param[8];
    int nparam;
    const uint8_t *data;
    size_t dataLen;
    uint32_t p(int i, uint32_t dflt = 0) const { return i < nparam ? param[i] : dflt; }
    String str() const {        // the data as text, stopping at the first NUL (FujiNet pads names to 256)
        String s;
        for (size_t i = 0; i < dataLen && data[i]; i++) s += (char)data[i];
        return s;
    }
};

static uint8_t checksum(const uint8_t *b, size_t n) {
    uint16_t c = 0;
    for (size_t i = 0; i < n; i++) { c += b[i]; c = (c >> 8) + (c & 0xFF); }
    return (uint8_t)c;
}

static bool parse(uint8_t *b, size_t n, Packet &pk) {
    if (n < 6) return false;
    if ((size_t)(b[2] | b[3] << 8) != n) return false;
    uint8_t ck = b[4];
    b[4] = 0;
    bool ok = checksum(b, n) == ck;
    b[4] = ck;
    if (!ok) return false;
    pk.device = b[0];
    pk.command = b[1];
    pk.nparam = 0;
    static const uint8_t SIZE[8] = {0, 1, 1, 1, 1, 2, 2, 4}, COUNT[8] = {0, 1, 2, 3, 4, 1, 2, 1};
    uint8_t descr[8];
    int nd = 0;
    size_t off = 6;
    uint8_t d = b[5];
    descr[nd++] = d;
    while ((d & 0x80) && nd < 8) {
        if (off >= n) return false;
        d = b[off++];
        descr[nd++] = d;
    }
    for (int i = 0; i < nd; i++) {
        uint8_t k = descr[i] & 0x07;
        for (int j = 0; j < COUNT[k]; j++) {
            if (off + SIZE[k] > n) return false;
            uint32_t v = 0;
            for (int x = 0; x < SIZE[k]; x++) v |= (uint32_t)b[off + x] << (8 * x);
            off += SIZE[k];
            if (pk.nparam < 8) pk.param[pk.nparam++] = v;
        }
    }
    pk.data = b + off;
    pk.dataLen = n - off;
    return true;
}

static void slipByte(uint8_t c) {
    if (c == SLIP_END)      { port->write(SLIP_ESC); port->write(SLIP_ESC_END); }
    else if (c == SLIP_ESC) { port->write(SLIP_ESC); port->write(SLIP_ESC_ESC); }
    else port->write(c);
}

static void reply(uint8_t device, bool ack, const uint8_t *data = nullptr, size_t n = 0) {
    if (!ack) { n = 0; naks++; }
    size_t len = 6 + n;
    uint8_t hdr[6] = {device, ack ? REPLY_ACK : REPLY_NAK, (uint8_t)len, (uint8_t)(len >> 8), 0, 0};
    uint16_t c = 0;                                     // the checksum over header and data, computed in pieces
    auto add = [&c](const uint8_t *b, size_t k) { for (size_t i = 0; i < k; i++) { c += b[i]; c = (c >> 8) + (c & 0xFF); } };
    add(hdr, 6);
    add(data, n);
    hdr[4] = (uint8_t)c;
    port->write(SLIP_END);
    for (int i = 0; i < 6; i++) slipByte(hdr[i]);
    for (size_t i = 0; i < n; i++) slipByte(data[i]);
    port->write(SLIP_END);
}
static void ack(const Packet &pk, const uint8_t *d = nullptr, size_t n = 0) { reply(pk.device, true, d, n); }
static void nak(const Packet &pk) { reply(pk.device, false); }
static void ackStr(const Packet &pk, const String &s) {   // a C string, NUL included, as FujiNet sends them
    ack(pk, (const uint8_t *)s.c_str(), s.length() + 1);
}
static void unknown(const Packet &pk) {
    logf("not supported: device %02X command %02X (%d params, %u data bytes) -> NAK", pk.device, pk.command,
         pk.nparam, (unsigned)pk.dataLen);
    nak(pk);
}

// ---- The FujiNet device (0x70) ------------------------------------------------------------------
static void putIp(uint8_t *p, IPAddress a) { for (int i = 0; i < 4; i++) p[i] = a[i]; }

static void adapterConfig(const Packet &pk, bool extended) {
    // ssid[33] hostname[64] ip[4] gateway[4] netmask[4] dns[4] mac[6] bssid[6] fn_version[15];
    // extended adds sLocalIP[16] sGateway[16] sNetmask[16] sDnsIP[16] sMacAddress[18] sBssid[18]
    uint8_t c[240] = {0};
    bool up = WiFi.status() == WL_CONNECTED;
    strlcpy((char *)c, up ? WiFi.SSID().c_str() : "NOT CONNECTED", 33);
    if (up) {
        strlcpy((char *)c + 33, MDNS_NAME, 64);
        putIp(c + 97, WiFi.localIP()); putIp(c + 101, WiFi.gatewayIP());
        putIp(c + 105, WiFi.subnetMask()); putIp(c + 109, WiFi.dnsIP());
        const uint8_t *bssid = WiFi.BSSID();
        if (bssid) memcpy(c + 119, bssid, 6);
    }
    WiFi.macAddress(c + 113);
    strlcpy((char *)c + 125, "LisaNet " LISANET_WIFI_VERSION, 15);
    if (extended) {
        strlcpy((char *)c + 140, WiFi.localIP().toString().c_str(), 16);
        strlcpy((char *)c + 156, WiFi.gatewayIP().toString().c_str(), 16);
        strlcpy((char *)c + 172, WiFi.subnetMask().toString().c_str(), 16);
        strlcpy((char *)c + 188, WiFi.dnsIP().toString().c_str(), 16);
        snprintf((char *)c + 204, 18, "%02X:%02X:%02X:%02X:%02X:%02X", c[113], c[114], c[115], c[116], c[117], c[118]);
        snprintf((char *)c + 222, 18, "%02X:%02X:%02X:%02X:%02X:%02X", c[119], c[120], c[121], c[122], c[123], c[124]);
    }
    ack(pk, c, extended ? 240 : 140);
}

static void closeAll();

static void fujiDevice(const Packet &pk) {
    switch (pk.command) {
        case 0xFA: {                                    // GET_WIFISTATUS: 3 connected, 6 not
            uint8_t s = WiFi.status() == WL_CONNECTED ? 3 : 6;
            ack(pk, &s, 1);
            break;
        }
        case 0xEA: { uint8_t one = 1; ack(pk, &one, 1); break; }       // GET_WIFI_ENABLED
        case 0xE8: adapterConfig(pk, false); break;                      // GET_ADAPTERCONFIG
        case 0xC4: adapterConfig(pk, true); break;                       // GET_ADAPTERCONFIG_EXTENDED
        case 0xFE: {                                    // GET_SSID: ssid[33] password[64] (the password is not given out)
            uint8_t c[97] = {0};
            strlcpy((char *)c, WiFi.SSID().c_str(), 33);
            ack(pk, c, sizeof c);
            break;
        }
        case 0x53: { uint8_t z[4] = {0}; ack(pk, z, 4); break; }       // FUJI_STATUS: no disk slots here
        case 0x00: {                                    // DEVICE_READY: the adapter's self-test answer, 512 'A's
            static uint8_t a[512];
            memset(a, 'A', sizeof a);
            ack(pk, a, sizeof a);
            break;
        }
        case 0xFF: closeAll(); ack(pk); break;          // FUJI_RESET: a real FujiNet restarts; closing every unit will do
        default: unknown(pk);
    }
}

// ---- The clock (0x45) ---------------------------------------------------------------------------
static struct tm localIn(const String &tz) {
    setenv("TZ", tz.c_str(), 1);
    tzset();
    time_t t = time(nullptr);
    struct tm tm;
    localtime_r(&t, &tm);
    setenv("TZ", tzMain.c_str(), 1);
    tzset();
    return tm;
}

static void clockDevice(const Packet &pk) {
    bool alt = pk.nparam > 0 && pk.param[0] == 0x01;    // parameter 1 = use the alternate time zone
    const String &tz = alt && tzAlt.length() ? tzAlt : tzMain;
    char s[40];
    switch (pk.command) {
        case 0x93: case 0x9A: {                         // GETTIME / GETTZTIME: day month yy hour min sec
            struct tm t = localIn(pk.command == 0x9A && tzAlt.length() ? tzAlt : tz);
            uint8_t b[6] = {(uint8_t)t.tm_mday, (uint8_t)(t.tm_mon + 1), (uint8_t)(t.tm_year - 100),
                            (uint8_t)t.tm_hour, (uint8_t)t.tm_min, (uint8_t)t.tm_sec};
            ack(pk, b, 6);
            break;
        }
        case 0x54: case 0x4D: {                         // simple: century yy month day hour min sec [hundredths]
            struct timeval tv;
            gettimeofday(&tv, nullptr);
            struct tm t = localIn(tz);
            uint8_t b[8] = {(uint8_t)(t.tm_year / 100 + 19), (uint8_t)(t.tm_year % 100), (uint8_t)(t.tm_mon + 1),
                            (uint8_t)t.tm_mday, (uint8_t)t.tm_hour, (uint8_t)t.tm_min, (uint8_t)t.tm_sec,
                            (uint8_t)(tv.tv_usec / 10000)};
            ack(pk, b, pk.command == 0x4D ? 8 : 7);
            break;
        }
        case 0x50: {                                    // ProDOS
            struct tm t = localIn(tz);
            uint8_t b[4] = {(uint8_t)(t.tm_mday + ((t.tm_mon + 1) << 5)),
                            (uint8_t)(((t.tm_year % 100) << 1) + ((t.tm_mon + 1) >> 3)), (uint8_t)t.tm_min,
                            (uint8_t)t.tm_hour};
            ack(pk, b, 4);
            break;
        }
        case 0x53: { struct tm t = localIn(tz); strftime(s, sizeof s, "%Y%m%d0%H%M%S000", &t); ackStr(pk, s); break; }
        case 0x49: { struct tm t = localIn(tz); strftime(s, sizeof s, "%Y-%m-%dT%H:%M:%S%z", &t); ackStr(pk, s); break; }
        case 0x5A: { struct tm t = localIn("UTC0"); strftime(s, sizeof s, "%Y-%m-%dT%H:%M:%S%z", &t); ackStr(pk, s); break; }
        case 0x47: ackStr(pk, tzMain); break;           // the time zone
        case 0x4C: { uint8_t n = tzMain.length() + 1; ack(pk, &n, 1); break; }
        case 0x99: tzAlt = pk.str(); ack(pk); logf("alternate time zone: %s", tzAlt.c_str()); break;
        case 0x74: setTimeZone(pk.str()); ack(pk); break;
        default: unknown(pk);
    }
}

// ---- Network units N1-N8 (0x71-0x78) ------------------------------------------------------------
struct Unit {
    bool open = false;
    String url, method;
    uint8_t mode = 0, trans = 0;
    bool performed = false, done = false, json = false;
    uint8_t err = ST_SUCCESS;
    std::string rx;                 // what is ready for READ (translated), pulled from the network by STATUS/READ
    std::string tx;                 // what WRITE collected, sent with the request
    std::string eol = "\r\n";       // the Lisa's line ending (translation target); SET_EOL changes it
    std::string jsonEol = "\n";     // between JSON query values, as fujinet-firmware's JSON parser
    String login, password;
    HTTPClient *http = nullptr;
    WiFiClient *client = nullptr;
    NetworkClient *stream = nullptr;
    int32_t remaining = -1;         // body bytes still to come, -1 when the server did not say
    cJSON *root = nullptr;
    bool chat = false;              // a chat:// unit (chat.cpp): WRITE collects the question, STATUS/READ deliver the answer
    int chatKind = 0;               // 0 default provider, 1 Claude, 2 OpenAI
    bool chatAsked = false;         // the question has been handed to chat.cpp
};
static Unit units[8];

static void release(Unit &u) {
    if (u.http) { u.http->end(); delete u.http; u.http = nullptr; }
    if (u.client) { delete u.client; u.client = nullptr; }
    if (u.root) { cJSON_Delete(u.root); u.root = nullptr; }
    u.stream = nullptr;
}
static void reset(Unit &u) {
    release(u);
    u = Unit();
}
static void closeAll() { for (auto &u : units) reset(u); }

static void replaceAll(std::string &s, const std::string &from, const std::string &to) {
    if (from.empty() || from == to) return;
    for (size_t i = 0; (i = s.find(from, i)) != std::string::npos; i += to.size()) s.replace(i, from.size(), to);
}
static const char *netEol(uint8_t trans) { return trans == 1 ? "\r" : trans == 2 ? "\n" : trans == 3 ? "\r\n" : ""; }

// "N1:https://host/x" or "N:HTTPS://host/x" -> "https://host/x" (scheme lower-cased)
static String cleanUrl(String s) {
    int colon = s.indexOf(':');
    if (colon > 0 && colon <= 3 && (s[0] == 'N' || s[0] == 'n') && s.substring(colon + 1).indexOf("://") > 0)
        s = s.substring(colon + 1);
    int sep = s.indexOf("://");
    if (sep > 0) { String scheme = s.substring(0, sep); scheme.toLowerCase(); s = scheme + s.substring(sep); }
    return s;
}

static uint8_t httpError(int code) {
    if (code < 0) return ST_NOT_CONNECTED;
    if (code < 300) return ST_SUCCESS;
    if (code == 401 || code == 402 || code == 403 || code == 407) return ST_ACCESS_DENIED;
    if (code == 404 || code == 410) return ST_NOT_FOUND;
    if (code < 500) return ST_CLIENT_GENERAL;
    return ST_SERVER_GENERAL;
}

// Run the request: on the first STATUS, READ or PARSE (as fujinet-firmware does), or at CLOSE for a write that was
// never read back. The body is not read here; pull() takes it as the Lisa asks.
static void perform(Unit &u, int n) {
    if (u.performed) return;
    u.performed = true;
    if (WiFi.status() != WL_CONNECTED) { u.err = ST_NOT_CONNECTED; u.done = true; logf("N%d: no WiFi", n); return; }
    bool tls = u.url.startsWith("https://");
    if (tls) { auto *c = new WiFiClientSecure(); c->setInsecure(); u.client = c; }   // no certificate store here
    else u.client = new WiFiClient();
    u.http = new HTTPClient();
    u.http->useHTTP10(true);                            // no chunked encoding: the body streams as sent
    u.http->setFollowRedirects(HTTPC_FORCE_FOLLOW_REDIRECTS);
    u.http->setTimeout(10000);
    u.http->setUserAgent("LisaNet-FujiNet/" LISANET_WIFI_VERSION);
    if (!u.http->begin(*u.client, u.url)) { u.err = ST_INVALID_SPEC; u.done = true; release(u); return; }
    if (u.login.length()) u.http->setAuthorization(u.login.c_str(), u.password.c_str());
    int code = u.http->sendRequest(u.method.c_str(), (uint8_t *)u.tx.data(), u.tx.size());
    u.tx.clear();
    u.err = httpError(code);
    logf("N%d: %s %s -> %d", n, u.method.c_str(), u.url.c_str(), code);
    if (u.err != ST_SUCCESS) { u.done = true; release(u); return; }
    u.remaining = u.http->getSize();
    u.stream = u.http->getStreamPtr();
    if (u.remaining == 0 || !u.stream) { u.done = true; release(u); }
}

// Move what has arrived into rx (translated), up to about RX_CHUNK waiting
static void pull(Unit &u) {
    if (u.done || !u.stream) return;
    static uint8_t buf[1024];
    while (u.rx.size() < RX_CHUNK) {
        int avail = u.stream->available();
        if (avail <= 0) {
            if (!u.stream->connected()) { u.done = true; release(u); }
            break;
        }
        size_t want = min((size_t)avail, sizeof buf);
        if (u.remaining >= 0) want = min(want, (size_t)u.remaining);
        int got = u.stream->read(buf, want);
        if (got <= 0) break;
        std::string chunk((const char *)buf, got);
        if (u.trans >= 1 && u.trans <= 3) replaceAll(chunk, netEol(u.trans), u.eol);   // every mode's ending is one
        u.rx += chunk;                                                                  // character or CR LF itself
        if (u.remaining >= 0 && (u.remaining -= got) == 0) { u.done = true; release(u); break; }
    }
}

// ---- JSON (NET_SET_PARSER 1, then PARSE and QUERY), output as fujinet-firmware's JSON parser gives it --------------
static void jsonValue(cJSON *it, std::string &out, const std::string &eol) {
    if (!it) return;
    if (cJSON_IsString(it)) out += std::string(it->valuestring) + eol;
    else if (cJSON_IsBool(it)) out += std::string(cJSON_IsTrue(it) ? "TRUE" : "FALSE") + eol;
    else if (cJSON_IsNull(it)) out += "NULL" + eol;
    else if (cJSON_IsNumber(it)) {
        char b[32];
        double v = it->valuedouble;
        if (fabs(v - llround(v)) < 1e-9 && fabs(v) < 9e18) snprintf(b, sizeof b, "%lld", (long long)llround(v));
        else snprintf(b, sizeof b, "%.10g", v);
        out += std::string(b) + eol;
    } else if (cJSON_IsObject(it)) {
        if (!it->child) out += eol;
        for (cJSON *c = it->child; c; c = c->next) { out += std::string(c->string) + eol; jsonValue(c, out, eol); }
    } else if (cJSON_IsArray(it)) {
        for (cJSON *c = it->child; c; c = c->next) jsonValue(c, out, eol);
    } else out += "UNKNOWN" + eol;
}

// A JSON pointer: /key/0/other (~1 is '/', ~0 is '~'); empty means the whole document
static cJSON *jsonPointer(cJSON *root, const String &q) {
    cJSON *it = root;
    int i = 0;
    if (q.length() && q[0] == '/') i = 1;
    while (it && i < (int)q.length()) {
        int j = q.indexOf('/', i);
        if (j < 0) j = q.length();
        String key = q.substring(i, j);
        key.replace("~1", "/");
        key.replace("~0", "~");
        if (cJSON_IsArray(it)) {
            bool digits = key.length() > 0;
            for (char ch : key) if (!isdigit((unsigned char)ch)) digits = false;
            it = digits ? cJSON_GetArrayItem(it, key.toInt()) : nullptr;
        } else if (cJSON_IsObject(it)) {
            it = cJSON_GetObjectItemCaseSensitive(it, key.c_str());
        } else it = nullptr;
        i = j + 1;
    }
    return it;
}

// A chat:// unit: the first STATUS or READ hands the question (what WRITE collected) to chat.cpp, which answers on a task
// of its own; until then STATUS says 0 bytes waiting but still connected, so the Lisa keeps polling. The answer is plain
// ASCII with \n line ends, translated to the unit's line ending like any other text.
static void chatPump(Unit &u, int n) {
    auto fail = [&](const char *why) {
        u.chatAsked = u.performed = u.done = true;
        u.rx = std::string("[error: ") + why + "]" + (u.trans >= 1 && u.trans <= 3 ? u.eol : std::string("\n"));
    };
    if (!u.chatAsked) {
        std::string q = u.tx;
        u.tx.clear();
        while (!q.empty() && (q.back() == '\r' || q.back() == '\n')) q.pop_back();
        if (q.empty()) { fail("nothing was written before reading"); return; }
        if (!chat::start(u.chatKind, q, true)) { fail("the chat is busy with another question"); return; }
        u.chatAsked = u.performed = true;
        logf("N%d: chat question, %u characters", n, (unsigned)q.size());
    }
    if (!u.done && chat::state() == chat::REPLY) {
        std::string r = chat::takeReply() + "\n";
        if (u.trans >= 1 && u.trans <= 3) replaceAll(r, "\n", u.eol);
        u.rx += r;
        u.done = true;
        logf("N%d: chat answer, %u bytes", n, (unsigned)r.size());
    }
}

static void netDevice(const Packet &pk) {
    int n = pk.device - DEV_NET_FIRST + 1;
    Unit &u = units[n - 1];
    switch (pk.command) {
        case 0x4F: {                                    // OPEN: mode, translation; data = the URL
            reset(u);
            u.url = cleanUrl(pk.str());
            u.mode = pk.p(0);
            u.trans = pk.p(1) & 0x03;
            chatcore::Target target;
            if (chatcore::parseTarget(pk.str().c_str(), target)) {
                u.chat = true;
                u.open = true;
                u.method = "CHAT";
                if (target.kind == chatcore::Target::RESET) {   // chat://reset: forget the conversation, answer "OK"
                    chat::resetHistory();
                    u.chatAsked = u.performed = u.done = true;
                    u.rx = "OK" + (u.trans >= 1 && u.trans <= 3 ? u.eol : std::string("\n"));
                } else {
                    if (chat::state() == chat::REPLY) chat::takeReply();   // nobody claimed the last answer
                    u.chatKind = target.kind == chatcore::Target::CLAUDE ? 1 : target.kind == chatcore::Target::OPENAI ? 2 : 0;
                }
                logf("N%d: OPEN %s (chat)", n, pk.str().c_str());
                ack(pk);
                break;
            }
            if (!u.url.startsWith("http://") && !u.url.startsWith("https://")) {
                logf("N%d: OPEN %s -> only http:// and https:// are supported here", n, u.url.c_str());
                u.err = ST_NOT_IMPLEMENTED;
                nak(pk);
                return;
            }
            switch (u.mode) {
                case 4: case 12: u.method = "GET"; break;
                case 13: case 14: u.method = "POST"; break;   // fujinet-firmware treats 14 (PUT with headers) as POST
                case 8: u.method = "PUT"; break;
                case 5: case 9: u.method = "DELETE"; break;
                default:
                    logf("N%d: OPEN mode %u is not supported", n, u.mode);
                    u.err = ST_NOT_IMPLEMENTED;
                    nak(pk);
                    return;
            }
            u.open = true;
            logf("N%d: OPEN %s mode %u trans %u", n, u.url.c_str(), u.mode, u.trans);
            ack(pk);
            break;
        }
        case 0x53: {                                    // STATUS: bytes waiting (u16), connected, error
            uint16_t avail = 0;
            uint8_t conn = 0, err = u.err;
            if (u.open && u.chat) {
                chatPump(u, n);
                avail = min(u.rx.size(), (size_t)65535);
                conn = u.done ? 0 : 1;
                err = (avail == 0 && u.done) ? ST_EOF : ST_SUCCESS;
            } else if (u.open) {
                if (u.json && u.root) {                 // after a QUERY, rx holds its answer
                    avail = min(u.rx.size(), (size_t)65535);
                    conn = 1;
                    err = avail ? ST_SUCCESS : ST_EOF;
                } else {
                    perform(u, n);
                    pull(u);
                    avail = min(u.rx.size(), (size_t)65535);
                    conn = u.done ? 0 : 1;
                    if (avail == 0 && u.done && u.err == ST_SUCCESS) err = ST_EOF;
                }
            } else if (err == ST_SUCCESS) err = ST_NOT_CONNECTED;
            uint8_t b[4] = {(uint8_t)avail, (uint8_t)(avail >> 8), conn, err};
            ack(pk, b, 4);
            break;
        }
        case 0x52: {                                    // READ: u16 count
            size_t want = pk.p(0);
            if (!u.open || !want) { nak(pk); return; }
            if (u.chat) chatPump(u, n);
            else if (!(u.json && u.root)) { perform(u, n); pull(u); }
            size_t give = min(want, u.rx.size());
            if (!give) { nak(pk); return; }
            ack(pk, (const uint8_t *)u.rx.data(), give);
            u.rx.erase(0, give);
            break;
        }
        case 0x57: {                                    // WRITE: data to send with the request
            if (!u.open || u.performed) { nak(pk); return; }
            std::string d((const char *)pk.data, pk.dataLen);
            if (u.trans >= 1 && u.trans <= 3) replaceAll(d, u.eol, netEol(u.trans));
            u.tx += d;
            ack(pk);
            break;
        }
        case 0x43:                                      // CLOSE: a write that was never read back is sent now
            if (u.open && !u.chat && !u.performed && u.method != "GET") perform(u, n);
            reset(u);
            ack(pk);
            break;
        case 0x54: u.trans = pk.p(0) & 0x03; ack(pk); break;                 // TRANSLATION
        case 0x4C:                                                           // SET_EOL
            if (pk.dataLen) { u.eol = std::string((const char *)pk.data, pk.dataLen); u.jsonEol = u.eol; }
            ack(pk);
            break;
        case 0xFC:                                      // SET_PARSER: parameter 1 is the mode (1 = JSON)
            if (pk.p(1) > 1) { logf("N%d: parser %u not supported (JSON only)", n, (unsigned)pk.p(1)); nak(pk); return; }
            u.json = pk.p(1) == 1;
            if (!u.json && u.root) { cJSON_Delete(u.root); u.root = nullptr; u.rx.clear(); }
            ack(pk);
            break;
        case 0x50: {                                    // PARSE: read the whole body and parse it as JSON
            if (!u.open || !u.json) { nak(pk); return; }
            perform(u, n);
            std::string body = u.rx;
            u.rx.clear();
            uint32_t start = millis();
            while (!u.done && body.size() < JSON_MAX && millis() - start < 15000) {
                pull(u);
                body += u.rx;
                u.rx.clear();
                if (!u.done) delay(2);
            }
            if (u.root) cJSON_Delete(u.root);
            u.root = body.empty() ? nullptr : cJSON_Parse(body.c_str());
            if (!u.root) { u.err = ST_BAD_JSON; logf("N%d: PARSE failed (%u bytes)", n, (unsigned)body.size()); nak(pk); return; }
            ack(pk);
            break;
        }
        case 0x51: {                                    // QUERY: data = a JSON pointer; its value becomes the read data
            if (!u.root) { nak(pk); return; }
            u.rx.clear();
            jsonValue(jsonPointer(u.root, pk.str()), u.rx, u.jsonEol);
            ack(pk);
            break;
        }
        case 0xFD: u.login = pk.str(); ack(pk); break;                       // USERNAME
        case 0xFE: u.password = pk.str(); ack(pk); break;                    // PASSWORD
        case 0x5A: ack(pk); break;                                           // SET_INT_RATE: no interrupts here
        default: unknown(pk);
    }
}

// ---- Receive ------------------------------------------------------------------------------------
static uint8_t frame[MAX_PACKET];
static size_t frameLen = 0;
static bool inFrame = false, escaped = false, overflow = false;

static void handleFrame() {
    Packet pk;
    if (overflow || !parse(frame, frameLen, pk)) {
        logf("dropped a bad packet (%u bytes%s)", (unsigned)frameLen, overflow ? ", too long" : "");
        return;
    }
    packets++;
    if (pk.device == DEV_FUJINET) fujiDevice(pk);
    else if (pk.device == DEV_CLOCK) clockDevice(pk);
    else if (pk.device >= DEV_NET_FIRST && pk.device <= DEV_NET_LAST) netDevice(pk);
    else unknown(pk);
}

static void rxByte(uint8_t c) {
    if (c == SLIP_END) {
        if (inFrame && frameLen) handleFrame();
        inFrame = true;                                 // an END both closes a frame and opens the next
        frameLen = 0; escaped = false; overflow = false;
        return;
    }
    if (!inFrame) return;
    if (escaped) {
        escaped = false;
        c = c == SLIP_ESC_END ? SLIP_END : c == SLIP_ESC_ESC ? SLIP_ESC : c;
    } else if (c == SLIP_ESC) { escaped = true; return; }
    if (frameLen < sizeof frame) frame[frameLen++] = c;
    else overflow = true;
}

// ---- Public -------------------------------------------------------------------------------------
void begin(HardwareSerial &p) {
    port = &p;
    nvs.begin("fujinet", false);
    curBaud = nvs.getUInt("baud", 9600);
    tzMain = nvs.getString("tz", "UTC0");
    setenv("TZ", tzMain.c_str(), 1);
    tzset();
}

bool routed() { return isRouted; }

void noteRouted(bool on) {
    if (on == isRouted) return;
    isRouted = on;
    inFrame = false;
    closeAll();
    atmodem::setLisaAttached(!on);                      // the modem stays off the wires while Serial B has them
    port->updateBaudRate(on ? curBaud : LISA_BAUD);
    while (port->available()) port->read();
    if (on) logf("Serial B is on the WiFi board: FujiNet on, %lu baud", (unsigned long)curBaud);
    else logf("Serial B is back on its own port: FujiNet off, the Serial A modem is back");
}

uint32_t baud() { return curBaud; }
void setBaud(uint32_t b) {
    curBaud = b;
    if (isRouted) port->updateBaudRate(b);
}

void save() {
    if (nvs.getUInt("baud", 9600) != curBaud) nvs.putUInt("baud", curBaud);
    if (nvs.getString("tz", "UTC0") != tzMain) nvs.putString("tz", tzMain);
}
bool unsaved() { return nvs.getUInt("baud", 9600) != curBaud || nvs.getString("tz", "UTC0") != tzMain; }

String timeZone() { return tzMain; }
void setTimeZone(const String &tz) {
    if (!tz.length() || tz.length() > 60) return;
    tzMain = tz;
    setenv("TZ", tz.c_str(), 1);
    tzset();
    logf("time zone: %s", tz.c_str());
}

void poll() {
    static bool sntpStarted = false;                   // SNTP needs the network stack: start it once WiFi is up
    if (!sntpStarted && WiFi.status() == WL_CONNECTED) {
        sntpStarted = true;
        configTzTime(tzMain.c_str(), "pool.ntp.org", "time.nist.gov");
    }
    if (isRouted) {
        while (port->available()) { lastByteMs = millis(); rxByte(port->read()); }
    }
    // Learn whether the FPGA has Serial B on J21 (the web page reports it too, every few seconds while open). Only
    // between packets, and quickly: one attempt, so an FPGA without the control channel costs at most ~0.4 s a minute.
    uint32_t now = millis();
    if (now - lastCheckMs >= checkEvery && now - lastByteMs > 2000 && !inFrame) {
        lastCheckMs = now;
        fpgactl::Status s;
        int st = fpgactl::status(s, 1);
        if (st == fpgactl::OK) { noteRouted(s.serialB != 0); checkEvery = 10000; }
        else checkEvery = 60000;                        // not answering (an older FPGA build): try again in a minute
    }
}

static String jsonEsc(const String &s) {
    String o;
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if ((uint8_t)c < 0x20) o += ' ';
        else o += c;
    }
    return o;
}

String infoJson() {
    time_t t = time(nullptr);
    struct tm tm;
    localtime_r(&t, &tm);
    char ts[40];
    if (tm.tm_year >= 120) strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
    else strcpy(ts, "not set yet (no NTP answer)");
    String o = "{\"routed\":" + String(isRouted ? "true" : "false") + ",\"baud\":" + String(curBaud) + ",\"tz\":\"" +
               jsonEsc(tzMain) + "\",\"unsaved\":" + String(unsaved() ? "true" : "false") + ",\"time\":\"" + ts + "\",\"packets\":" + String(packets) + ",\"naks\":" +
               String(naks) + ",\"log\":[";
    for (int i = 0; i < logCount; i++) o += String(i ? "," : "") + "\"" + jsonEsc(logLines[i]) + "\"";
    return o + "]}";
}

}  // namespace fujinet
