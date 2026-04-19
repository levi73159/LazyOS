const std = @import("std");
const BitmapAllocator = @import("BitmapAllocator.zig");
const BootInfo = @import("../arch/bootinfo.zig").BootInfo;

pub const PAGE_SIZE: usize = 4096;

const PhysicalMemoryAllocators = struct {
    acpi: BitmapAllocator, // 0 - 32 MB because acpi doesn't need much memory
    kernel: BitmapAllocator, // 32 MB - 1 GB
    user: ?BitmapAllocator, // 1 GB - end (if memory available if not, user processess will use kernel bitmap)
};

var allocators: ?PhysicalMemoryAllocators = null;

pub fn init(mb: *const BootInfo) void {
    std.log.debug("Initializing physical memory", .{});
    std.log.debug("HHDM offset: {x}", .{mb.hhdm_offset});
    std.log.debug("Initializing ACPI PMEM", .{});
    const _acpi = BitmapAllocator.init(mb.memory_map, mb.hhdm_offset, .init(0, 32 * 1024 * 1024));
    std.log.debug("Initializing KERNEL PMEM", .{});
    const _kernel = BitmapAllocator.init(mb.memory_map, mb.hhdm_offset, .init(32 * 1024 * 1024, 1024 * 1024 * 1024));

    var memory_end: u64 = 0;
    for (mb.memory_map) |entry| {
        if (entry.type == .usable) {
            memory_end = @max(memory_end, entry.base + entry.length);
        }
    }

    const aligned_end_addr = std.mem.alignBackward(u64, memory_end, 4096);
    std.log.debug("Memory end: {x}", .{aligned_end_addr});

    std.log.debug("Initializing USER PMEM", .{});
    const _user = if (aligned_end_addr < 1024 * 1024 * 1024) blk: {
        std.log.warn("Not enough memory for user processes (defaulting to kernel bitmap)", .{});
        break :blk null;
    } else BitmapAllocator.init(mb.memory_map, mb.hhdm_offset, .init(1024 * 1024 * 1024, aligned_end_addr));

    allocators = PhysicalMemoryAllocators{
        .acpi = _acpi,
        .kernel = _kernel,
        .user = _user,
    };
}

pub fn kernel() *BitmapAllocator {
    return &allocators.?.kernel;
}

pub fn acpi() *BitmapAllocator {
    return &allocators.?.acpi;
}

pub fn user() *BitmapAllocator {
    return &(allocators.?.user orelse allocators.?.kernel);
}
