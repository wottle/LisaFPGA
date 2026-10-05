// USB host: transfers (usb_xfer.c) and device management (usb_host.c).
#pragma once
#include <stdint.h>

#define MAX_DEVS 8
#define MAX_EPS  8

typedef struct {
    uint8_t used;
    uint8_t port;        // root port
    uint8_t addr;
    uint8_t ls;          // low speed
    uint8_t pre;         // low speed behind a hub: every packet needs a PRE
    uint8_t mps0;        // EP0 max packet
    uint8_t parent;      // index + 1 of the hub it is on, 0 = root port
    uint8_t hub_port;
    uint8_t is_hub;
    uint8_t hub_ports;   // hubs only
} usb_dev_t;

extern usb_dev_t devs[MAX_DEVS];

// One transaction. For IN, the payload is in the port's RX buffer afterwards: see sie_read().
// Returns the RESULT word: [3:0] status, [14:8] rx length, [23:16] received PID.
uint32_t sie_xfer(const usb_dev_t *d, uint8_t pid, uint8_t ep, int data1, const uint8_t *out, int len);
void sie_read(int port, uint8_t *buf, int n);

// Control transfer on EP0. data is the IN buffer or OUT payload; *len is in: buffer size / OUT length,
// out: bytes received. Returns 0, or a negative R_* code.
int usb_control(const usb_dev_t *d, const uint8_t setup[8], uint8_t *data, int *len);

void usb_host_init(void);
void usb_host_poll(void);
