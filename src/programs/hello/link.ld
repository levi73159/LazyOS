/* src/programs/user.ld */
SECTIONS {
    . = 0x400000;

    .text : {
        *(.text.unlikely .text.*_unlikely .text.unlikely.*)
        *(.text.exit .text.exit.*)
        *(.text.startup .text.startup.*)
        *(.text.hot .text.hot.*)
        *(.text .stub .text.* .gnu.linkonce.t.*)
    }

    .rodata : {
        *(.rodata .rodata.* .gnu.linkonce.r.*)
    }

    .eh_frame_hdr : { *(.eh_frame_hdr) *(.eh_frame_entry .eh_frame_entry.*) }
    .eh_frame : { KEEP (*(.eh_frame)) }

    .data : {
        *(.data .data.* .gnu.linkonce.d.*)
    }

    .bss : {
        *(.dynbss)
        *(.bss .bss.* .gnu.linkonce.b.*)
        *(COMMON)
    }

    /* discard unwanted sections */
    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.gnu.version*)
    }
}
