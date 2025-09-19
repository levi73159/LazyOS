const gdt = @import("gdt.zig");
const log = @import("std").log.scoped(.idt);

// a 64 bit interrupt gate descriptor
pub const Gate = packed struct(u128) {
    offset_low: u16 = 0,
    segment_selector: u16 = @intFromEnum(gdt.Selector.kernel_code),
    interrupt_stack: u3 = 0, // unused (interrupt stack table)
    __reserved1: u5 = 0,
    flags: Flags = .{},
    offset_high: u48 = 0,
    __reserved3: u32 = 0,

    pub fn getOffset(self: Gate) u64 {
        return @as(u64, self.offset_high) << 32 | @as(u64, self.offset_low);
    }
};

pub const Descriptor = packed struct {
    limit: u16,
    base: u64,
};

pub const GateType = enum(u4) {
    interrupt_64bit = 0xe,
    trap_64bit = 0xf,
    _,
};

pub const Flags = packed struct(u8) {
    gate_type: GateType = .interrupt_64bit,
    __reserved2: u1 = 0,
    privilege: u2 = 0,
    present: bool = false,
};

// default idt
pub var idt: [256]Gate = .{Gate{}} ** 256;

pub var descriptor = Descriptor{
    .limit = @sizeOf(Gate) * idt.len - 1,
    .base = undefined,
};

fn loadIDT(desc: *const Descriptor) void {
    asm volatile ("lidt (%[idt])"
        :
        : [idt] "r" (desc),
        : .{ .memory = true });
}

pub fn init() void {
    log.debug("Initializing IDT", .{});
    descriptor.base = @intFromPtr(&idt);
    loadIDT(&descriptor);
}

pub fn setGate(interrupt: u16, base: usize, segment: gdt.Selector, flags: Flags) void {
    const offset_low: u16 = @truncate(base & 0xFFFF); // lower 16 bits
    const offset_high: u48 = @truncate(base >> 16); // upper 48 bits
    idt[interrupt] = Gate{
        .offset_low = offset_low,
        .segment_selector = @intFromEnum(segment),
        .flags = flags,
        .offset_high = offset_high,
    };
}

pub fn enableGate(interrupt: u16) void {
    log.debug("Enabling interrupt {d}", .{interrupt});
    idt[interrupt].flags.present = true;
}

pub fn disableGate(interrupt: u16) void {
    log.debug("Disabling interrupt {d}", .{interrupt});
    idt[interrupt].flags.present = false;
}
