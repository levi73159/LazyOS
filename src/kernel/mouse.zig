const std = @import("std");
const io = @import("arch.zig").io;

const InterruptFrame = @import("arch.zig").registers.InterruptFrame;

var mouse_x: u32 = 0;
var mouse_y: u32 = 0;

// #define MOUSE_PORT   0x60
// #define MOUSE_STATUS 0x64
// #define MOUSE_ABIT   0x02
// #define MOUSE_BBIT   0x01
// #define MOUSE_WRITE  0xD4
// #define MOUSE_F_BIT  0x20
// #define MOUSE_V_BIT  0x08

const MOUSE_PORT = 0x60;
const MOUSE_STATUS = 0x64;
const MOUSE_ABIT = 0x02;
const MOUSE_BBIT = 0x01;
const MOUSE_WRITE = 0xD4;
const MOUSE_F_BIT = 0x20;
const MOUSE_V_BIT = 0x08;

var cycle: u8 = 0;
var mouse_bytes: [3]u8 = .{0} * 3;

pub fn handler(frame: *InterruptFrame) void {
    const status: u8 = io.inb(MOUSE_STATUS);
    while (status & MOUSE_BBIT != 0) {
        const mouse_in = io.inb(MOUSE_PORT);
    }
}

fn read() u8 {
    wait(0);
    return io.inb(MOUSE_PORT);
}

fn wait(a_type: u8) void {
    var _time_out: u32 = 100000;
    if (a_type == 0) {
        while (_time_out > 0) : (_time_out -= 1) {
            if ((io.inb(0x64) & 1) == 1) {
                return;
            }
        }
    } else {
        while (_time_out > 0) : (_time_out -= 1) {
            if ((io.inb(0x64) & 2) == 0) {
                return;
            }
        }
    }
}
