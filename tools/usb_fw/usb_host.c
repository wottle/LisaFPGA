// USB host: root ports, enumeration, HID boot keyboards and mice, hubs, report output.
// See docs/usb_softcpu_host_design.md.
#include "usb.h"
#include "util.h"

#define PID_IN    0x69
#define PID_DATA0 0xC3
#define PID_DATA1 0x4B

usb_dev_t devs[MAX_DEVS];

// ---- interrupt endpoints being polled ----
enum { EP_KBD = 1, EP_MOUSE, EP_HUB };
typedef struct {
    uint8_t  used, dev, ep, kind, toggle, interval_ms;
    uint32_t last_us;
    uint8_t  report[8];      // keyboards: last accepted boot report
} ep_t;
static ep_t eps[MAX_EPS];

static void log_dev(const usb_dev_t *d) {
    log_str("[p"); log_dec(d->port);
    if (d->parent) { log_str(" hub"); log_dec(devs[d->parent - 1].addr); log_str("."); log_dec(d->hub_port); }
    log_str(" a"); log_dec(d->addr); log_str("] ");
}

// ===================================================================================================
// Report output
// ===================================================================================================
static uint8_t kbd_out[8];

// Keyboards are merged: modifiers OR'd, keycodes collected (up to six) from every keyboard interface, so
// two keyboards -- or a receiver that exposes two keyboard interfaces -- cannot release each other's keys.
static void kbd_update(void) {
    uint8_t m[8] = {0};
    int n = 2;
    for (int i = 0; i < MAX_EPS; i++) {
        if (!eps[i].used || eps[i].kind != EP_KBD) continue;
        m[0] |= eps[i].report[0];
        for (int k = 2; k < 8 && n < 8; k++) {
            uint8_t c = eps[i].report[k];
            int dup = 0;
            if (c < 4) continue;
            for (int j = 2; j < n; j++) dup |= m[j] == c;
            if (!dup) m[n++] = c;
        }
    }
    int same = 1;
    for (int k = 0; k < 8; k++) same &= m[k] == kbd_out[k];
    if (same) return;
    memcpy(kbd_out, m, 8);
    KBD_LO = m[2] | (uint32_t)m[3] << 8 | (uint32_t)m[4] << 16 | (uint32_t)m[5] << 24;
    KBD_HI = m[6] | (uint32_t)m[7] << 8 | (uint32_t)m[0] << 16;
}

static void mouse_out(uint8_t btn, uint8_t dx, uint8_t dy) {
    MOUSE_OUT = (btn & 7) | (uint32_t)dx << 8 | (uint32_t)dy << 16;
}

// ===================================================================================================
// Device bookkeeping
// ===================================================================================================
static int alloc_addr(void) {
    for (int a = 1; a < 128; a++) {
        int used = 0;
        for (int i = 0; i < MAX_DEVS; i++) used |= devs[i].used && devs[i].addr == a;
        if (!used) return a;
    }
    return -1;
}

static void dev_remove(int idx) {
    usb_dev_t *d = &devs[idx];
    if (!d->used) return;
    for (int i = 0; i < MAX_DEVS; i++)                    // children first
        if (devs[i].used && devs[i].parent == idx + 1) dev_remove(i);
    log_dev(d); log_str("removed\n");
    int kbd = 0;
    for (int i = 0; i < MAX_EPS; i++) {
        if (!eps[i].used || eps[i].dev != idx) continue;
        if (eps[i].kind == EP_KBD) kbd = 1;
        if (eps[i].kind == EP_MOUSE) mouse_out(0, 0, 0);  // release any held buttons
        eps[i].used = 0;
    }
    if (kbd) kbd_update();                                // releases its keys
    d->used = 0;
}

static void ep_add(int dev, int ep, int kind, int interval) {
    for (int i = 0; i < MAX_EPS; i++) {
        if (eps[i].used) continue;
        memset(&eps[i], 0, sizeof eps[i]);
        eps[i].used = 1; eps[i].dev = dev; eps[i].ep = ep; eps[i].kind = kind;
        eps[i].interval_ms = interval < 1 ? 1 : interval;
        eps[i].last_us = now_us();
        return;
    }
    log_str("endpoint table full\n");
}

// ===================================================================================================
// Requests
// ===================================================================================================
static int req(const usb_dev_t *d, uint8_t type, uint8_t request, uint16_t value, uint16_t index,
               uint8_t *data, int len) {
    uint8_t s[8] = { type, request, value & 0xFF, value >> 8, index & 0xFF, index >> 8, len & 0xFF, len >> 8 };
    int n = len;
    int r = usb_control(d, s, data, &n);
    return r < 0 ? r : n;
}

static int get_descriptor(const usb_dev_t *d, uint8_t type, uint8_t idx, uint8_t *buf, int len) {
    return req(d, 0x80, 6, (uint16_t)type << 8 | idx, 0, buf, len);
}

// ===================================================================================================
// HID: decide what an interface is from its report descriptor, not its class codes. The Keychron
// receiver's interface 1 claims to be a boot keyboard but is a barcode reader and game controller.
// ===================================================================================================
enum { HID_KBD = 1, HID_MOUSE = 2 };

static int hid_classify(const uint8_t *r, int n) {
    uint32_t page = 0, usage = 0;
    int have_usage = 0, depth = 0, found = 0;
    for (int i = 0; i < n;) {
        uint8_t b = r[i];
        if (b == 0xFE) { i += 3 + (i + 1 < n ? r[i + 1] : 0); continue; }   // long item
        int size = b & 3;
        if (size == 3) size = 4;
        uint32_t data = 0;
        for (int k = 0; k < size && i + 1 + k < n; k++) data |= (uint32_t)r[i + 1 + k] << (8 * k);
        uint8_t tag = b & 0xFC;
        i += 1 + size;
        switch (tag) {
        case 0x04: page = data; break;                                      // Usage Page
        case 0x08:                                                          // Usage
            if (!have_usage) { usage = data; have_usage = 1; }
            break;
        case 0xA0:                                                          // Collection
            if (data == 1 && depth == 0) {                                  // top-level Application
                uint32_t up = size == 4 ? usage >> 16 : page, u = usage & 0xFFFF;
                if (up == 1 && u == 6) found |= HID_KBD;
                if (up == 1 && u == 2) found |= HID_MOUSE;
            }
            depth++;
            have_usage = 0;
            break;
        case 0xC0: if (depth) depth--; have_usage = 0; break;               // End Collection
        case 0x80: case 0x90: case 0xB0: have_usage = 0; break;             // Input/Output/Feature
        default: break;
        }
    }
    return found;
}

// ===================================================================================================
// Enumeration
// ===================================================================================================
static uint8_t buf[512];
static void hub_init(int idx, int ep, int interval);

typedef struct { uint8_t num, cls, sub, proto, ep, interval; uint16_t rlen; } iface_t;

// Enumerate the device just reset on (port, parent hub, hub port). Returns its index or -1.
static int enumerate(int port, int parent, int hub_port, int ls, int pre) {
    int idx = -1, addr = alloc_addr(), r;
    for (int i = 0; i < MAX_DEVS; i++) if (!devs[i].used) { idx = i; break; }
    if (idx < 0 || addr < 0) { log_str("device table full\n"); return -1; }
    usb_dev_t *d = &devs[idx];
    memset(d, 0, sizeof *d);
    d->port = port; d->ls = ls; d->pre = pre; d->parent = parent; d->hub_port = hub_port;
    d->addr = 0; d->mps0 = 8;

    if ((r = get_descriptor(d, 1, 0, buf, 8)) < 8) goto fail;
    d->mps0 = buf[7];
    if (d->mps0 != 8 && d->mps0 != 16 && d->mps0 != 32 && d->mps0 != 64) d->mps0 = 8;
    if ((r = req(d, 0x00, 5, addr, 0, 0, 0)) < 0) goto fail;               // SET_ADDRESS
    delay_ms(2);
    d->addr = addr;
    d->used = 1;
    if ((r = get_descriptor(d, 1, 0, buf, 18)) < 18) goto fail;
    log_dev(d); log_str(ls ? "low" : "full"); log_str(" speed ");
    log_hex(buf[9] << 8 | buf[8], 4); log_str(":"); log_hex(buf[11] << 8 | buf[10], 4); log_str("\n");
    d->is_hub = buf[4] == 9;

    if ((r = get_descriptor(d, 2, 0, buf, 9)) < 9) goto fail;
    int total = buf[2] | buf[3] << 8;
    if (total > (int)sizeof buf) total = sizeof buf;
    if ((r = get_descriptor(d, 2, 0, buf, total)) < total) goto fail;
    uint8_t cfg = buf[5];

    // collect the interfaces worth looking at: HID boot interfaces and hubs, with their interrupt IN
    iface_t ifs[6];
    int nif = 0, cur = -1;                                                  // cur: interface being read, if kept
    for (int i = 0; i + 1 < total && buf[i] >= 2; i += buf[i]) {
        const uint8_t *p = &buf[i];
        if (p[1] == 4 && nif < 6) {                                         // interface
            ifs[nif].num = p[2]; ifs[nif].cls = p[5]; ifs[nif].sub = p[6]; ifs[nif].proto = p[7];
            ifs[nif].ep = 0; ifs[nif].rlen = 0;
            cur = (p[3] == 0 && (p[5] == 3 || p[5] == 9)) ? nif++ : -1;     // alt setting 0 only
        } else if (p[1] == 4) {
            cur = -1;
        } else if (p[1] == 0x21 && cur >= 0 && ifs[cur].cls == 3) {         // HID descriptor
            ifs[cur].rlen = p[7] | p[8] << 8;
        } else if (p[1] == 5 && cur >= 0 && !ifs[cur].ep && (p[2] & 0x80) && (p[3] & 3) == 3) {
            ifs[cur].ep = p[2] & 15;                                         // first interrupt IN
            ifs[cur].interval = p[6];
        }
    }

    if ((r = req(d, 0x00, 9, cfg, 0, 0, 0)) < 0) goto fail;                 // SET_CONFIGURATION

    for (int k = 0; k < nif; k++) {
        iface_t *f = &ifs[k];
        if (!f->ep) continue;
        if (f->cls == 9) { hub_init(idx, f->ep, f->interval); continue; }
        if (f->sub != 1) continue;                                          // boot interfaces only
        int len = f->rlen > sizeof buf ? (int)sizeof buf : f->rlen;
        int kind = 0;
        if (len && req(d, 0x81, 6, 0x2200, f->num, buf, len) > 0) {
            int c = hid_classify(buf, len);
            kind = (c & HID_KBD) ? EP_KBD : (c & HID_MOUSE) ? EP_MOUSE : 0;
        } else                                                              // no report descriptor: trust the boot protocol code
            kind = f->proto == 1 ? EP_KBD : f->proto == 2 ? EP_MOUSE : 0;
        log_dev(d); log_str("interface "); log_dec(f->num);
        if (!kind) { log_str(": not a keyboard or mouse, ignored\n"); continue; }
        log_str(kind == EP_KBD ? ": keyboard" : ": mouse"); log_str(", EP"); log_dec(f->ep); log_str("\n");
        req(d, 0x21, 0x0B, 0, f->num, 0, 0);                                // SET_PROTOCOL(boot)
        req(d, 0x21, 0x0A, 0, f->num, 0, 0);                                // SET_IDLE(0); may STALL, harmless
        ep_add(idx, f->ep, kind, ls ? (f->interval < 10 ? 10 : f->interval) : f->interval);
    }
    return idx;

fail:
    log_str("[p"); log_dec(port); log_str("] enumeration failed, status "); log_dec(-r); log_str("\n");
    if (d->used) dev_remove(idx);
    d->used = 0;
    return -1;
}

// ===================================================================================================
// Hubs
// ===================================================================================================
#define HUB_PORT_POWER   8
#define HUB_PORT_RESET   4
#define C_PORT_CONNECTION 16

static void hub_init(int idx, int ep, int interval) {
    usb_dev_t *h = &devs[idx];
    int r = req(h, 0xA0, 6, 0x2900, 0, buf, 9);
    if (r < 7) { log_dev(h); log_str("hub descriptor failed\n"); return; }
    h->hub_ports = buf[2];
    int pwr_ms = buf[5] * 2;
    log_dev(h); log_str("hub, "); log_dec(h->hub_ports); log_str(" ports\n");
    for (int p = 1; p <= h->hub_ports; p++) req(h, 0x23, 3, HUB_PORT_POWER, p, 0, 0);
    delay_ms(pwr_ms + 20);
    // the status endpoint can be as slow as 255 ms (Apple's older hub); poll it faster than that
    ep_add(idx, ep, EP_HUB, interval > 32 ? 32 : interval);
}

static int hub_port_status(usb_dev_t *h, int p, uint16_t *status, uint16_t *change) {
    uint8_t s[4];
    if (req(h, 0xA3, 0, 0, p, s, 4) < 4) return -1;
    *status = s[0] | s[1] << 8;
    *change = s[2] | s[3] << 8;
    return 0;
}

static void hub_port_changed(int idx, int p) {
    usb_dev_t *h = &devs[idx];
    uint16_t st, ch;
    if (hub_port_status(h, p, &st, &ch) < 0) return;
    for (int b = 0; b < 5; b++)                                             // acknowledge every change bit
        if (ch & (1 << b)) req(h, 0x23, 1, C_PORT_CONNECTION + b, p, 0, 0);
    if (!(ch & 1)) return;

    for (int i = 0; i < MAX_DEVS; i++)                                      // whatever was there is gone
        if (devs[i].used && devs[i].parent == idx + 1 && devs[i].hub_port == p) dev_remove(i);
    if (!(st & 1)) return;

    delay_ms(100);                                                          // attach debounce
    req(h, 0x23, 3, HUB_PORT_RESET, p, 0, 0);
    uint32_t t0 = now_us();
    do {
        delay_ms(10);
        if (hub_port_status(h, p, &st, &ch) < 0) return;
    } while (!(ch & 0x10) && now_us() - t0 < 500000u);                      // wait for C_PORT_RESET
    req(h, 0x23, 1, C_PORT_CONNECTION + 4, p, 0, 0);
    if (!(st & 2)) { log_dev(h); log_str("port "); log_dec(p); log_str(" did not enable\n"); return; }
    delay_ms(10);                                                           // reset recovery
    int ls = (st >> 9) & 1;
    enumerate(h->port, idx + 1, p, ls, ls);
}

// ===================================================================================================
// Interrupt endpoint polling
// ===================================================================================================
static void poll_ep(int i) {
    ep_t *e = &eps[i];
    usb_dev_t *d = &devs[e->dev];
    uint32_t r = sie_xfer(d, PID_IN, e->ep, e->toggle, 0, 0);
    int st = r & 15, n = (r >> 8) & 0x7F;
    uint8_t rx[8] = {0};

    if (st == R_STALL) {                                                    // CLEAR_FEATURE(ENDPOINT_HALT)
        req(d, 0x02, 1, 0, 0x80 | e->ep, 0, 0);
        e->toggle = 0;
        return;
    }
    if (st != R_DATA) return;
    if (((r >> 16) & 0xFF) != (e->toggle ? PID_DATA1 : PID_DATA0)) return;  // a retransmission: drop it
    e->toggle ^= 1;
    sie_read(d->port, rx, n < 8 ? n : 8);

    switch (e->kind) {
    case EP_KBD:
        // Boot reports are exactly 8 bytes. Shorter ones are other collections sharing the endpoint
        // (the Keychron's consumer/system keys); ErrorRollOver (0x01 in every slot) is not a key state.
        if (n != 8 || rx[2] == 0x01) return;
        memcpy(e->report, rx, 8);
        kbd_update();
        break;
    case EP_MOUSE:
        if (n >= 3) mouse_out(rx[0], rx[1], rx[2]);
        break;
    case EP_HUB:
        for (int p = 1; p <= d->hub_ports && p < 8; p++)
            if (rx[0] & (1 << p)) hub_port_changed(e->dev, p);
        break;
    }
}

// ===================================================================================================
// Root ports
// ===================================================================================================
enum { P_EMPTY, P_DEBOUNCE, P_RESET, P_RECOVER, P_RUN, P_FAILED };
static struct { uint8_t state, fs; uint32_t t0; } ports[NUM_PORTS];

static void root_teardown(int p) {
    for (int i = 0; i < MAX_DEVS; i++)
        if (devs[i].used && devs[i].port == p && !devs[i].parent) dev_remove(i);
}

static void root_poll(int p) {
    uint32_t st = SIE_STATUS(p), t = now_us() - ports[p].t0;
    int attached = st & STAT_ATTACHED;

    switch (ports[p].state) {
    case P_EMPTY:
        if (attached) { ports[p].state = P_DEBOUNCE; ports[p].t0 = now_us(); }
        break;
    case P_DEBOUNCE:                                                        // 100 ms of steady attach
        if (!attached) ports[p].state = P_EMPTY;
        else if (t > 100000u) {
            ports[p].fs = (st & STAT_ATTACHED_FS) != 0;
            SIE_CTRL(p) = CTRL_BUS_RESET | (ports[p].fs ? 0 : CTRL_PORT_LS);
            ports[p].state = P_RESET; ports[p].t0 = now_us();
        }
        break;
    case P_RESET:                                                           // root ports reset for 50 ms
        if (t > 50000u) {
            SIE_CTRL(p) = CTRL_SOF_EN | (ports[p].fs ? 0 : CTRL_PORT_LS);
            ports[p].state = P_RECOVER; ports[p].t0 = now_us();
        }
        break;
    case P_RECOVER:
        if (t > 20000u) {
            log_str("[p"); log_dec(p); log_str("] attached, "); log_str(ports[p].fs ? "full" : "low");
            log_str(" speed\n");
            ports[p].state = enumerate(p, 0, 0, !ports[p].fs, 0) >= 0 ? P_RUN : P_FAILED;
            ports[p].t0 = now_us();
        }
        break;
    case P_RUN:
    case P_FAILED:
        if (!attached) {
            log_str("[p"); log_dec(p); log_str("] detached\n");
            root_teardown(p);
            SIE_CTRL(p) = 0;
            ports[p].state = P_EMPTY;
        } else if (ports[p].state == P_FAILED && t > 2000000u) {           // retry every 2 s
            root_teardown(p);
            ports[p].state = P_DEBOUNCE; ports[p].t0 = now_us() - 100000u;
        }
        break;
    }
}

void usb_host_init(void) {
    memset(devs, 0, sizeof devs);
    memset(eps, 0, sizeof eps);
    memset(ports, 0, sizeof ports);
    for (int p = 0; p < NUM_PORTS; p++) SIE_CTRL(p) = 0;
}

void usb_host_poll(void) {
    for (int p = 0; p < NUM_PORTS; p++) root_poll(p);
    for (int i = 0; i < MAX_EPS; i++) {
        if (!eps[i].used) continue;
        if (now_us() - eps[i].last_us < eps[i].interval_ms * 1000u) continue;
        eps[i].last_us = now_us();
        poll_ep(i);
    }
}
