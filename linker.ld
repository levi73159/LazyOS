ENTRY(boot_init)
PHDRS
{
    limine_requests PT_LOAD;
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
    debug PT_LOAD;
}
VIRT_START = 0xffffffff80000000;
SECTIONS
{
    . = VIRT_START;
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine_requests
    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .text : {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    } :text
    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .rodata : {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    } :rodata
    .note.gnu.build-id : {
        *(.note.gnu.build-id)
    } :rodata
    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    } :data
    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    /* Debug sections — PT_NULL so bootloader doesn't try to load them */
    .debug_info : {
        __debug_info_start = .;
        *(.debug_info)
        __debug_info_end = .;
    } :debug
    .debug_addr : {
        __debug_addr_start = .;
        *(.debug_addr)
        __debug_addr_end = .;
    } :debug
    .debug_abbrev : {
        __debug_abbrev_start = .;
        *(.debug_abbrev)
        __debug_abbrev_end = .;
    } :debug
    .debug_str : {
        __debug_str_start = .;
        *(.debug_str)
        __debug_str_end = .;
    } :debug
    .debug_line : {
        __debug_line_start = .;
        *(.debug_line)
        __debug_line_end = .;
    } :debug
    .debug_ranges : {
        __debug_ranges_start = .;
        *(.debug_ranges)
        __debug_ranges_end = .;
    } :debug
    .debug_aranges : {
        __debug_aranges_start = .;
        *(.debug_aranges)
        __debug_aranges_end = .;
    } :debug
    .debug_line_str : {
        __debug_line_str_start = .;
        *(.debug_line_str)
        __debug_line_str_end = .;
    } :debug
    .debug_loclists : {
        __debug_loclists_start = .;
        *(.debug_loclists)
        __debug_loclists_end = .;
    } :debug
    .debug_rnglists : {
        __debug_rnglists_start = .;
        *(.debug_rnglists)
        __debug_rnglists_end = .;
    } :debug
    kernel_size = . - VIRT_START;


    /* discard everything else */
    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
    }
}
