#include "usb.h"
#include "util.h"

int main(void) {
    log_str("usb_fw: start\n");
    usb_host_init();
    for (uint32_t n = 0;; n++) {
        usb_host_poll();
        DBG_WORD = n;
    }
}
