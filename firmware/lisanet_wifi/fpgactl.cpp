// fpgactl -- see fpgactl.h. Written with an AI assistant.
#include "fpgactl.h"
#include "sdlink.h"

namespace fpgactl {

static uint8_t seq = 0;
static uint8_t resp[32];
static size_t respLen = 0;      // payload length of the last reply (status byte first)
static uint8_t raw[64];         // every byte received during the last call's reply windows, for AT+FPGA
static size_t rawLen = 0;
static uint8_t lastSent[24];
static size_t lastSentLen = 0;

const char *statusName(int s) {
    switch (s) {
        case OK:          return "OK";
        case BAD_REQUEST: return "BAD_REQUEST";
        case LOCKED:      return "LOCKED";
        case BUSY:        return "BUSY";
        case UNKNOWN_CMD: return "UNKNOWN_CMD";
        default:          return "NO_REPLY (FPGA without the control channel, or no WiFi board link)";
    }
}

static const uint8_t MARK[4] = {0xC3, 0x3C, 0x96, 0x69};

// One request and its reply. The SD servers skip everything that is not their own A5 5A frame, so a control frame
// must never contain A5: seq is chosen to keep it out of the header and the CRC.
static int call(uint8_t cmd, const uint8_t *pay, uint8_t len, int attempts) {
    HardwareSerial *port = sdlink::linkPort();
    if (!port) return NO_REPLY;
    uint8_t frame[4 + 3 + 8 + 4];
    size_t n = 0;
    for (;;) {
        seq++;
        uint8_t hdr[3] = {cmd, seq, len};
        uint32_t c = sdlink::crc32Update(0xFFFFFFFFu, hdr, 3);
        c = sdlink::crc32Update(c, pay, len) ^ 0xFFFFFFFFu;
        n = 0;
        memcpy(frame, MARK, 4); n = 4;
        memcpy(frame + n, hdr, 3); n += 3;
        memcpy(frame + n, pay, len); n += len;
        for (int i = 0; i < 4; i++) frame[n++] = c >> (8 * i);
        bool clean = true;
        for (size_t i = 4; i < n; i++) if (frame[i] == 0xA5) clean = false;
        if (clean) break;                                   // otherwise try the next seq
    }
    rawLen = 0;
    memcpy(lastSent, frame, n); lastSentLen = n;
    for (int attempt = 0; attempt < attempts; attempt++) {
        while (port->available()) port->read();
        port->write(frame, n);
        // Reply: marker, cmd|80, seq, len, payload, CRC. The FPGA may wait up to ~200 ms for a frame tick.
        uint8_t buf[4 + 3 + 32 + 4];
        size_t have = 0, need = 0;
        uint32_t start = millis();
        while (millis() - start < 400) {
            if (!port->available()) { delay(0); continue; }
            uint8_t b = port->read();
            if (rawLen < sizeof raw) raw[rawLen++] = b;
            if (have < 4) {                                 // hunting for the marker
                if (b == MARK[have]) buf[have++] = b;
                else have = (b == MARK[0]) ? 1 : 0;
                if (have == 1) buf[0] = b;
                continue;
            }
            buf[have++] = b;
            if (have == 7) {
                if (buf[6] > 32) { have = 0; continue; }
                need = 7 + buf[6] + 4;
            }
            if (have >= 7 && have == need) {
                uint8_t plen = buf[6];
                uint32_t c = sdlink::crc32Update(0xFFFFFFFFu, buf + 4, 3 + plen) ^ 0xFFFFFFFFu;
                uint32_t got = buf[7 + plen] | (uint32_t)buf[8 + plen] << 8 | (uint32_t)buf[9 + plen] << 16 |
                               (uint32_t)buf[10 + plen] << 24;
                if (c == got && buf[4] == (cmd | 0x80) && buf[5] == seq && plen >= 1) {
                    memcpy(resp, buf + 7, plen);
                    respLen = plen;
                    return resp[0];
                }
                have = 0;
            }
        }
    }
    return NO_REPLY;
}

static uint16_t rd16(const uint8_t *p) { return p[0] | (uint16_t)p[1] << 8; }

int status(Status &s) {
    int st = call(0x01, nullptr, 0, 3);
    if (st != OK) return st;
    if (respLen < 15) return BAD_REQUEST;
    const uint8_t *p = resp + 1;                            // version, then the FPGA's status block
    s.version   = p[0];
    s.videoMode = p[1];
    uint8_t f = p[2], g = p[3];
    s.contrast = f & 0x01;      s.lisaOn = f & 0x02;    s.boardPresent = f & 0x04;
    s.espMode = (f & 0x08) ? ((f & 0x10) ? 2 : 1) : 0;
    s.saved = f & 0x20;         s.saving = f & 0x40;    s.speedUserSet = f & 0x80;
    s.speedIdx = g & 0x03;      s.has1024 = g & 0x04;   s.modeUserSet = g & 0x08;
    s.rom3A = g & 0x10;         s.contrastJumper = g & 0x20;
    s.hOff = rd16(p + 4); s.hLim = rd16(p + 6); s.vOff = rd16(p + 8); s.vLim = rd16(p + 10);
    s.tempC = (respLen >= 15) ? rd16(p + 12) * 503.975f / 65536.0f - 273.15f : NAN;
    s.hasMachine = respLen >= 17;                           // two more status bytes after the temperature
    uint8_t m = s.hasMachine ? p[14] : 0, r = s.hasMachine ? p[15] : 0;
    s.scanlines = m & 0x01;  s.scanlinesJumper = m & 0x02;  s.inverse = m & 0x04;  s.inverseJumper = m & 0x08;
    s.rom3ASwitch = m & 0x20;  s.twiggy = m & 0x40;  s.twiggySwitch = m & 0x80;  // m bit 4 is rom3A, as in g
    s.ram = r & 0x03;  s.ramSwitch = (r >> 2) & 0x03;  s.ramUserSet = r & 0x10;
    return OK;
}

int set(uint8_t reg, uint16_t value) {
    uint8_t p[3] = {reg, (uint8_t)value, (uint8_t)(value >> 8)};
    return call(0x02, p, 3, 3);                             // repeating a SET is harmless
}

const uint8_t *lastRaw(size_t &n) { n = rawLen; return raw; }
const uint8_t *lastFrame(size_t &n) { n = lastSentLen; return lastSent; }

int action(uint8_t a) {
    return call(0x03, &a, 1, 1);
}

}  // namespace fpgactl
