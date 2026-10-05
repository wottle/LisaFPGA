/* 32 KB RAM at 0, code and data together. The top 2 KB is left for the stack. */
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 30K }
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss  : { . = ALIGN(4); __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
}
