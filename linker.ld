ENTRY(__kernel_start)

SECTIONS {
    . = 1M;
    KERNEL_START_ADDR = .;

    .text : ALIGN(4K) {
        /* We need to specify KEEP to prevent the linker from garbage-collecting the multiboot section. */
        KEEP(*(.multiboot))
        *(.text)
    }
 
    .rodata : ALIGN(4K) {
        *(.rodata)
    }
 
    .data : ALIGN(4K) {
        *(.data)
    }
 
    .bss : ALIGN(4K) {
        *(COMMON)
        *(.bss)
    }

    KERNEL_END_ADDR = .;
}
