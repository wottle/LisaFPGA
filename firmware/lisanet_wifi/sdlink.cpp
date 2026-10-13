// sdlink -- LisaNet link client (docs/lisanet_link_protocol.md). Written with an AI assistant.
// The same framing and retry rules as tools/lisanet_client/lisanet.ps1, which was used to test the server over USB.
#include "sdlink.h"

namespace sdlink {

static HardwareSerial *port = nullptr;
static uint8_t seq = 0;
static uint8_t rx[6 + MAX_DATA + 64 + 4];   // one response frame
static size_t rxLen = 0;                     // payload length of the last response
static const uint8_t HANDLE = 1;

static const char *const names[] = {"OK", "NOT_FOUND", "EXISTS", "IO", "BAD_REQUEST", "NO_HANDLE", "UNKNOWN_CMD",
                                    "NO_CARD", "NO_CONTIGUOUS"};
const char *statusName(int s) {
    if (s == TIMEOUT) return "NO_RESPONSE (is ESP32 MODE set to WIFI?)";
    return (s >= 0 && s < (int)(sizeof names / sizeof names[0])) ? names[s] : "UNKNOWN";
}

static uint32_t crcTable[256];
static void crcInit() {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crcTable[i] = c;
    }
}
static uint32_t crcUpdate(uint32_t c, const uint8_t *p, size_t n) {
    while (n--) c = crcTable[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return c;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) { p[i] = v; v >>= 8; } }
static uint16_t get16(const uint8_t *p) { return p[0] | (uint16_t)p[1] << 8; }
static uint64_t get64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | p[i]; return v; }

void begin(HardwareSerial &p, int rxPin, int txPin, uint32_t baud) {
    crcInit();
    port = &p;
    port->setRxBufferSize(8192);
    port->setTxBufferSize(8192);
    port->begin(baud, SERIAL_8N1, rxPin, txPin);
}

// Waits for the response to (cmd, seq). Returns true with the payload in rx[6..] and its length in rxLen.
static bool readResponse(uint8_t wantCmd, uint8_t wantSeq, uint32_t timeoutMs) {
    uint32_t start = millis();
    size_t have = 0, need = 0;
    while (millis() - start < timeoutMs) {
        if (!port->available()) { delay(0); continue; }
        uint8_t b = port->read();
        if (have == 0 && b != 0xA5) continue;
        if (have == 1 && b != 0x5A) { have = (b == 0xA5) ? 1 : 0; continue; }
        rx[have++] = b;
        if (have == 6) {
            uint16_t len = get16(rx + 4);
            if (len > MAX_DATA + 64) { have = 0; continue; }
            need = 6 + len + 4;
        }
        if (have >= 6 && have == need) {
            uint16_t len = get16(rx + 4);
            uint32_t want = rx[6 + len] | (uint32_t)rx[7 + len] << 8 | (uint32_t)rx[8 + len] << 16 | (uint32_t)rx[9 + len] << 24;
            uint32_t c = crcUpdate(0xFFFFFFFFu, rx + 2, 4 + len) ^ 0xFFFFFFFFu;
            if (c == want && rx[2] == wantCmd && rx[3] == wantSeq) { rxLen = len; return true; }
            have = 0;                                  // corrupt, or a stale answer to an earlier attempt
        }
    }
    return false;
}

// One request with retries. On success the response payload (after the status byte) is at rx + 7, length rxLen - 1.
static int call(uint8_t cmd, const uint8_t *a, size_t na, const uint8_t *b = nullptr, size_t nb = 0,
                uint32_t timeoutMs = 1000) {
    if (!port) return TIMEOUT;
    seq++;
    uint8_t hdr[6] = {0xA5, 0x5A, cmd, seq, 0, 0};
    put16(hdr + 4, na + nb);
    uint32_t c = crcUpdate(0xFFFFFFFFu, hdr + 2, 4);
    c = crcUpdate(c, a, na);
    if (nb) c = crcUpdate(c, b, nb);
    c ^= 0xFFFFFFFFu;
    uint8_t tail[4] = {(uint8_t)c, (uint8_t)(c >> 8), (uint8_t)(c >> 16), (uint8_t)(c >> 24)};
    for (int attempt = 0; attempt < 4; attempt++) {
        while (port->available()) port->read();
        port->write(hdr, 6);
        if (na) port->write(a, na);
        if (nb) port->write(b, nb);
        port->write(tail, 4);
        if (readResponse(cmd | 0x80, seq, timeoutMs)) return rxLen ? rx[6] : BAD_REQUEST;
    }
    return TIMEOUT;
}

static const uint8_t *resp() { return rx + 7; }
static size_t respLen() { return rxLen ? rxLen - 1 : 0; }

static int pathCall(uint8_t cmd, const String &path, uint32_t timeoutMs = 2000) {
    return call(cmd, (const uint8_t *)path.c_str(), path.length(), nullptr, 0, timeoutMs);
}

int hello(String &fw) {
    int s = call(0x01, nullptr, 0, nullptr, 0, 500);
    if (s == OK && respLen() >= 3) fw = String((const char *)resp() + 3).substring(0, respLen() - 3);
    return s;
}

int info(uint64_t &card, uint64_t &freeBytes) {
    int s = call(0x02, nullptr, 0, nullptr, 0, 20000);
    if (s == OK && respLen() >= 16) { card = get64(resp()); freeBytes = get64(resp() + 8); }
    return s;
}

int list(const String &path, void (*fn)(const Entry &, void *), void *ctx) {
    uint16_t start = 0;
    while (start != 0xFFFF) {
        uint8_t a[2];
        put16(a, start);
        int s = call(0x10, a, 2, (const uint8_t *)path.c_str(), path.length(), 5000);
        if (s != OK) return s;
        const uint8_t *r = resp();
        size_t n = respLen(), o = 2;
        start = get16(r);
        while (o + 10 <= n) {
            Entry e;
            e.dir = r[o] & 1;
            e.size = get64(r + o + 1);
            uint8_t nl = r[o + 9];
            char tmp[256];
            memcpy(tmp, r + o + 10, nl); tmp[nl] = 0;
            e.name = tmp;
            fn(e, ctx);
            o += 10 + nl;
        }
    }
    return OK;
}

int stat(const String &path, bool &isDir, uint64_t &size) {
    int s = pathCall(0x11, path);
    if (s == OK && respLen() >= 9) { isDir = resp()[0] & 1; size = get64(resp() + 1); }
    return s;
}

int openRead(const String &path, uint64_t &size) {
    uint8_t m = 0;
    int s = call(0x20, &m, 1, (const uint8_t *)path.c_str(), path.length(), 2000);
    if (s == OK && respLen() >= 9) size = get64(resp() + 1);
    return s;
}

int openWriteReserve(const String &path, uint64_t size) {
    uint8_t a[9] = {3};
    put64(a + 1, size);
    return call(0x20, a, 9, (const uint8_t *)path.c_str(), path.length(), 30000);   // preAllocate scans the FAT
}

int read(uint64_t off, uint8_t *buf, size_t want, size_t &got) {
    if (want > MAX_DATA) want = MAX_DATA;
    uint8_t a[11] = {HANDLE};
    put64(a + 1, off);
    put16(a + 9, want);
    int s = call(0x21, a, 11, nullptr, 0, 2000);
    got = 0;
    if (s == OK) { got = respLen(); memcpy(buf, resp(), got); }
    return s;
}

int write(uint64_t off, const uint8_t *buf, size_t n) {
    uint8_t a[9] = {HANDLE};
    put64(a + 1, off);
    return call(0x22, a, 9, buf, n, 3000);
}

int close(bool abandon) {
    uint8_t a[2] = {HANDLE, 1};
    return call(0x23, a, abandon ? 2 : 1, nullptr, 0, 5000);   // a completing CLOSE also moves an upload into place
}
int remove(const String &path) { return pathCall(0x30, path, 5000); }

// Requests whose payload is two paths: the first, a NUL, the second. (Arduino String silently drops an appended
// '\0', so build the bytes directly.)
static int twoPathCall(uint8_t cmd, const String &from, const String &to, uint32_t timeoutMs) {
    uint8_t a[512];
    size_t nf = from.length(), nt = to.length();
    if (nf + 1 + nt > sizeof a) return BAD_REQUEST;
    memcpy(a, from.c_str(), nf);
    a[nf] = 0;
    memcpy(a + nf + 1, to.c_str(), nt);
    return call(cmd, a, nf + 1 + nt, nullptr, 0, timeoutMs);
}

int rename(const String &from, const String &to) { return twoPathCall(0x31, from, to, 5000); }

int mkdir(const String &path) { return pathCall(0x32, path, 5000); }

int copyStart(const String &from, const String &to, uint64_t &total) {
    int s = twoPathCall(0x33, from, to, 30000);                      // reserving the destination scans the FAT
    if (s == OK && respLen() >= 8) total = get64(resp());
    return s;
}

int copyReplace(const String &from, const String &to, const String &backup, uint64_t &total) {
    // source, NUL, target, NUL, backup: the third field lets the target exist (see the protocol doc)
    uint8_t a[768];
    size_t nf = from.length(), nt = to.length(), nb = backup.length();
    if (nf + nt + nb + 2 > sizeof a) return BAD_REQUEST;
    memcpy(a, from.c_str(), nf);
    a[nf] = 0;
    memcpy(a + nf + 1, to.c_str(), nt);
    a[nf + 1 + nt] = 0;
    memcpy(a + nf + nt + 2, backup.c_str(), nb);
    int s = call(0x33, a, nf + nt + nb + 2, nullptr, 0, 30000);
    if (s == OK && respLen() >= 8) total = get64(resp());
    return s;
}

int copyStep(uint64_t &copied, uint64_t &total) {
    int s = call(0x34, nullptr, 0, nullptr, 0, 10000);
    if (s == OK && respLen() >= 16) { copied = get64(resp()); total = get64(resp() + 8); }
    return s;
}
int mountNextSet(const String &path) { return pathCall(0x40, path, 5000); }

int mountNextGet(String &path) {
    int s = call(0x41, nullptr, 0, nullptr, 0, 2000);
    if (s == OK) { char tmp[256]; size_t n = respLen() < 255 ? respLen() : 255; memcpy(tmp, resp(), n); tmp[n] = 0; path = tmp; }
    return s;
}

}  // namespace sdlink
