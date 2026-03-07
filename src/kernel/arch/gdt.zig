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

const TSS = packed struct {
    _reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    _reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    _reserved2: u64 = 0,
    _reserved3: u16 = 0,
    iopb_offset: u16 = 0,
};

var tss: TSS align(16) = TSS{};
const tss_limit: u32 = @sizeOf(TSS) - 1;

pub const Selector = enum(u16) {
    null = 0,
    kernel_code = 0x08,
    kernel_data = 0x10,
    tss = 0x18,
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
    }, .{ .bit64 = false, .granularity = 1 }),
};

var descriptor = Descriptor{
    .limit = @sizeOf(@TypeOf(gdt)) - 1,
    .base = undefined,
};

pub fn init() !void {
    log.debug("Initializing GDT (64 bit)", .{});
    descriptor.base = @intFromPtr(&gdt[0]);

    try loadGDT();
}

pub extern fn asm_loadGDT(desc: *const Descriptor) void;

fn loadGDT() !void {
    @import("std").log.debug("Loading GDT", .{});
    asm_loadGDT(&descriptor);
    @import("std").log.debug("Loading GDT", .{});

    asm volatile (
        \\pushq $0x08
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        ::: .{ .rax = true });
    @import("std").log.debug("Loading GDT", .{});

    // reload data segment
    asm volatile (
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
    );
    @import("std").log.debug("Loading GDT", .{});

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
