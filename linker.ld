/**
 * Kernel Linker Script
 */

/**
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2024-2025 Samuel Fiedler
 */

/* general variables */
KERNEL_PHYS_START = 1M;
KERNEL_STACK_SIZE = 0x4000;

/* entry point */
ENTRY(__zig_entry)

SECTIONS {
    . = KERNEL_PHYS_START;
    __kernel_start = .;

    /* dedicated start section so we can ensure that everything related to startup always lies at the correct address */
    .start : ALIGN(4K) {
        __kernel_boot_info = .;
        . += 8;
        KEEP(*(.start*));
    }
    .start = KERNEL_PHYS_START;

    /* program code */
    .text : ALIGN(4K) {
        *(.text*)
    }

    /* read-only data */
    .rodata : ALIGN(4K) {
        *(.rodata*)
    }

    /* readable and writable data */
    .data : ALIGN(4K) {
        *(.data*)
    }

    /* writable but uninitialized data */
    .bss : ALIGN(4K) {
        *(COMMON*)
        *(.bss*)

        . = ALIGN(16);
        __stack_bottom = .;
        . += KERNEL_STACK_SIZE;
        __stack_top = .;
    }

    __kernel_end = .;
}
