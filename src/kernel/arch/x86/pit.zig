//!implemt later
const std = @import("std");
const irq = @import("irq.zig");
const io = @import("../io.zig");

const InterruptFrame = @import("registers.zig").InterruptFrame;

const log = std.log.scoped(.pit);

const FREQ: u32 = 3579545 / 3;
const MIN_FREQ: u32 = 18;
const MAX_FREQ: u32 = 1_193_181;

const DATA_PORT = 0x40;
const COMMAND_PORT = 0x43;

pub var ticks: u64 = 0;

const CommandByte = packed struct(u8) {
    binary_mode: bool = false,
    operation_mode: OperationMode = .square_wave,
    access_mode: u2 = 3, // lobyte/hibyte (low first then high)
    chanel: u2 = 0,
};

const OperationMode = enum(u3) {
    rate_generator = 2,
    square_wave = 3,
    _,
};

const init_command = CommandByte{}; // square wave, lobyte/hibyte, channel 0

// amount of hz
pub fn init() void {
    log.debug("Initializing PIT", .{});
    irq.register(0, handler);
}

pub fn handler(_: *InterruptFrame) void {
    ticks +%= 1;
}
