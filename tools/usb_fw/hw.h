// MMIO map of usb_softcpu.sv and usb_sie.sv -- keep the three in step.
#pragma once
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(a))

// usb_softcpu
#define DBG_WORD     REG32(0x10000000)
#define TIMER_US     REG32(0x10000004)
#define SIM_CONSOLE  REG32(0x10000008)   // simulation only; ignored in hardware
#define KBD_LO       REG32(0x10000010)   // keys 0-3
#define KBD_HI       REG32(0x10000014)   // key 4, key 5, modifiers; writing emits the report
#define MOUSE_OUT    REG32(0x10000018)   // buttons, dx, dy; writing emits the report

// usb_sie, one block per root port
#define SIE_BASE(p)      (0x10001000u + ((uint32_t)(p) << 12))
#define SIE_CTRL(p)      REG32(SIE_BASE(p) + 0x00)
#define SIE_STATUS(p)    REG32(SIE_BASE(p) + 0x04)
#define SIE_CMD(p)       REG32(SIE_BASE(p) + 0x08)
#define SIE_RESULT(p)    REG32(SIE_BASE(p) + 0x0C)
#define SIE_TXBUF(p, i)  REG32(SIE_BASE(p) + 0x40 + 4 * (i))
#define SIE_RXBUF(p, i)  REG32(SIE_BASE(p) + 0x80 + 4 * (i))

#define CTRL_SOF_EN      0x1
#define CTRL_BUS_RESET   0x2
#define CTRL_PORT_LS     0x4

#define STAT_ATTACHED    0x1
#define STAT_ATTACHED_FS 0x2
#define STAT_BUSY        0x4

// RESULT status codes
enum { R_NONE, R_ACK, R_NAK, R_STALL, R_DATA, R_TIMEOUT, R_CRC, R_PID, R_BABBLE };

#define NUM_PORTS 2
