const std = @import("std");
const mem = std.mem;
const mm = @import("mem.zig");
const uefi = std.os.uefi;

const builtin = @import("builtin");

const Self = @This();
const log = std.log.scoped(.vmm);

const Error = error{} || uefi.UnexpectedError || uefi.tables.BootServices.AllocatePagesError;

pub const PageSize = enum(u1) {
    @"4k",
    @"2m",
};

pub const MmapFlags = packed struct(u64) {
    present: bool = false,
    read_write: ReadWrite = .read_write,
    privilage: Privilege = .supervisor,
    write_through: bool = false,
    cache_disabled: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    page_size: PageSize = .@"4k",
    global: bool = false,
    _pad: u54 = 0,
    execution_disable: bool = false,

    pub const default = MmapFlags{ .present = true, .read_write = .read_write, .privilage = .supervisor };
};

pub const Pml4VirtualAddress = packed struct(u64) {
    offset: u12,
    pt_idx: u9,
    pd_idx: u9,
    pdp_idx: u9,
    pml4_idx: u9,
    __unused: u16,

    pub const zero = Pml4VirtualAddress{ .offset = 0, .pt_idx = 0, .pd_idx = 0, .pdp_idx = 0, .pml4_idx = 0, .__unused = 0 };

    pub fn from(vaddr: u64) Pml4VirtualAddress {
        return @bitCast(vaddr);
    }

    pub fn raw(self: Pml4VirtualAddress) u64 {
        return @bitCast(self);
    }
};

pub const VirtAddr = Pml4VirtualAddress; // use a pml4VirtualAddress
pub const PhysAddr = u64;

pub const ReadWrite = enum(u1) { read_only = 0, read_write = 1 };
pub const Privilege = enum(u1) { supervisor = 0, user = 1 };

pub const Address = union(enum) {
    virt: Pml4VirtualAddress,
    phys: u64,

    pub fn raw(self: Address) u64 {
        return switch (self) {
            .virt => @bitCast(self.virt),
            .phys => self.phys,
        };
    }
};

pub const PageMapping = extern struct {
    const Entry = packed struct(u64) {
        present: bool = false,
        read_write: ReadWrite = .read_write,
        privilage: Privilege = .supervisor,
        write_through: bool = false,
        cache_disabled: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        page_size: PageSize = .@"4k",
        global: bool = false,
        _pad: u3 = 0,
        addr: u36 = 0,
        _pad2: u15 = 0,
        execution_disable: bool = false,

        pub fn getAddr(self: *const Entry) u64 {
            return @as(u64, self.addr) << 12;
        }

        pub fn print(self: *const Entry, vaddr: *const Pml4VirtualAddress) void {
            log.info("Entry: 0x{x}\t->\t0x{x}\t=\t0x{x}", .{ vaddr.raw(), self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };

    const ENTIRES = @divExact(mm.ARCH_PAGE_SIZE, @sizeOf(Entry));
    mappings: [ENTIRES]Entry,

    pub fn print(self: *const PageMapping, level: u8) void {
        var vaddr = Pml4VirtualAddress.zero;
        self._print(level, &vaddr);
    }

    fn _print(self: *const PageMapping, level: u8, vaddr: *Pml4VirtualAddress) void {
        for (&self.mappings, 0..) |*entry, index| {
            if (!entry.present) continue;
            switch (level) {
                4 => vaddr.pml4_idx = @intCast(index),
                3 => vaddr.pdp_idx = @intCast(index),
                2 => vaddr.pd_idx = @intCast(index),
                1 => {
                    vaddr.pt_idx = @intCast(index);
                    entry.print(vaddr);
                    continue;
                },
                else => @panic("Invalid level"),
            }
            const next_level_mapping: *PageMapping = @ptrFromInt(entry.getAddr());
            next_level_mapping._print(level - 1, vaddr);
        }
    }
};

mapping: *PageMapping,
levels: u8 = 4,

pub fn init() Error!Self {
    const root_ptr = try mm.allocatePages(1);
    return .{
        .mapping = @ptrCast(root_ptr),
    };
}

pub fn mmap(self: *const Self, vaddr: VirtAddr, paddr: PhysAddr, flags: MmapFlags) Error!void {
    const phys = mem.alignBackward(PhysAddr, paddr, mm.ARCH_PAGE_SIZE);

    const pdp_mapping = try getOrCreateLevel(self.mapping, vaddr.pml4_idx);
    const pd_mapping = try getOrCreateLevel(pdp_mapping, vaddr.pdp_idx);
    const pt_mapping = try getOrCreateLevel(pd_mapping, vaddr.pd_idx);
    if (flags.page_size == .@"2m") {
        // TODO: handle large pages here
        @panic("TODO: handle large pages here");
    }
    const entry = &pt_mapping.mappings[vaddr.pt_idx];

    writeEntry(entry, phys, flags);
}

fn getOrCreateLevel(mapping: *PageMapping, index: u9) Error!*PageMapping {
    const next_level: *PageMapping.Entry = &mapping.mappings[index];
    if (!next_level.present) {
        const page = try mm.allocatePages(1);
        writeEntry(next_level, @intFromPtr(page.ptr), MmapFlags{ .present = true, .read_write = .read_write });
        return @ptrCast(page);
    }
    const addr = next_level.getAddr();
    return @ptrFromInt(addr);
}

// TEST: make sure PageMapping.Entry have the correct format
fn writeEntry(entry: *PageMapping.Entry, paddr: PhysAddr, flags: MmapFlags) void {
    entry.* = @bitCast(paddr | @as(u64, @bitCast(flags)));
}

test writeEntry {
    const entry = PageMapping.Entry{ .addr = 0xC00CAFEB, .present = true };
    try std.testing.expectEqual(@as(u64, @bitCast(entry)), 0xC00CAFEB003);
}

test "get Entry addr" {
    const entry = PageMapping.Entry{ .addr = 0xC00CAFEB, .present = true };
    try std.testing.expectEqual(entry.getAddr(), 0xC00CAFEB000);
}

test getOrCreateLevel {
    var page_map = PageMapping{ .mappings = [_]PageMapping.Entry{.{}} ** PageMapping.ENTIRES };
    page_map.mappings[10] = PageMapping.Entry{ .addr = 0xC00CAFEB, .present = true };

    {
        const mapping = try getOrCreateLevel(&page_map, 10);
        try std.testing.expectEqual(@intFromPtr(mapping), 0xC00CAFEB000);
    }

    {
        const mapping = try getOrCreateLevel(&page_map, 11); // NOTE: does not exist, should create it
        const addr = page_map.mappings[11].getAddr();
        defer {
            // free the page
            const page_ptr: [*]align(mm.ARCH_PAGE_SIZE) u8 = @ptrFromInt(addr);
            const page = page_ptr[0..mm.ARCH_PAGE_SIZE]; // 1 page
            std.testing.allocator.free(page);
        }

        try std.testing.expectEqual(@intFromPtr(mapping), addr);
        try std.testing.expect(page_map.mappings[11].present);
    }
}

pub fn print(self: *const Self) void {
    log.info("Entry: vaddr\t->\tpaddr\t\t=\tFull Entry", .{});
    self.mapping.print(self.levels);
}
