const std = @import("std");
const mem = std.mem;

const multiboot = @import("../arch.zig").Multiboot;

const log = std.log.scoped(.bitmap_allocator);

const Self = @This();

block_size: u64,
memsize_bytes: u64,
memsize: u64,

membase: [*]u8,

const RegionBlocks = struct {
    base: u64,
    size: u64,
    type: multiboot.MemoryType,
};

pub fn init(block_size: u64, regions: []multiboot.MemoryMapEntry) !Self {
    var self = Self{
        .block_size = block_size,
        .memsize_bytes = 0,
        .memsize = 0,
        .membase = undefined,
    };
    self.determineMemoryRage(regions);
}

inline fn toBlock(self: Self, ptr: anytype) u64 {
    const u8ptr: [*]u8 = @ptrCast(@alignCast(ptr));
    return (u8ptr - self.membase) / self.block_size;
}

inline fn toBlockRoundup(self: Self, ptr: anytype) u64 {
    const u8ptr: [*]u8 = @ptrCast(@alignCast(ptr));
    return std.math.divCeil(u64, @intFromPtr(u8ptr - self.membase), self.block_size) catch @panic("Divide by zero");
}

inline fn toPtr(comptime T: type, self: Self, block: u64) T {
    const u8Ptr: [*]u8 = self.membase + block * self.block_size;
    return @ptrCast(@alignCast(u8Ptr));
}
