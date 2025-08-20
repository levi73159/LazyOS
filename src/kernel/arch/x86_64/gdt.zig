const builtin = @import("builtin");
const log = @import("std").log.scoped(.gdt);

pub const Descriptor = @import("../globals.zig").Descriptor;
pub const Access = @import("../globals.zig").GDTAccess;
pub const Flags = @import("../globals.zig").GDTFlags;

pub const Entry = packed struct(u128) {
    limit_low: u16,
    base_low: u24,
    access: Access,
    limit_high: u4,
    flags: Flags,
    base_high: u40,
    __reserved: u32 = 0,

    pub fn init(limit: u20, base: u64, access: Access, flags: Flags) Entry {
        return Entry{
            .limit_low = @truncate(limit & 0xFFFF),
            .base_low = @truncate(base & 0xFFFFFF),
            .access = access,
            .limit_high = @truncate((limit >> 16) & 0xF),
            .flags = flags,
            .base_high = @truncate(base >> 24),
        };
    }

    pub fn nullDescriptor() Entry {
        return Entry{
            .limit_low = 0,
            .base_low = 0,
            .access = .{},
            .limit_high = 0,
            .flags = .{},
            .base_high = 0,
        };
    }
};

pub const Selector = enum(u16) {
    null = 0,
    kernel_code = 0x08,
    kernel_data = 0x10,
};

var gdt = [_]Entry{
    Entry.nullDescriptor(),

    // kernel 64 bit code segment
    Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = true,
        .descriptor_type = 1,
        .privilage_level = 0,
        .present = true,
    }, .{ .bit64 = true, .granularity = 1 }),

    // kernel 64 bit data segment
    Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = false,
        .descriptor_type = 1,
        .privilage_level = 0,
        .present = true,
    }, .{ .bit64 = true, .granularity = 1 }),
};

var descriptor = Descriptor{
    .limit = @sizeOf(Entry) * gdt.len - 1,
    .base = undefined,
};

pub fn init() !void {
    log.debug("Initializing GDT (64 bit)", .{});
    descriptor.base = @intFromPtr(&gdt[0]);
    try loadGDT();
}

fn loadGDT() !void {
    asm volatile (
        \\lgdt (%[desc])
        :
        : [desc] "r" (&descriptor),
        : "memory"
    );

    asm volatile (
        \\ljmp $0x08, $1f
        \\1:
    );
}
