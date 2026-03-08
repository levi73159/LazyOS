const std = @import("std");
const bootinfo = @import("../arch/bootinfo.zig");
const Alignment = std.mem.Alignment;

const log = std.log.scoped(.pmem);

var bitmap: []u8 = undefined; // use a bitmap allocator to track free pages
const PAGE_SIZE = 4096;

var total_pages: u64 = 0;
var last_used_index: u64 = 0;
var usable_memory: u64 = 0;

pub fn init(mmap: []*bootinfo.MemoryMapEntry, hddm_offset: u64) void {
    log.debug("Initializing PMEM", .{});

    // find the highest address in memory to size the bitmap
    var highest: u64 = 0;
    for (mmap) |entry| {
        // only consider usable memory
        highest = @max(highest, entry.base + entry.length);
    }
    log.debug("Highest address: 0x{x}", .{highest});

    total_pages = highest / PAGE_SIZE;
    const bitmap_size = (total_pages + 7) / 8; // round up to nearest byte

    log.debug("Total pages: {d}", .{total_pages});
    // find usable memory large enough to hold bitmap itself
    for (mmap) |entry| {
        if (entry.type == .usable and entry.length >= bitmap_size) {
            bitmap = @as([*]u8, @ptrFromInt(entry.base + hddm_offset))[0..bitmap_size];
            @memset(bitmap, 0xFF);
            break;
        }
    }

    // now mark usable memory as free
    for (mmap) |entry| {
        if (entry.type == .usable) {
            freeRegion(entry.base, entry.length);
            usable_memory += entry.length;
        }
    }

    markUsed(@intFromPtr(bitmap.ptr) - hddm_offset, bitmap_size);
}

pub fn allocPage() !u64 {
    // finds a free bit starting from last_used_index
    var i = last_used_index;
    while (i < total_pages) : (i += 1) {
        if (!getBit(i)) {
            setBit(i); // mark as used
            last_used_index = i + 1;
            return i * PAGE_SIZE;
        }
    }

    return error.OutOfMemroy;
}

pub fn freePage(phys: u64) void {
    const index = phys / PAGE_SIZE;
    clearBit(index);
    if (index < last_used_index) last_used_index = index;
}

pub fn allocBlock(size: u64) !u64 {
    const pages_needed = (size + PAGE_SIZE - 1) / PAGE_SIZE; // round up to nearest page
    var pages_found: u32 = 0;

    var i = last_used_index;
    var start: ?u64 = null;
    while (i < total_pages) : (i += 1) {
        if (!getBit(i)) {
            if (start == null) {
                start = i;
            }
            pages_found += 1;
            if (pages_found == pages_needed) {
                for (0..pages_found) |j| {
                    setBit(start.? + j);
                }
                last_used_index = i + 1;
                return start.? * PAGE_SIZE;
            }
        } else {
            pages_found = 0;
            start = null;
        }
    }

    return error.OutOfMemroy;
}

pub fn freeBlock(phys: u64, size: u64) void {
    const index = phys / PAGE_SIZE;
    const pages_needed = (size + PAGE_SIZE - 1) / PAGE_SIZE; // round up to nearest page
    for (0..pages_needed) |i| {
        clearBit(index + i);
    }
    if (index < last_used_index) last_used_index = index;
}

inline fn setBit(index: u64) void {
    bitmap[index / 8] |= (@as(u8, 1) << @intCast(index % 8));
}

inline fn clearBit(index: u64) void {
    bitmap[index / 8] &= ~(@as(u8, 1) << @intCast(index % 8));
}

inline fn getBit(index: u64) bool {
    return (bitmap[index / 8] & (@as(u8, 1) << @intCast(index % 8))) != 0;
}

fn freeRegion(base: u64, length: u64) void {
    const start = base / PAGE_SIZE;
    const count = length / PAGE_SIZE;

    for (0..count) |i| {
        clearBit(start + i);
    }
}

fn markUsed(base: u64, length: u64) void {
    const start = base / PAGE_SIZE;
    const count = length / PAGE_SIZE;

    for (0..count) |i| {
        setBit(start + i);
    }
}

pub fn getTotalMemory() u64 {
    return usable_memory;
}

pub fn getHighestAddress() u64 {
    return total_pages * PAGE_SIZE;
}
