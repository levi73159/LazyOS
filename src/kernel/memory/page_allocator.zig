const std = @import("std");
const pmem = @import("pmem.zig");
const mem = std.mem;

const log = std.log.scoped(.page_allocator);

const PAGE_SIZE = 4096;

fn alloc(ctx: *anyopaque, size: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    const align_val = alignment.toByteUnits();

    const aligned_size = size + align_val - 1;
    const pages_needed = (aligned_size + PAGE_SIZE - 1) / PAGE_SIZE; // round up to nearest page
    const addr = pmem.allocPagesV(pages_needed) catch return null;

    // make sure the address is aligned to
    const aligned_addr = mem.alignForward(usize, addr, align_val);
    return @ptrFromInt(aligned_addr);
}

fn free(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = ret_addr;

    const addr = @intFromPtr(memory.ptr);
    const aligned_addr = mem.alignBackward(usize, addr, alignment.toByteUnits());

    const pages_needed = (memory.len + PAGE_SIZE - 1) / PAGE_SIZE; // round up to nearest page
    pmem.freePagesV(aligned_addr, pages_needed);
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_size: usize, ret_addr: usize) bool {
    const pages_count = (buf.len + PAGE_SIZE - 1) / PAGE_SIZE; // round up to nearest page
    const new_pages_count = (new_size + PAGE_SIZE - 1) / PAGE_SIZE; // round up to nearest page

    if (pages_count == new_pages_count) return true;
    if (pages_count > new_pages_count) {
        const page_diff = pages_count - new_pages_count;
        const byte_diff = page_diff * PAGE_SIZE;
        const addr = @intFromPtr(buf.ptr);
        const aligned_addr = mem.alignBackward(usize, addr, alignment.toByteUnits());
        pmem.freePagesV(aligned_addr + byte_diff, page_diff);
        return true;
    }
    if (new_size == 0) {
        free(ctx, buf, alignment, ret_addr);
        return true;
    }

    return false;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
    // if resize fails, move memory
    if (resize(ctx, buf, alignment, new_size, ret_addr)) {
        return buf.ptr;
    }

    const new_buf = alloc(ctx, new_size, alignment, ret_addr) orelse return null;

    const copy_size = @min(buf.len, new_size);
    @memcpy(new_buf[0..copy_size], buf[0..copy_size]);

    free(ctx, buf, alignment, ret_addr);
    return new_buf;
}

pub const allocator = mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .free = free,
        .resize = resize,
        .remap = remap,
    },
};
