const io = @import("arch/x86/io.zig");
const std = @import("std");
const fbcon = @import("FBCon/FBCon.zig");

const builtin = @import("builtin");
const testing = @import("std").testing;
const is_test = builtin.is_test;

const KernelBootInfo = @import("boot_info.zig").KernelBootInfo;

var con: fbcon = undefined;

fn assert(ok: bool) void {
    if (!ok) {
        unreachable;
    }
}

pub fn init(boot_info: *const KernelBootInfo) void {
    con.framebuffer_pointer = boot_info.video_mode_info.framebuffer_pointer;
    con.pixels_per_scanline = boot_info.video_mode_info.pixels_per_scanline;
    con.pixel_format = boot_info.video_mode_info.pixel_format;
    con.pixel_width = boot_info.video_mode_info.horizontal_resolution;
    con.pixel_height = boot_info.video_mode_info.vertical_resolution;
    con.setup();
}

pub fn write(data: []const u8) void {
    con.puts(data);
}

pub fn dbg(data: []const u8) void {
    for (data) |c| {
        io.outb(0xe9, c);
    }
}

pub fn panic(msg: []const u8) noreturn {
    write("PANIC: ");
    write(msg);
    write("\n");
    io.hlt();
}

pub fn logFn(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    _: anytype,
) void {
    write(format);
    write("\n");
}
