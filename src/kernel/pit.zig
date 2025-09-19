const std = @import("std");
const arch = @import("arch.zig");
const io = arch.io;

const Frame = arch.registers.InterruptFrame;

var tick_count: u64 = 0;
var frequency: u32 = 0;

const Mode = enum(u3) {
    rate_generator = 2,
    square_wave_generator = 3,
    _,
};

const CommandByte = packed struct(u8) {
    bcd: bool = false,
    mode: Mode = .rate_generator,
    lowbyte: bool = true,
    highbyte: bool = true,
    channel: u2 = 0,
};

// 100Hz for the best
pub fn init(freq: u32) void {
    frequency = freq;
    const divisor = 1193182 / frequency;

    sendCommandByte(.{}); // send the default command byte

    // send divisor low byte then high byte
    io.outb(0x40, @truncate(divisor & 0xFF));
    io.outb(0x40, @truncate(divisor >> 8));

    arch.irq.register(0, handler);
    arch.irq.enable(0);
}

fn handler(_: Frame) void {
    tick_count += 1;
}

fn sendCommandByte(command: CommandByte) void {
    io.outb(0x43, @bitCast(command));
}

pub fn ticks() u64 {
    return tick_count;
}

pub fn getFrequency() u32 {
    return frequency;
}

pub fn sleep(ms: u32) void {
    // PIT is at 100 Hz -> 1 tick = 10ms
    const ticks_per_ms = @as(f64, @floatFromInt(frequency)) / 1000.0; // = 0.1 ticks per ms
    const total_ticks: f64 = @as(f64, @floatFromInt(ms)) * ticks_per_ms;
    const ticks_to_wait: u64 = @intFromFloat(@trunc(total_ticks));

    const end = tick_count + ticks_to_wait;
    while (tick_count < end) {
        // busy-wait until enough ticks have passed
        asm volatile ("hlt"); // sleep CPU until next interrupt
    }
}
