#pragma once
#include <stdint.h>
#include <stddef.h>
#include "hw.h"

void *memset(void *d, int c, size_t n);
void *memcpy(void *d, const void *s, size_t n);

static inline uint32_t now_us(void) { return TIMER_US; }
void delay_us(uint32_t us);
#define delay_ms(ms) delay_us((ms) * 1000u)

// Logging: goes to the simulation console (and nowhere in hardware, for now)
void log_str(const char *s);
void log_hex(uint32_t v, int digits);
void log_dec(uint32_t v);
