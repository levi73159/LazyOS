const gdt = @import("gdt.zig");

const log = @import("std").log.scoped(.idt);

pub const Gate = packed struct(u64) {
    base_low: u16 = 0,
    selector: u16 = @intFromEnum(gdt.Selector.kernel_code),
    __reserved: u8 = 0,
    flags: Flags = .{},
    base_high: u16 = 0,

    pub fn getOffset(self: Gate) u32 {
        return @as(u32, self.base_high) << 16 | @as(u32, self.base_low);
    }
};

pub const Flags = packed struct(u8) {
    gate_type: GateType = .interrupt_32bit,
    __reserved2: u1 = 0,
    privilage: u2 = 0,
    present: bool = false,
};

pub const GateType = enum(u4) {
    task_gate = 0x5,
    interrupt_16bit = 0x6,
    trap_16bit = 0x7,
    interrupt_32bit = 0xe,
    trap_32bit = 0xf,
    _,
};

pub const Descriptor = packed struct {
    limit: u16,
    base: usize,
};

fn loadIDT(desc: *const Descriptor) void {
    asm volatile ("lidt (%[idt])"
        :
        : [idt] "r" (desc),
        : "memory"
    );
}

pub var idt: [256]Gate = .{Gate{}} ** 256;
pub var descriptor: Descriptor = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = undefined };

pub fn init() void {
    log.debug("Initializing IDT", .{});
    descriptor.base = @intFromPtr(&idt);

    loadIDT(&descriptor);
}

pub fn enableGate(interrupt: u8) void {
    idt[interrupt].flags.present = true;
}

pub fn disableGate(interrupt: u8) void {
    idt[interrupt].flags.present = false;
}

pub fn setGate(interrupt: u16, base: usize, segment: gdt.Selector, flags: Flags) void {
    idt[interrupt].base_low = @truncate(base & 0xFFFF);
    idt[interrupt].base_high = @truncate(base >> 16);
    idt[interrupt].selector = @intFromEnum(segment);
    idt[interrupt].flags = flags;
}
