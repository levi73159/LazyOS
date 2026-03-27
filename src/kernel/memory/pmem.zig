const std = @import("std");
const BitmapAllocator = @import("BitmapAllocator.zig");
const BootInfo = @import("../arch/bootinfo.zig").BootInfo;

pub const PAGE_SIZE: usize = 4096;

const PhysicalMemoryAllocators = struct {
    kernel: BitmapAllocator,
    acpi: BitmapAllocator,
};

var allocators: ?PhysicalMemoryAllocators = null;

pub fn init(mb: *const BootInfo) void {
    std.log.debug("Initializing physical memory", .{});
    std.log.debug("HHDM offset: {x}", .{mb.hhdm_offset});
    std.log.debug("Initializing ACPI PMEM", .{});
    const _acpi = BitmapAllocator.init(mb.memory_map, mb.hhdm_offset, .init(0, 32 * 1024 * 1024));
    std.log.debug("Initializing KERNEL PMEM", .{});
    const _kernel = BitmapAllocator.init(mb.memory_map, mb.hhdm_offset, .init(32 * 1024 * 1024, 1024 * 1024 * 1024)); // 1 GB of kernel memory

    allocators = PhysicalMemoryAllocators{
        .acpi = _acpi,
        .kernel = _kernel,
    };
}

pub fn kernel() *BitmapAllocator {
    return &allocators.?.kernel;
}

pub fn acpi() *BitmapAllocator {
    return &allocators.?.acpi;
}
