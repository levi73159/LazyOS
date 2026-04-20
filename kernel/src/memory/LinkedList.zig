const std = @import("std");
const root = @import("root");
const paging = root.arch.paging;
const mem = std.mem;
const BitmapAllocator = @import("BitmapAllocator.zig");
const is_debug = true;

const Self = @This();

const log = std.log.scoped(._heap);

const PAGE_SIZE = 4096;

const HEAP_PAGES = 64;
const EXTRA_GROWTH = 8;
const HEAP_SIZE = PAGE_SIZE * HEAP_PAGES;

// every time we allocate we also will have this
// [Header] [padding] [offset] [data]
// offset is how many bytes to offset ptr to end of header = padding
// Header will contain info about size and next block prev block, magic number, padding, and free
// A block is defined as
// [Header][padding][offset][data]
// every block contains a block_padding which is the padding between blocks
// [Block0][block_padding][Block1]
// in this situation block_padding will be contained in Block0

const Fields = packed struct(usize) {
    is_free: bool = true,
    padding: u16,
    size: u47,

    pub fn init(size: usize, is_free: bool) Fields {
        return .{
            .is_free = is_free,
            .size = @intCast(size),
            .padding = 0,
        };
    }
};

const Header = struct {
    flags: Fields, // does not include header of offset data header at start of data, only
    next: ?*Header,
    block_padding: u16 = 0,

    fn trueSize(self: *const Header) usize {
        return self.flags.size + HEADER_SIZE + OFFSET_SIZE + self.padding();
    }

    fn getSize(self: *const Header) usize {
        return self.flags.size;
    }

    fn padding(self: *const Header) u16 {
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
    }

    fn setSize(self: *Header, size: usize) void {
        self.flags.size = @intCast(size);
    }

    pub fn format(
        self: *const @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("0x{x}:({any}, next: 0x{x}, true size: {d})", .{ @intFromPtr(self), self.flags, @intFromPtr(self.next), self.trueSize() });
    }
};
const HEADER_SIZE = @sizeOf(Header);
const OFFSET_SIZE = @sizeOf(u16);
const offset_type = u16;

const MIN_SPLIT = HEADER_SIZE + OFFSET_SIZE + 1;

name: ?[]const u8 = null, // name of this heap (used for debugging)
start: ?*Header = null,
end: ?*Header = null,
last_free: ?*Header = null,
base: usize,
limit: usize,
pages_in_heap: u32 = 0,
pmem: *BitmapAllocator = undefined,

pub fn init(pmem: *BitmapAllocator, base: usize, limit: usize) Self {
    log.debug("HEADER SIZE: {d}", .{@sizeOf(Header)});
    const page_phys = pmem.allocPages(HEAP_PAGES) catch @panic("out of memory cannot init heap");
    paging.getKernelVmem().mapRange(base, page_phys, HEAP_PAGES * PAGE_SIZE, .rw);

    const page = base;
    const header: *Header = @ptrFromInt(page);
    header.* = .{
        .flags = .init(HEAP_SIZE - HEADER_SIZE - OFFSET_SIZE, true),
        .next = null,
    };
    return Self{ .start = header, .end = header, .last_free = header, .pages_in_heap = HEAP_PAGES, .pmem = pmem, .base = base, .limit = limit };
}

// NOTE: only to be called by heap.zig when fully init heap and vmem
pub fn updateRegions(self: *Self, alloc: std.mem.Allocator, comptime name: []const u8) void {
    paging.getKernelVmem().addRegion(alloc, name ++ " heap start", @intFromPtr(self.start.?), self.start.?.trueSize());
    self.name = name;
}

pub fn deinit(self: *Self) void {
    var current = self.start;
    while (current) |b| {
        current = b.next;
        const pages = b.trueSize() / PAGE_SIZE;
        self.pmem.freePagesV(@intFromPtr(b), pages);

        log.debug("freeing {d} pages at address {x}", .{ pages, @intFromPtr(b) });
    }
}

fn findPrev(self: *Self, block: *Header) ?*Header {
    var current = self.start; // should we use last_free?

    while (current) |b| {
        if (b.next == block) return b;
        current = b.next;
    }

    return null;
}

fn allocPage(self: *Self, pages: usize) !*Header {
    const base_start = self.base + (self.pages_in_heap * PAGE_SIZE);
    const end = base_start + (pages * PAGE_SIZE);

    if (end > self.base + self.limit) {
        return error.OutOfMemory;
    }
    for (0..pages) |i| {
        const virt = base_start + (i * PAGE_SIZE);
        const phys = self.pmem.allocPage() catch return error.OutOfMemory;

        paging.getKernelVmem().mapPage(virt, phys, .rw);
    }
    const header: *Header = @ptrFromInt(base_start);

    const size = pages * PAGE_SIZE;
    header.* = .{
        .flags = .init(size - HEADER_SIZE - OFFSET_SIZE, true),
        .next = null,
    };

    self.pages_in_heap += @intCast(pages);

    return header;
}

fn growHeap(self: *Self, pages: usize) !*Header {
    log.debug("growing heap by {d}+1 pages", .{pages});
    const header = try self.allocPage(pages);
    const extra: ?*Header = if (self.pages_in_heap < 1_000) self.allocPage(EXTRA_GROWTH) catch null else null;

    if (self.end) |end| {
        end.next = header;
    }
    header.next = extra;

    self.end = extra orelse header;
    self.last_free = header;

    return header;
}

fn isClose(a: *const Header, b: *const Header) bool {
    return @intFromPtr(a) + a.trueSize() + a.block_padding == @intFromPtr(b);
}

fn splitBlock(self: *Self, block: *Header, size: usize) bool {
    const block_addr = @intFromPtr(block);

    const addr = block_addr + HEADER_SIZE + OFFSET_SIZE + size + block.padding();
    const aligned_addr = mem.alignForward(usize, addr, @alignOf(Header));
    const block_padding = aligned_addr - addr;

    const required = size + HEADER_SIZE + OFFSET_SIZE + block.padding() + block_padding;

    if (block.getSize() < required + MIN_SPLIT)
        return false;

    block.block_padding = @intCast(block_padding);
    const header: *Header = @ptrFromInt(aligned_addr);

    header.* = .{
        .flags = .init(block.getSize() - block.padding() - HEADER_SIZE - OFFSET_SIZE - size - block_padding, true),
        .next = block.next,
    };

    block.next = header;
    block.setSize(size);

    self.last_free = header;

    return true;
}

fn canMergeForward(block: *const Header) bool {
    return block.next != null and block.next.?.isFree() and isClose(block, block.next.?);
}

fn mergeBlockFoward(self: *Self, block: *Header) void {
    // block consumes next block
    while (block.next) |next_block| {
        if (next_block.isFree() and isClose(block, next_block)) {
            // Only inherit last_free if block itself is free. When called from _resize
            // block is still in-use, so fall through to next_block.next instead.
            // IMPORTANT: use next_block.next here, NOT block.next — block.next still
            // equals next_block at this point (the reassignment on line below hasn't run).
            // Using block.next would set last_free to the block being consumed = dangling ptr.
            if (next_block == self.last_free) self.last_free = if (block.isFree()) block else next_block.next;
            if (next_block == self.end) self.end = block;

            block.addSize(next_block.trueSize() + block.block_padding);
            block.block_padding = next_block.block_padding;
            block.next = next_block.next;
        } else {
            break;
        }
    }
}

/// after calling this, block may be merged and will not be valid, therfore this functions returns the updated block header pointer
fn mergeBlockBackward(self: *Self, block: *Header) *Header {
    // previous block consumes block
    var current = block;
    while (self.findPrev(current)) |prev_block| {
        if (prev_block.isFree() and isClose(prev_block, current)) {
            if (current == self.last_free) self.last_free = prev_block;
            if (current == self.end) self.end = prev_block;

            prev_block.addSize(current.trueSize() + prev_block.block_padding);
            prev_block.block_padding = current.block_padding;
            prev_block.next = current.next;
            current = prev_block;
        } else {
            break;
        }
    }

    return current;
}

fn mergeBlock(self: *Self, block: *Header) *Header {
    self.mergeBlockFoward(block);
    return self.mergeBlockBackward(block);
}

fn findFreeBlock(self: *Self, size: usize, alignment: mem.Alignment) ?*Header {
    var current = self.last_free;

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

    current = self.start;

    while (current) |block| {
        if (block == self.last_free) break;
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

pub fn allocate(self: *Self, size: usize, _alignment: mem.Alignment) ![*]u8 {
    const alignment = mem.Alignment.max(_alignment, .@"16"); // at least 2 byte alignment
    if (alignment.toByteUnits() % 2 != 0) @panic("Alignment must be a multiple of 2");
    const block = self.findFreeBlock(size, alignment) orelse blk: {
        log.debug("Size: {d}: alignment: {d}", .{ size, alignment });
        const total_size = size + alignment.toByteUnits() + HEADER_SIZE + OFFSET_SIZE;
        log.debug("Total size: {d}", .{total_size});
        const pages_needed = (total_size + PAGE_SIZE - 1) / PAGE_SIZE;
        log.debug("Allocating {d} pages", .{pages_needed});
        const block = try self.growHeap(pages_needed);
        break :blk block;
    };

    block.setFree(false);

    const block_addr = @intFromPtr(block);
    const data_addr = block_addr + HEADER_SIZE + OFFSET_SIZE;
    const aligned_data_addr = mem.alignForward(usize, data_addr, alignment.toByteUnits());
    const padding = aligned_data_addr - block_addr - HEADER_SIZE - OFFSET_SIZE;
    block.setPadding(padding);

    const offset_ptr: *offset_type = @ptrFromInt(aligned_data_addr - OFFSET_SIZE);
    offset_ptr.* = @intCast(padding);

    if (!self.splitBlock(block, size)) {
        // can't shrink block so we act like we splitting it by setting the size and adding the block padding to compensate
        // block_padding is u8 — if the excess exceeds 255 we cannot store it there, so leave
        // the block slightly oversized rather than wrapping and corrupting the free-list geometry.
        const excess = block.getSize() - size;
        if (excess <= std.math.maxInt(u16)) {
            block.block_padding += @intCast(excess);
            block.setSize(size);
        }
        // else: block stays oversized; wasteful but safe.

        // splitBlock didn't run, so last_free was not updated. If it still points to
        // this block (which is now in-use), advance it so findFreeBlock doesn't get
        // stuck and grow the heap on every subsequent allocation.
        if (self.last_free == block) self.last_free = block.next;
    }

    // log.debug("alloc({d}) = {x}", .{ size, aligned_data_addr });
    return @ptrFromInt(aligned_data_addr);
}

pub fn free(self: *Self, ptr: [*]u8) void {
    // log.debug("free({x})", .{@intFromPtr(ptr)});
    const offset: *offset_type = @ptrFromInt(@intFromPtr(ptr) - OFFSET_SIZE);
    const block: *Header = @ptrFromInt(@intFromPtr(ptr) - offset.* - HEADER_SIZE - OFFSET_SIZE);

    block.setFree(true);
    const updated_block = self.mergeBlock(block);
    self.last_free = updated_block;

    updated_block.addSize(updated_block.padding());
    updated_block.setPadding(0);
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

    const offset: *offset_type = @ptrFromInt(@intFromPtr(memory.ptr) - OFFSET_SIZE);
    const block: *Header = @ptrFromInt(@intFromPtr(memory.ptr) - offset.* - HEADER_SIZE - OFFSET_SIZE);

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

pub fn dump(self: *Self, fliter: enum { free, used, all }, comptime print: fn (comptime fmt: []const u8, args: anytype) void) void {
    var current = self.start;
    while (current) |block| : (current = block.next) {
        if (fliter == .free and !block.isFree()) {
            continue;
        }
        print("Block {x} - {x}", .{ @intFromPtr(block), @intFromPtr(block) + block.trueSize() });
        print("  Size: {d}", .{block.getSize()});
        print("  True Size: {d}", .{block.trueSize()});
        print("  Block Padding: {d}", .{block.block_padding});
        print("  Padding: {d}", .{block.padding()});
        print("  USER DATA ADDR: {x}", .{@intFromPtr(block) + HEADER_SIZE + OFFSET_SIZE + block.padding()});
        print("  Free: {}", .{block.isFree()});
        print("  Next: {?*}", .{block.next});

        if (!block.isFree()) {
            const data_addr = @intFromPtr(block) + HEADER_SIZE + OFFSET_SIZE + block.padding();
            // const data = @as([*]u8, @ptrFromInt(data_addr))[0..block.getSize()];
            // print("  DATA: {any}", .{data});

            const offset_ptr: *offset_type = @ptrFromInt(data_addr - OFFSET_SIZE);
            print("  Offset: {d}", .{offset_ptr.*});
        }
    }
}
