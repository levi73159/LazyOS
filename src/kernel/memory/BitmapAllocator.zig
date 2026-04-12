const std = @import("std");
const bootinfo = @import("../arch/bootinfo.zig");
const Alignment = std.mem.Alignment;

const log = std.log.scoped(.bitmap_allocator);

const PAGE_SIZE = 4096;

const Self = @This();

pub const PhysRange = struct {
    start: u64,
    length: u64,

    pub fn init(start: u64, _end: u64) PhysRange {
        std.debug.assert(start <= _end);
        const length = _end - start;
        return PhysRange{
            .start = std.mem.alignForward(usize, start, PAGE_SIZE),
            .length = std.mem.alignForward(usize, length, PAGE_SIZE),
        };
    }

    pub inline fn end(self: PhysRange) u64 {
        return self.start + self.length;
    }

    pub fn inside(self: PhysRange, addr: u64) bool {
        return addr >= self.start and addr < self.end();
    }
};

bitmap: []u8,
total_pages: u64,
last_used_index: u64,
usable_memory: u64,
start: u64,

pub fn init(mmap: []*bootinfo.MemoryMapEntry, hddm_offset: u64, range: PhysRange) Self {
    // find the highest address in memory to size the bitmap
    var highest: u64 = 0;
    for (mmap) |entry| {
        // only consider usable memory
        highest = @max(highest, entry.base + entry.length);
    }
    if (range.end() < highest) highest = range.end(); // limit to highst range if range is to high use highest usable memory
    log.debug("Highest address: 0x{x}", .{highest});

    const total_pages = (highest - range.start) / PAGE_SIZE;
    const bitmap_size = (total_pages + 7) / 8; // round up to nearest byte

    log.debug("Total pages: {d}", .{total_pages});
    var bitmap: []u8 = undefined;
    var usable_memory: u64 = 0;

    // bitmap placement — find usable entry that overlaps range and is large enough
    for (mmap) |entry| {
        if (entry.type != .usable) continue;
        if (!overlapsRange(entry.base, entry.length, range)) continue;

        const base, const len = clampToRange(entry.base, entry.length, range);
        if (len >= bitmap_size) {
            bitmap = @as([*]u8, @ptrFromInt(base + hddm_offset))[0..bitmap_size];
            @memset(bitmap, 0xFF);
            break;
        }
    } else {
        @panic("Couldn't find usable memory large enough to hold the bitmap");
    }

    // mark free regions — clamp each entry to range bounds
    for (mmap) |entry| {
        if (entry.type != .usable) continue;
        if (!overlapsRange(entry.base, entry.length, range)) continue;

        const base, const len = clampToRange(entry.base, entry.length, range);
        freeRegion(bitmap, base, len, range);
        usable_memory += len;
    }

    markUsed(bitmap, @intFromPtr(bitmap.ptr) - hddm_offset, bitmap_size, range);

    return Self{
        .bitmap = bitmap,
        .total_pages = total_pages,
        .last_used_index = 0,
        .usable_memory = usable_memory,
        .start = range.start,
    };
}

pub fn allocPage(self: *Self) !u64 {
    // finds a free bit starting from last_used_index
    var i = self.last_used_index;
    while (i < self.total_pages) : (i += 1) {
        if (!getBit(self.bitmap, i)) {
            setBit(self.bitmap, i); // mark as used
            self.last_used_index = i + 1;
            return i * PAGE_SIZE + self.start;
        }
    }

    return error.OutOfMemroy;
}

fn overlapsRange(entry_base: u64, entry_len: u64, range: PhysRange) bool {
    return entry_base < range.end() and entry_base + entry_len > range.start;
}

// clamp an entry to the range bounds
fn clampToRange(base: u64, length: u64, range: PhysRange) struct { u64, u64 } {
    const clamped_base = @max(base, range.start);
    const clamped_end = @min(base + length, range.end());
    if (clamped_end <= clamped_base) return .{ 0, 0 };
    return .{ clamped_base, clamped_end - clamped_base };
}

pub fn freePage(self: *Self, phys: u64) void {
    const index = (phys - self.start) / PAGE_SIZE;
    clearBit(self.bitmap, index);
    if (index < self.last_used_index) self.last_used_index = index;
}

// allocate a page, but returns its virtual address
pub fn allocPageV(self: *Self) !u64 {
    const phys = try self.allocPage();
    return bootinfo.toVirtualHHDM(phys);
}

// free a page by its virtual address
pub fn freePageV(self: *Self, virt: u64) void {
    const phys = bootinfo.toPhysicalHHDM(virt);
    self.freePage(phys);
}

pub fn allocPages(self: *Self, count: usize) !u64 {
    var i = self.last_used_index;
    var pages_found: u32 = 0;

    var start: ?u64 = null;
    while (i < self.total_pages) : (i += 1) {
        if (!getBit(self.bitmap, i)) {
            if (start == null) {
                start = i;
            }
            pages_found += 1;
            if (pages_found >= count) {
                for (0..pages_found) |j| {
                    setBit(self.bitmap, start.? + j);
                }
                self.last_used_index = i + 1;
                return start.? * PAGE_SIZE + self.start;
            }
        } else {
            pages_found = 0;
            start = null;
        }
    }

    return error.OutOfMemroy;
}

pub fn allocPagesV(self: *Self, count: usize) !u64 {
    const phys = try self.allocPages(count);
    return bootinfo.toVirtualHHDM(phys);
}

pub fn freePages(self: *Self, phys: u64, count: usize) void {
    const index = phys / PAGE_SIZE - self.start / PAGE_SIZE;
    for (0..count) |i| {
        clearBit(self.bitmap, index + i);
    }
    if (index < self.last_used_index) self.last_used_index = index;
}

pub fn freePagesV(self: *Self, virt: u64, count: usize) void {
    const phys = bootinfo.toPhysicalHHDM(virt);
    self.freePages(phys, count);
}

inline fn setBit(bitmap: []u8, index: u64) void {
    bitmap[index / 8] |= (@as(u8, 1) << @intCast(index % 8));
}

inline fn clearBit(bitmap: []u8, index: u64) void {
    bitmap[index / 8] &= ~(@as(u8, 1) << @intCast(index % 8));
}

inline fn getBit(bitmap: []u8, index: u64) bool {
    return (bitmap[index / 8] & (@as(u8, 1) << @intCast(index % 8))) != 0;
}

fn freeRegion(bitmap: []u8, base: u64, length: u64, range: PhysRange) void {
    const total_pages = bitmap.len * 8;
    const start = (base - range.start) / PAGE_SIZE;
    // clamp end to total_pages so we never write past the bitmap
    const end_page = @min(
        (base + length - range.start + PAGE_SIZE - 1) / PAGE_SIZE,
        total_pages,
    );
    if (end_page <= start) return;
    for (start..end_page) |i| {
        clearBit(bitmap, i);
    }
}

fn markUsed(bitmap: []u8, base: u64, length: u64, range: PhysRange) void {
    const total_pages = bitmap.len * 8;
    const start = base / PAGE_SIZE - range.start / PAGE_SIZE;
    const end_page = @min(
        (base + length - range.start + PAGE_SIZE - 1) / PAGE_SIZE,
        total_pages,
    );
    if (end_page <= start) return;
    for (start..end_page) |i| {
        setBit(bitmap, i);
    }
}
pub fn getTotalMemory(self: *Self) u64 {
    return self.usable_memory;
}

pub fn getHighestAddress(self: *Self) u64 {
    return self.total_pages * PAGE_SIZE;
}
