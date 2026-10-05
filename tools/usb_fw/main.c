#include "hw.h"

static void puts_sim(const char *s) { while (*s) SIM_CONSOLE = (uint8_t)*s++; }

static void delay_us(uint32_t us) {
    uint32_t t0 = TIMER_US;
    while (TIMER_US - t0 < us) ;
}

int main(void) {
    puts_sim("usb_fw: hello\n");
    for (uint32_t n = 1;; n++) {
        DBG_WORD = n;
        delay_us(10);
        if (n == 3) puts_sim("usb_fw: timer ok\n");
    }
}
