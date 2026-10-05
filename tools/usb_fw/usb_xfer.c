// Transactions and control transfers over usb_sie.
#include "usb.h"
#include "util.h"

#define PID_SETUP 0x2D
#define PID_IN    0x69
#define PID_OUT   0xE1
#define PID_DATA0 0xC3
#define PID_DATA1 0x4B

#define CTRL_TIMEOUT_US 500000u   // a control transfer that keeps NAKing for this long has failed
#define MAX_ERRORS      3         // TIMEOUT / CRC / PID errors tolerated per stage

uint32_t sie_xfer(const usb_dev_t *d, uint8_t pid, uint8_t ep, int data1, const uint8_t *out, int len) {
    int p = d->port;
    for (int i = 0; i < len; i += 4) {
        uint32_t w = 0;
        for (int k = 0; k < 4 && i + k < len; k++) w |= (uint32_t)out[i + k] << (8 * k);
        SIE_TXBUF(p, i >> 2) = w;
    }
    SIE_CMD(p) = pid | (uint32_t)d->addr << 8 | (uint32_t)(ep & 15) << 15 | (uint32_t)(data1 & 1) << 19 |
                 (uint32_t)(d->ls & 1) << 20 | (uint32_t)(d->pre & 1) << 21 | (uint32_t)len << 24;
    while (SIE_STATUS(p) & STAT_BUSY) ;
    return SIE_RESULT(p);
}

void sie_read(int port, uint8_t *buf, int n) {
    for (int i = 0; i < n; i += 4) {
        uint32_t w = SIE_RXBUF(port, i >> 2);
        for (int k = 0; k < 4 && i + k < n; k++) buf[i + k] = (uint8_t)(w >> (8 * k));
    }
}

// Retry a transaction through NAKs (until the deadline) and transient errors (MAX_ERRORS times).
// Returns the final RESULT word; status is ACK / DATA on success.
static uint32_t xfer_retry(const usb_dev_t *d, uint8_t pid, int data1, const uint8_t *out, int len,
                           uint32_t t0) {
    int errors = 0;
    for (;;) {
        uint32_t r = sie_xfer(d, pid, 0, data1, out, len);
        switch (r & 15) {
        case R_ACK: case R_DATA: case R_STALL:
            return r;
        case R_NAK:
            if (now_us() - t0 > CTRL_TIMEOUT_US) return r;
            break;
        default:
            if (++errors >= MAX_ERRORS) return r;
            break;
        }
    }
}

int usb_control(const usb_dev_t *d, const uint8_t setup[8], uint8_t *data, int *len) {
    uint32_t t0 = now_us(), r;
    int wlen = setup[6] | setup[7] << 8;
    int in = setup[0] & 0x80;
    int got = 0, toggle = 1;

    r = xfer_retry(d, PID_SETUP, 0, setup, 8, t0);
    if ((r & 15) != R_ACK) return -(int)(r & 15);

    if (wlen && in) {                               // data stage, IN
        int cap = *len < wlen ? *len : wlen;
        while (got < wlen) {
            int n;
            r = xfer_retry(d, PID_IN, toggle, 0, 0, t0);
            if ((r & 15) != R_DATA) return -(int)(r & 15);
            if (((r >> 16) & 0xFF) != (toggle ? PID_DATA1 : PID_DATA0)) {   // a duplicate: drop it
                if (now_us() - t0 > CTRL_TIMEOUT_US) return -R_PID;
                continue;
            }
            n = (r >> 8) & 0x7F;
            if (got < cap) {
                uint8_t tmp[64];
                sie_read(d->port, tmp, n);
                memcpy(data + got, tmp, (got + n > cap) ? (size_t)(cap - got) : (size_t)n);
            }
            got += n;
            toggle ^= 1;
            if (n < d->mps0) break;                 // short packet ends the stage
        }
        if (got > cap) got = cap;
        r = xfer_retry(d, PID_OUT, 1, 0, 0, t0);    // status stage: zero-length OUT
        if ((r & 15) != R_ACK) return -(int)(r & 15);
    } else {
        if (wlen) {                                 // data stage, OUT
            for (int off = 0; off < wlen; off += d->mps0) {
                int n = wlen - off < d->mps0 ? wlen - off : d->mps0;
                r = xfer_retry(d, PID_OUT, toggle, data + off, n, t0);
                if ((r & 15) != R_ACK) return -(int)(r & 15);
                toggle ^= 1;
            }
        }
        do {                                        // status stage: zero-length IN, DATA1
            r = xfer_retry(d, PID_IN, 1, 0, 0, t0);
            if ((r & 15) != R_DATA) return -(int)(r & 15);
        } while (((r >> 16) & 0xFF) != PID_DATA1);
    }
    *len = got;
    return 0;
}
