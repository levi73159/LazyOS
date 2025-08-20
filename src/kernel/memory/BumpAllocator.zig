const std = @import("std");
const builtin = @import("builtin");

const mem = std.mem;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.bump_allocator);

const Self = @This();

region: []u8,
end: usize,

pub fn init(region: []u8) Self {
    return Self{
        .region = region,
        .end = 0,
    };
}

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &Allocator.VTable{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        },
    };
}

pub fn alloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, _: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    log.debug("allocating {d} bytes", .{len});

    const ptr_aligned = alignment.toByteUnits();
    const adjust_off = mem.alignPointerOffset(self.region.ptr + self.end, ptr_aligned) orelse return null;
    const adjusted_index = self.end + adjust_off;
    const new_end_index = adjusted_index + len;
    if (new_end_index > self.region.len) return null;
    self.end = new_end_index;
    return self.region.ptr + adjusted_index;
}

pub fn isLastAllocation(self: *Self, buf: []u8) bool {
    return buf.ptr + buf.len == self.region.ptr + self.end;
}

pub fn resize(
    ctx: *anyopaque,
    buf: []u8,
    _: mem.Alignment,
    new_size: usize,
    _: usize,
) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (!self.isLastAllocation(buf)) {
        if (new_size > buf.len) return false;
        return true;
    }

    if (new_size <= buf.len) {
        const sub = buf.len - new_size;
        self.end -= sub;
        return true;
    }

    const add = new_size - buf.len;
    if (add + self.end > self.region.len) return false;

    self.end += add;
    return true;
}

pub fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

pub fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    return_address: usize,
) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = return_address;

    if (self.isLastAllocation(buf)) {
        self.end -= buf.len;
    }
}
