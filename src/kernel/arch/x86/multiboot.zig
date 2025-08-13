pub const MultibootInfo = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    u: extern union {
        aout_sym: AOUTSymbolTable,
        elf_sec: ElfSectionHeaderTable,
    },

    mmap_length: u32,
    mmap_addr: u32,

    drives_length: u32,
    drives_addr: u32,

    config_table: u32,
    boot_loader_name: u32,
    apm_table: u32,

    // video
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,

    framebuffer_addr: u64,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: u8,

    framebuffer: extern union {
        palette: extern struct { palette_addr: u32, num_colors: u16 },
        rgb: extern struct {
            red_field_pos: u8,
            red_mask_size: u8,
            green_field_pos: u8,
            green_mask_size: u8,
            blue_field_pos: u8,
            blue_mask_size: u8,
        },
    },

    pub fn getMemoryMap(self: MultibootInfo) []MemoryMapEntry {
        const ptr: [*]MemoryMapEntry = @ptrFromInt(self.mmap_addr);
        const slice = ptr[0 .. self.mmap_length / @sizeOf(MemoryMapEntry)];
        return slice;
    }
};

pub const AOUTSymbolTable = extern struct {
    tabsize: u32,
    strsize: u32,
    addr: u32,
    reserved: u32,
};

pub const ElfSectionHeaderTable = extern struct {
    num: u32,
    size: u32,
    addr: u32,
    shndx: u32,
};

pub const MemoryType = enum(u32) {
    available = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    nvs = 4,
    bad_ram = 5,
};

pub const MemoryMapEntry = extern struct {
    size: u32 align(1),
    addr: u64 align(1),
    len: u64 align(1),
    type: MemoryType align(1),
};

pub const HEADER_MAGIC = 0x1BADB002;
