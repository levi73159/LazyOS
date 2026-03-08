pub const HEADER_MAGIC = 0x1BADB002;
pub const MemoryMapEntry = @import("limine.zig").MemmapEntry;

var boot_info: BootInfo = undefined;

pub const BootInfo = struct {
    framebuffer: Framebuffer,
    memory_map: []*MemoryMapEntry,
    hhdm_offset: u64,
    kernel: KernelInfo,

    pub fn getFramebuffer(self: BootInfo, comptime T: type) []T {
        if (self.framebuffer.bpp != @typeInfo(T).int.bits) @panic("Framebuffer pixel size mismatch");

        const addr: usize = @intCast(self.framebuffer.address);
        const ptr: [*]u8 = @ptrFromInt(addr);
        const slice = ptr[0 .. self.framebuffer.pitch * self.framebuffer.height];
        return @ptrCast(@alignCast(slice));
    }
};

pub fn registerBootInfo(info: BootInfo) *const BootInfo {
    boot_info = info;
    return &boot_info;
}

pub inline fn getBootInfo() *const BootInfo {
    return &boot_info;
}

pub const Framebuffer = struct {
    address: u64,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
};

pub const KernelInfo = struct {
    phys_addr: u64,
    virt_addr: u64,
    size: u64,
};

pub inline fn toVirtualHHDM(phys: u64) u64 {
    return phys + getBootInfo().hhdm_offset;
}

pub inline fn toPhysicalHHDM(virt: u64) u64 {
    return virt - getBootInfo().hhdm_offset;
}

pub inline fn kernelToPhysical(virt: u64) u64 {
    const info = getBootInfo();
    return virt - info.kernel.virt_addr + info.kernel.phys_addr;
}
