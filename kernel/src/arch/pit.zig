const std = @import("std");
const root = @import("root");
const arch = @import("arch.zig");
const io = arch.io;
const scheduler = root.proc.scheduler;

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

fn handler(frame: *Frame) void {
    _ = @atomicRmw(u64, &tick_count, .Add, 1, .monotonic);
    scheduler.schedule(frame);
}

fn sendCommandByte(command: CommandByte) void {
    io.outb(0x43, @bitCast(command));
}

pub fn ticks() u64 {
    return @atomicLoad(u64, &tick_count, .monotonic);
}

pub fn getFrequency() u32 {
    return frequency;
}

pub fn sleep(ms: u32) void {
    const ticks_to_wait = (@as(u64, ms) * frequency) / 1000;
    const end = @atomicLoad(u64, &tick_count, .monotonic) + ticks_to_wait;
    while (@atomicLoad(u64, &tick_count, .monotonic) < end) {
        asm volatile ("pause"); // hint to CPU we're spinning, no race concern
    }
}
