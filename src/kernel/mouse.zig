const std = @import("std");
const io = @import("arch.zig").io;
const irq = @import("arch.zig").irq;
const Screen = @import("Screen.zig");

const InterruptFrame = @import("arch.zig").registers.InterruptFrame;

var mouse_x: u32 = 0;
var mouse_y: u32 = 0;

const MOUSE_PORT = 0x60;
const MOUSE_STATUS = 0x64;
const MOUSE_ABIT = 0x02;
const MOUSE_BBIT = 0x01;
const MOUSE_WRITE = 0xD4;
const MOUSE_F_BIT = 0x20;
const MOUSE_V_BIT = 0x08;

const ACK = 0xFA;
const RESEND = 0xFE;

var cycle: u8 = 0;
var mouse_bytes: [4]u8 = .{0} ** 4;

var window_height: u32 = 0;
var window_width: u32 = 0;

const DATA_INDEX = 0; // for mouse bytes
const X_MOVE_INDEX = 1; // for mouse bytes
const Y_MOVE_INDEX = 2; // for mouse bytes
const EXTRA_INDEX = 3; // for mouse bytes

pub fn x() u32 {
    return mouse_x;
}

pub fn y() u32 {
    return mouse_y;
}

pub fn handler(_: *InterruptFrame) void {
    const byte = read();
    mouse_bytes[cycle] = byte;
    cycle = (cycle + 1) % 3;
    if (cycle == 0) {
        const dx: i8 = @bitCast(mouse_bytes[X_MOVE_INDEX]);
        const dy: i8 = @bitCast(mouse_bytes[Y_MOVE_INDEX]);

        std.log.debug("dx: {d}, dy: {d}", .{ dx, dy });

        if (dx >= 0) {
            mouse_x += @intCast(dx);
        } else {
            mouse_x -|= @intCast(-dx);
        }

        if (dy >= 0) {
            mouse_y -|= @intCast(dy);
        } else {
            mouse_y += @intCast(-dy);
        }

        if (mouse_x > window_width) mouse_x = window_width - 1;
        if (mouse_y > window_height) mouse_y = window_height - 1;

        Screen.get().clear(.white());
        Screen.get().drawRect(mouse_x, mouse_y, 10, 10, .red());
        Screen.get().swapBuffers();
    }
}

pub fn init() !void {
    io.cli();
    defer io.sti();

    // enable the aux mouse device
    wait(1);
    io.outb(MOUSE_STATUS, 0xA8);

    // update controller command byte to enable IRQ1 + IRQ12
    wait(1);
    io.outb(0x64, 0x20);
    wait(0);
    const cmd = io.inb(0x60);
    const new_cmd = cmd | 0b11;
    wait(1);
    io.outb(0x64, 0x60);
    wait(1);
    io.outb(0x60, new_cmd);

    // tell mouse to use default settings
    try write(0xF6);

    // Enable the mouse
    try write(0xF4); // enable data reporting

    // enable interrupt for 12
    irq.register(12, handler);
    irq.enable(12);

    const s = Screen.get();
    window_height = s.height;
    window_width = s.width;
}

fn read() u8 {
    wait(0);
    return io.inb(MOUSE_PORT);
}

fn write(value: u8) !void {
    wait(1);
    io.outb(MOUSE_STATUS, 0xD4);
    wait(1);
    io.outb(MOUSE_PORT, value);

    const response = read();
    if (response == RESEND) {
        std.log.debug("Resending mouse command", .{});
        return write(value);
    } else if (response != ACK) {
        std.log.debug("Mouse command failed", .{});
        return error.CommandNotAcked;
    }
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
