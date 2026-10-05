// MMIO map of usb_softcpu.sv -- keep the two in step.
#pragma once
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(a))
#define DBG_WORD   REG32(0x10000000)
#define TIMER_US   REG32(0x10000004)
#define SIM_CONSOLE REG32(0x10000008)
