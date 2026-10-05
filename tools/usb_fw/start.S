# Reset entry for the USB host firmware. PicoRV32 starts at 0 with sp already set (STACKADDR), but set it
# anyway so the firmware does not depend on that parameter.
    .section .text.start
    .global _start
_start:
    li   sp, 0x8000
    la   a0, __bss_start
    la   a1, __bss_end
1:  bgeu a0, a1, 2f
    sw   zero, 0(a0)
    addi a0, a0, 4
    j    1b
2:  call main
3:  j    3b
