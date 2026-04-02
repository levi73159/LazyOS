const std = @import("std");
const builtin = @import("builtin");
const log = @import("std").log.scoped(.gdt);

const boot = @import("../boot.zig");

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

// A entry with a 64 bit base address (used for TSS)
pub const Entry64 = packed struct(u128) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: Access,
    limit_high: u4,
    flags: Flags,
    base_high: u8,
    base_upper: u32, // bits: 63:32
    __reserved: u32 = 0,

    pub fn init(limit: u20, base: u64, access: Access, flags: Flags) Entry64 {
        return Entry64{
            .limit_low = @truncate(limit & 0xFFFF),
            .base_low = @truncate(base & 0xFFFF),
            .base_mid = @truncate((base >> 16) & 0xFF),
            .base_high = @truncate((base >> 24) & 0xFF),
            .base_upper = @truncate((base >> 32) & 0xFFFFFFFF),
            .access = access,
            .limit_high = @truncate((limit >> 16) & 0xF),
            .flags = flags,
        };
    }
};

pub const TSS = packed struct {
    __reserved: u32 = 0,
    rsp0: u64,
    rsp1: u64,
    rsp2: u64,
    __reserved2: u64 = 0,
    ist1: u64,
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    __reserved3: u64 = 0,
    __reserved4: u16 = 0,
    iopb_offset: u16,
};

comptime {
    std.debug.assert(@offsetOf(TSS, "rsp0") == 0x04);
    std.debug.assert(@offsetOf(TSS, "ist1") == 0x24);
    std.debug.assert(@offsetOf(TSS, "iopb_offset") == 0x66);
}

pub const Segment = enum(u8) {
    kernel_code = @intFromEnum(Selector.kernel_code),
    kernel_data = @intFromEnum(Selector.kernel_data),
    user_code = @intFromEnum(Selector.user_code) | 3,
    user_data = @intFromEnum(Selector.user_data) | 3, // or 3 for ring 3
};

pub const GDT = packed struct {
    null_desc: Entry, // 0x0
    kerenl_code: Entry, // 0x8
    kerenl_data: Entry, // 0x10
    user_data: Entry, // 0x18
    user_code: Entry, // 0x20
    tss_desc: Entry64, // 0x28
};

pub const Selector = enum(u16) {
    null = @offsetOf(GDT, "null_desc"),
    kernel_code = @offsetOf(GDT, "kerenl_code"),
    kernel_data = @offsetOf(GDT, "kerenl_data"),
    user_code = @offsetOf(GDT, "user_code"),
    user_data = @offsetOf(GDT, "user_data"),
    tss = @offsetOf(GDT, "tss_desc"),
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

    .tss_desc = undefined, // loaded at runtime
};

pub var tss = std.mem.zeroes(TSS);

var descriptor = Descriptor{
    .limit = @sizeOf(@TypeOf(gdt)) - 1,
    .base = undefined,
};

pub fn init() !void {
    log.debug("Initializing GDT (64 bit)", .{});
    descriptor.base = @intFromPtr(&gdt);

    tss.rsp0 = @intFromPtr(&boot.kernel_stack) + boot.KERNEL_STACK_SIZE;
    gdt.tss_desc = Entry64.init(@sizeOf(TSS) - 1, @intFromPtr(&tss), .{
        .accessed = true,
        .read_write = 0,
        .direction_conforming = 0,
        .executable = true,
        .descriptor_type = 0,
        .present = true,
    }, .{});

    try loadGDT();

    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (@intFromEnum(Selector.tss)),
    );
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
