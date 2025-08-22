const std = @import("std");
const io = @import("arch.zig").io;

const InterruptFrame = @import("arch.zig").registers.InterruptFrame;

var mouse_x: u32 = 0;
var mouse_y: u32 = 0;

var cycle: u8 = 0;

pub fn handler(frame: *InterruptFrame) void {}

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
