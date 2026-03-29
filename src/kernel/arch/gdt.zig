const builtin = @import("builtin");
const log = @import("std").log.scoped(.gdt);

pub const Descriptor = @import("descriptors.zig").Descriptor;
pub const Access = @import("descriptors.zig").GDTAccess;
pub const Flags = @import("descriptors.zig").GDTFlags;

pub const Entry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: Access,
    limit_high: u4,
    flags: Flags,
    base_high: u8,

    pub fn init(limit: u20, base: u32, access: Access, flags: Flags) Entry {
        return Entry{
            .limit_low = @truncate(limit & 0xFFFF),

            .base_low = @truncate(base & 0xFFFF),
            .base_mid = @truncate((base >> 16) & 0xFF),
            .base_high = @truncate((base >> 24) & 0xFF),

            .access = access,

            .limit_high = @truncate((limit >> 16) & 0xF),
            .flags = flags,
        };
    }

    pub fn nullDescriptor() Entry {
        return .{
            .limit_low = 0,
            .base_low = 0,
            .base_mid = 0,
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
    user_code = 0x18,
    user_data = 0x20,
};

pub const Segment = enum(u8) {
    kernel_code = 0x08,
    kernel_data = 0x10,
    user_code = 0x18 | 3,
    user_data = 0x20 | 3,
};

pub const GDT = packed struct {
    null_desc: Entry,
    kerenl_code: Entry,
    kerenl_data: Entry,
    user_code: Entry,
    user_data: Entry,
};

var gdt = GDT{
    .null_desc = Entry.nullDescriptor(),

    .kerenl_code = Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = true,
        .descriptor_type = 1,
        .privilage_level = 0,
        .present = true,
    }, .{ .bit64 = true, .granularity = 1 }),

    .kerenl_data = Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = false,
        .descriptor_type = 1,
        .privilage_level = 0,
        .present = true,
    }, .{ .bit64 = false, .granularity = 1 }),

    .user_code = Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = true,
        .descriptor_type = 1,
        .present = true,
        .privilage_level = 3,
    }, .{ .bit64 = true, .granularity = 1 }),

    .user_data = Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = false,
        .descriptor_type = 1,
        .present = true,
        .privilage_level = 3,
    }, .{ .bit64 = false, .granularity = 1 }),
};

var descriptor = Descriptor{
    .limit = @sizeOf(@TypeOf(gdt)) - 1,
    .base = undefined,
};

pub fn init() !void {
    log.debug("Initializing GDT (64 bit)", .{});
    descriptor.base = @intFromPtr(&gdt);

    try loadGDT();
}

pub extern fn asm_loadGDT(desc: *const Descriptor) void;

fn loadGDT() !void {
    @import("std").log.debug("Loading GDT", .{});
    asm_loadGDT(&descriptor);

    asm volatile (
        \\pushq $0x08
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        ::: .{ .rax = true });

    // reload data segment
    asm volatile (
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
    );

    if (builtin.mode == .Debug) {
        // quick sanity check on ds and es
        var ds: u16 = undefined;
        var es: u16 = undefined;
        asm volatile ("mov %%ds, %[ds]\nmov %%es, %[es]"
            : [ds] "=r" (ds),
              [es] "=r" (es),
        );
        if (ds != 0x10 or es != 0x10) {
            return error.LoadFailed;
        }
    }
}
