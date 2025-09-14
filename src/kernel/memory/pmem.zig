const std = @import("std");
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;

pub const PhysRange = struct {
    start: usize,
    length: usize,
};

const PhysRangeListItem = struct {
    range: PhysRange,
    prev: ?*PhysRangeListItem,
    next: ?*PhysRangeListItem,
};
pub const PhysRangeList = DoublyLinkedList(PhysRangeListItem, .prev, .next);
const PhysicalMemoryManager = struct {
    const Self = @This();

    lock: SpinLock,
    memory_ranges: PhysRangeList, // all the ranges
    free_ranges: PhysRangeList,
    reserved_ranges: PhysRangeList,
    uncommitted_page_count: u32,
    commited_page_count: u32,
    free_page_count: u32,
    reserved_page_count: u32,

    pub fn init() Self {
        return .{};
    }
};

var mm: PhysicalMemoryManager = undefined;

pub fn init() void {
    mm = .init();
}

// Todo:
// coomit pages
// uncommit pages
// allocate pages (commited/or not)
// free pages

pub fn commitPages(count: u32) bool {
    _ = count;
}

pub fn uncommitPages(count: u32) void {
    _ = count;
}

pub fn allocatePages(count: u32, args: struct { commited: bool, zero: bool }) PhysRange {
    _ = count;
    _ = args;
}

pub fn freePages(range: PhysRange) void {
    _ = range;
}
