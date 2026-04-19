const std = @import("std");
const root = @import("root");
const pit = root.pit;

pub const BLOCK_SIZE = 512;
pub const CACHE_BLOCKS = 64;

pub const CacheEntry = struct {
    lba: u32 = 0,
    valid: bool = false,
    last_used: u64 = 0,
    data: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE,
};

const Self = @This();

inactive: [CACHE_BLOCKS]CacheEntry = [_]CacheEntry{.{}} ** CACHE_BLOCKS,
active: [CACHE_BLOCKS]CacheEntry = [_]CacheEntry{.{}} ** CACHE_BLOCKS,

fn findIn(list: []CacheEntry, lba: u32) ?*CacheEntry {
    for (list) |*entry| {
        if (entry.valid and entry.lba == lba) return entry;
    }
    return null;
}

fn evictFrom(list: []CacheEntry) *CacheEntry {
    for (list) |*entry| {
        if (!entry.valid) return entry;
    }

    var oldest = &list[0];
    for (list[1..]) |*entry| {
        if (entry.last_used < oldest.last_used) oldest = entry;
    }
    oldest.valid = false;
    return oldest;
}

fn demoteOne(self: *Self) *CacheEntry {
    for (&self.active) |*entry| {
        if (!entry.valid) return entry;
    }

    var lru = &self.active[0];
    for (self.active[1..]) |*entry| {
        if (entry.last_used < lru.last_used) lru = entry;
    }

    const inactive_slot = evictFrom(&self.inactive);
    inactive_slot.* = lru.*;
    lru.valid = false;
    return lru;
}

pub fn read(self: *Self, lba: u32, buf: *[BLOCK_SIZE]u8, disk_reader: anytype) !void {
    const now = pit.ticks();

    if (findIn(&self.active, lba)) |entry| {
        entry.last_used = now;
        @memcpy(buf, &entry.data);
        return;
    }

    if (findIn(&self.inactive, lba)) |entry| {
        const saved_data = entry.data;
        entry.valid = false;

        const slot = self.demoteOne();
        slot.* = .{
            .lba = lba,
            .valid = true,
            .last_used = now,
            .data = saved_data,
        };
        @memcpy(buf, &slot.data);
        return;
    }

    const slot = evictFrom(&self.inactive);
    try disk_reader.read(lba, &slot.data);
    slot.lba = lba;
    slot.valid = true;
    slot.last_used = now;
    @memcpy(buf, &slot.data);
}

pub fn invalidate(self: *Self, lba: u32) void {
    if (findIn(&self.active, lba)) |e| e.valid = false;
    if (findIn(&self.inactive, lba)) |e| e.valid = false;
}
