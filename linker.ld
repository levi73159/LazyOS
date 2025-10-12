ENTRY(__kernel_entry)

/* Changes to KERNEL_ADDR_OFFSET must also be made to KERNEL_PAGE_NUMBER in boot.zig */
KERNEL_PHYS_START = 1M;
KERNEL_VIRT_START = 1M; /* identical kernel virtual address */

fb = 0xFFFFFFFFdeadbeef;
bootinfo = 0xFFFFFFFFcafebabe;

SECTIONS {
	. = 1M;

	.text : ALIGN(4K) {
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
		*(.kernel_heap)
	}

	.bss.stack : ALIGN(4K) {
		KEEP(*(.bss.stack))
	}

	KERNEL_PHYS_END = .;
}
