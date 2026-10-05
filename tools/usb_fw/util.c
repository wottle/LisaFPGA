#include "util.h"

void *memset(void *d, int c, size_t n) {
    uint8_t *p = d;
    while (n--) *p++ = (uint8_t)c;
    return d;
}

void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *p = d;
    const uint8_t *q = s;
    while (n--) *p++ = *q++;
    return d;
}

void delay_us(uint32_t us) {
    uint32_t t0 = now_us();
    while (now_us() - t0 < us) ;
}

void log_str(const char *s) { while (*s) SIM_CONSOLE = (uint8_t)*s++; }

void log_hex(uint32_t v, int digits) {
    while (digits--) SIM_CONSOLE = "0123456789abcdef"[(v >> (4 * digits)) & 15];
}

void log_dec(uint32_t v) {
    char b[11];
    int i = 0;
    do { b[i++] = '0' + v % 10; v /= 10; } while (v);
    while (i--) SIM_CONSOLE = b[i];
}
