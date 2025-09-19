const std = @import("std");
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;
const SpinLock = @import("../sync.zig").SpinLock;
const Constants = @import("constants.zig");

const arch = @import("../arch.zig");

const log = std.log.scoped(.pmen);

pub const PhysRange = struct {
    start: usize,
    length: usize,
    type: arch.Multiboot.MemoryType,
};

const PhysRangeListItem = struct {
    range: PhysRange,
    prev: ?*PhysRangeListItem = null,
    next: ?*PhysRangeListItem = null,
};
pub const PhysRangeList = DoublyLinkedList(PhysRangeListItem, .prev, .next);
const PhysicalMemoryManager = struct {
    const Self = @This();

    spinlock: SpinLock,
    memory_ranges: PhysRangeList, // all the ranges
    free_ranges: PhysRangeList,
    reserved_ranges: PhysRangeList,
    uncommitted_page_count: u32,
    commited_page_count: u32,
    free_page_count: u32,
    reserved_page_count: u32,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .spinlock = .create(),
            .memory_ranges = .{},
            .free_ranges = .{},
            .reserved_ranges = .{},
            .uncommitted_page_count = 0,
            .commited_page_count = 0,
            .free_page_count = 0,
            .reserved_page_count = 0,
            .allocator = allocator,
        };
    }
};

var mm: PhysicalMemoryManager = undefined;
var mmmap_entries: []arch.Multiboot.MemoryMapEntry = undefined;

pub fn init(mb: *arch.MultibootInfo, allocator: std.mem.Allocator) void {
    mm = .init(allocator);
    mm.spinlock.lock();
    defer mm.spinlock.unlock();

    reclaimFreeableMemory(mb);
    initRanges() catch |err| {
        log.err("Failed to init ranges: {s}", .{@errorName(err)});
    };

    mm.uncommitted_page_count = mm.free_page_count;
}

fn reclaimFreeableMemory(mb: *arch.MultibootInfo) void {
    log.debug("bootinfo ptr: {*}", .{mb});
    mmmap_entries = mb.getMemoryMap();

    for (mmmap_entries) |*entry| {
        log.debug("before: {any}", .{entry});
        if (entry.type != .acpi_reclaimable) continue;
        entry.type = .available;
        log.debug("after: {any}", .{entry});
    }
}

fn initRanges() !void {
    log.info("Initializing memory ranges...", .{});
    log.debug("ARCH PAGE SIZE: {d}", .{Constants.ARCH_PAGE_SIZE});
    for (mmmap_entries) |entry| {
        const range = PhysRange{ .start = @intCast(entry.addr), .length = @intCast(entry.size), .type = entry.type };
        const list_item = try mm.allocator.create(PhysRangeListItem);
        list_item.* = .{ .range = range };
        mm.memory_ranges.append(list_item);
        if (entry.type == .available) {
            const item = try mm.allocator.create(PhysRangeListItem);
            item.* = .{ .range = range };
            mm.free_ranges.append(item);
            log.debug("added free range: {any}", .{range});
            mm.free_page_count += try std.math.divCeil(u32, @intCast(entry.size), Constants.ARCH_PAGE_SIZE);
        } else if (entry.type == .reserved) {
            const item = try mm.allocator.create(PhysRangeListItem);
            item.* = .{ .range = range };
            mm.reserved_ranges.append(item);
            log.debug("added reserved range: {any}", .{range});
            mm.reserved_page_count += try std.math.divCeil(u32, @intCast(entry.size), Constants.ARCH_PAGE_SIZE);
        }
    }

    log.debug("page counts, reserved: {d} | free: {d}", .{ mm.reserved_page_count, mm.free_page_count });
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
