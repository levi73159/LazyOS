pub const Bootloader = enum(u8) {
    bios = 0, // not supported yet
    uefi = 1,
};

pub const PixelFormat = enum(u8) {
    argb,
    rgba,
    abgr,
    bgra,
};

pub const MmapEntry = extern struct {
    ptr: u64,
    size: u64,
};

magic: [4]u8 = [_]u8{ 'L', 'a', 'z', 'y' },
size: u32 = 96,
bootloader_type: Bootloader = .uefi,
__unused: [3]u8 = undefined,
framebuffer: ?u64 = null,
fb_width: u32 = 0,
fb_height: u32 = 0,
fb_scanline_bytes: ?u32 = null,
fb_pixel_format: PixelFormat = .rgba,
__reserved: [31]u8 = undefined,
acpi_ptr: ?u64 = null,
__reserved2: [24]u8 = undefined,
mmap: [1]MmapEntry = undefined,

