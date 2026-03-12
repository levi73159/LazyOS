const std = @import("std");
const mem = std.mem;
const pmem = @import("pmem.zig");
const is_debug = @import("builtin").mode == .Debug;

const Self = @This();

const log = std.log.scoped(.heap);

const PAGE_SIZE = 4096;

// every time we allocate we also will have this
// [Header] [padding] [offset] [data]
// offset is how many bytes to offset ptr to end of header = padding
// Header will contain info about size and next block prev block, magic number, padding, and free

const Fields = packed struct(usize) {
    is_free: bool = true,
    even: bool = false,
    padding: u8,
    block_padding: u8 = 0,
    size: u46,

    pub fn init(size: usize, is_free: bool) Fields {
        return .{
            .is_free = is_free,
            .even = if (is_debug) size % 2 == 0 else false,
            .size = @intCast(size),
            .padding = 0,
        };
    }

    pub fn verify(self: *const Fields) bool {
        if (is_debug) {
            const is_even = self.size % 2 == 0;
            if (is_even != self.even) return false;
            return true;
        }
        return !self.even;
    }
};

const Header = struct {
    flags: Fields, // does not include header of offset data header at start of data, only
    next: ?*Header,

    fn verify(self: *const Header) void {
        if (self.flags.verify() == false) std.debug.panic("Header Corrupted at address {x}", .{@intFromPtr(self)});
    }

    fn trueSize(self: *const Header) usize {
        return self.flags.size + HEADER_SIZE + OFFSET_SIZE + self.padding();
    }

    fn getSize(self: *const Header) usize {
        return self.flags.size;
    }

    fn padding(self: *const Header) u8 {
        return self.flags.padding;
    }

    fn setPadding(self: *Header, _pad: usize) void {
        self.flags.padding = @intCast(_pad);
    }

    fn isFree(self: *const Header) bool {
        return self.flags.is_free;
    }

    fn setFree(self: *Header, is_free: bool) void {
        self.flags.is_free = is_free;
    }

    fn addSize(self: *Header, size: usize) void {
        self.flags.size += @intCast(size);
        if (is_debug)
            self.flags.even = self.flags.size % 2 == 0;
    }

    fn setSize(self: *Header, size: usize) void {
        self.flags.size = @intCast(size);
        if (is_debug)
            self.flags.even = self.flags.size % 2 == 0;
    }

    pub fn format(
        self: *const @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("0x{x}:({any}, next: 0x{x}, true size: {d})", .{ @intFromPtr(self), self.flags, @intFromPtr(self.next), self.trueSize() });
    }
};
const HEADER_SIZE = @sizeOf(Header);
const OFFSET_SIZE = @sizeOf(u8);

const MIN_SPLIT = 32;

start: ?*Header = null,
end: ?*Header = null,
last_free: ?*Header = null,

pub fn init() Self {
    log.debug("HEADER SIZE: {d}", .{@sizeOf(Header)});
    const page = pmem.allocPagesV(1) catch @panic("out of memory cannot init heap");
    const header: *Header = @ptrFromInt(page);
    header.* = .{
        .flags = .init(PAGE_SIZE - HEADER_SIZE - OFFSET_SIZE, true),
        .next = null,
    };
    return Self{ .start = header, .end = header, .last_free = header };
}

fn findPrev(self: *Self, block: *Header) ?*Header {
    var current = self.start;

    while (current) |b| {
        if (b.next == block) return b;
        current = b.next;
    }

    return null;
}

fn growHeap(self: *Self, pages: usize) !*Header {
    log.debug("growing heap by {d} pages", .{pages});
    const page = try pmem.allocPagesV(pages);
    const header: *Header = @ptrFromInt(page);

    const size = pages * PAGE_SIZE;
    header.* = .{
        .flags = .init(size - HEADER_SIZE - OFFSET_SIZE, true),
        .next = null,
    };

    if (self.end) |end| {
        end.next = header;
    }

    self.end = header;
    self.last_free = header;
    return header;
}

fn isClose(a: *const Header, b: *const Header) bool {
    return @intFromPtr(a) + a.trueSize() + a.flags.block_padding == @intFromPtr(b);
}

fn splitBlock(self: *Self, block: *Header, size: usize) bool {
    const block_addr = @intFromPtr(block);

    const addr = block_addr + HEADER_SIZE + OFFSET_SIZE + size + block.padding();
    const aligned_addr = mem.alignForward(usize, addr, @alignOf(Header));
    const block_padding = aligned_addr - addr;

    const required = size + HEADER_SIZE + OFFSET_SIZE + block.padding() + block_padding;

    if (block.getSize() < required + MIN_SPLIT)
        return false;

    block.flags.block_padding = @intCast(block_padding);
    const header: *Header = @ptrFromInt(aligned_addr);

    log.debug("block addr: {x}", .{@intFromPtr(block)});
    log.debug("other header addr: {x}", .{@intFromPtr(header)});

    const remaining = block.trueSize() - size;
    if (remaining < MIN_SPLIT + HEADER_SIZE + OFFSET_SIZE) return false;

    const block_end = block_addr + block.trueSize() + size;
    const new_header_addr = aligned_addr;

    const new_block_size = block_end - new_header_addr - HEADER_SIZE - OFFSET_SIZE;
    log.debug("block remaining: {d}", .{remaining});
    header.* = .{
        .flags = .init(new_block_size, true),
        .next = block.next,
    };

    block.next = header;
    block.setSize(size);

    self.last_free = header;

    header.verify();
    block.verify();

    log.debug("header true size: {d}", .{header.trueSize()});
    log.debug("block true size: {d}", .{block.trueSize()});

    return true;
}

fn canMergeForward(block: *const Header) bool {
    return block.next != null and block.next.?.isFree() and isClose(block, block.next.?);
}

fn mergeBlockFoward(self: *Self, block: *Header) void {
    // block consumes next block
    while (block.next) |next_block| {
        if (next_block.isFree() and isClose(block, next_block)) {
            if (next_block == self.last_free) self.last_free = block;

            log.debug("merging blocks {f} and {f}", .{ block, next_block });
            block.addSize(next_block.trueSize() + block.flags.block_padding);
            block.flags.block_padding = next_block.flags.block_padding;
            block.next = next_block.next;
        } else {
            break;
        }
    }

    block.verify();
}

/// after calling this, block may be merged and will not be valid, therfore this functions returns the updated block header pointer
fn mergeBlockBackward(self: *Self, block: *Header) *Header {
    // previous block consumes block
    var current = block;
    while (self.findPrev(current)) |prev_block| {
        if (prev_block.isFree() and isClose(prev_block, current)) {
            if (current == self.last_free) self.last_free = prev_block;

            log.debug("merging blocks {f} and {f}", .{ block, prev_block });
            prev_block.addSize(current.trueSize() + prev_block.flags.block_padding);
            prev_block.flags.block_padding = current.flags.block_padding;
            prev_block.next = current.next;
            current = prev_block;
        } else {
            break;
        }
    }
    current.verify();

    return current;
}

fn mergeBlock(self: *Self, block: *Header) *Header {
    self.mergeBlockFoward(block);
    return self.mergeBlockBackward(block);
}

fn findFreeBlock(self: *Self, size: usize, alignment: mem.Alignment) ?*Header {
    var current = self.start;

    while (current) |block| {
        if (block.isFree()) {
            // Calculate padding required to satisfy alignment
            const block_addr = @intFromPtr(block);
            const aligned_data_addr = mem.alignForward(usize, block_addr + HEADER_SIZE + OFFSET_SIZE, alignment.toByteUnits());
            const padding = aligned_data_addr - block_addr - HEADER_SIZE - OFFSET_SIZE;

            // Check if block is large enough for requested size + offset + padding
            if (block.getSize() >= size + padding) {
                block.setPadding(padding);
                return block;
            }
        }
        current = block.next;
    }

    // No suitable free block found
    return null;
}

pub fn allocate(self: *Self, size: usize, alignment: mem.Alignment) ![*]u8 {
    log.debug("allocating {d} bytes, {d} bits", .{ size, size * 8 });
    const block = self.findFreeBlock(size, alignment) orelse blk: {
        const total_size = size + alignment.toByteUnits() + HEADER_SIZE + OFFSET_SIZE;
        const pages_needed = (total_size + PAGE_SIZE - 1) / PAGE_SIZE;
        const block = try self.growHeap(pages_needed);
        log.debug("block {f}", .{block});
        break :blk block;
    };

    block.verify();

    block.setFree(false);

    const block_addr = @intFromPtr(block);
    log.debug("block addr: {x}", .{block_addr});
    const data_addr = block_addr + HEADER_SIZE + OFFSET_SIZE;
    log.debug("data addr: {x}", .{data_addr});
    const aligned_data_addr = mem.alignForward(usize, data_addr, alignment.toByteUnits());
    log.debug("aligned data addr: {x}", .{aligned_data_addr});
    const padding = aligned_data_addr - block_addr - HEADER_SIZE - OFFSET_SIZE;
    log.debug("padding: {d}", .{padding});
    block.setPadding(padding);

    const offset_ptr: *u8 = @ptrFromInt(aligned_data_addr - OFFSET_SIZE);
    offset_ptr.* = @intCast(padding);

    log.debug("offset: {d}", .{offset_ptr.*});

    if (!self.splitBlock(block, size)) {
        log.warn("Failed to split block", .{});
    }

    log.debug("block {f}", .{block});

    self.dump();

    return @ptrFromInt(aligned_data_addr);
}

pub fn free(self: *Self, ptr: [*]u8) void {
    const offset: u8 = (ptr - 1)[0];
    const block: *Header = @ptrFromInt(@intFromPtr(ptr) - offset - HEADER_SIZE - OFFSET_SIZE);

    block.setFree(true);
    const updated_block = self.mergeBlock(block);
    self.last_free = updated_block;

    updated_block.addSize(updated_block.padding());
    updated_block.setPadding(0);

    updated_block.verify();
}

fn _alloc(ctx: *anyopaque, size: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.allocate(size, alignment) catch null;
}

fn _free(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    _ = alignment;

    const self: *Self = @ptrCast(@alignCast(ctx));
    self.free(memory.ptr);
}

fn _resize(ctx: *anyopaque, memory: []u8, _: mem.Alignment, new_size: usize, _: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));

    // attempt to resize in place
    if (memory.len == new_size) return true;
    if (memory.len == 0) {
        self.free(memory.ptr);
        return true;
    }

    const offset: u8 = (memory.ptr - 1)[0];
    const block: *Header = @ptrFromInt(@intFromPtr(memory.ptr) - offset - HEADER_SIZE - OFFSET_SIZE);

    if (block.getSize() > new_size) {
        if (self.splitBlock(block, new_size)) {
            self.mergeBlockFoward(block.next.?);
        }
        return true;
    }

    self.mergeBlockFoward(block);
    if (block.getSize() > new_size) {
        _ = self.splitBlock(block, new_size);
        return true;
    }
    if (block.getSize() == new_size) {
        return true;
    }

    return false;
}

fn _remap(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (_resize(ctx, memory, alignment, new_size, ret_addr)) {
        return memory.ptr;
    }

    self.free(memory.ptr);
    const ptr = self.allocate(new_size, alignment) catch return null;

    const copy_size = @min(memory.len, new_size);
    std.mem.copyForwards(u8, ptr[0..copy_size], memory[0..copy_size]);
    return ptr;
}

pub fn allocator(self: *Self) mem.Allocator {
    return mem.Allocator{
        .ptr = self,
        .vtable = &mem.Allocator.VTable{
            .alloc = _alloc,
            .free = _free,
            .resize = _resize,
            .remap = _remap,
        },
    };
}

pub fn dump(self: *Self) void {
    var current = self.start;
    while (current) |block| {
        log.debug("Block {x} - {x}", .{ @intFromPtr(block), @intFromPtr(block) + block.trueSize() });
        log.debug("  Size: {d}", .{block.getSize()});
        log.debug("  True Size: {d}", .{block.trueSize()});
        log.debug("  Block Padding: {d}", .{block.flags.block_padding});
        log.debug("  Padding: {d}", .{block.padding()});
        log.debug("  USER DATA ADDR: {x}", .{@intFromPtr(block) + HEADER_SIZE + OFFSET_SIZE + block.padding()});
        log.debug("  Free: {}", .{block.isFree()});
        log.debug("  Next: {?*}", .{block.next});
        log.debug("  Even: {}", .{block.flags.even});

        if (!block.isFree()) {
            const data_addr = @intFromPtr(block) + HEADER_SIZE + OFFSET_SIZE + block.padding();
            // const data = @as([*]u8, @ptrFromInt(data_addr))[0..block.getSize()];
            // log.debug("  DATA: {any}", .{data});

            const offset_ptr: *u8 = @ptrFromInt(data_addr - OFFSET_SIZE);
            log.debug("  Offset: {d}", .{offset_ptr.*});
        }

        current = block.next;
    }
}
