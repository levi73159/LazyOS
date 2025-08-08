const io = @import("arch/x86_64/io.zig");
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

const WriteError = error{};
const ConWriter = std.io.Writer(void, WriteError, writefn);
const DbgWriter = std.io.Writer(void, WriteError, dbgWriteFn);

fn writefn(_: void, bytes: []const u8) WriteError!usize {
    write(bytes);
    return bytes.len;
}

fn dbgWriteFn(_: void, bytes: []const u8) WriteError!usize {
    dbg(bytes);
    return bytes.len;
}

fn writer() ConWriter {
    return ConWriter{ .context = {} };
}

fn dbgWriter() DbgWriter {
    return DbgWriter{ .context = {} };
}

pub fn dbg(data: []const u8) void {
    for (data) |c| {
        io.outb(0xe9, c);
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer().print(fmt, args) catch unreachable;
}

pub fn dbgPrint(comptime fmt: []const u8, args: anytype) void {
    dbgWriter().print(fmt, args) catch unreachable;
}

pub fn panic(msg: []const u8) noreturn {
    // print to the host console first
    std.log.scoped(.host).err("!!! KERNEL PANIC !!!", .{});
    std.log.scoped(.host).err("PANIC: {s}", .{msg});

    std.log.err("PANIC: {s}", .{msg});
    io.hlt();
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = comptime switch (level) {
        .debug => "\x1b[32m",
        .info => "\x1b[36m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };

    const reset = "\x1b[0m";
    const w = if (scope == .host or level == .debug) dbgWriter() else writer();

    const prefix = if (scope != .host and scope != .default and scope != .none)
        color ++ "[" ++ @tagName(scope) ++ "] " ++ comptime level.asText() ++ ": "
    else
        color ++ comptime level.asText() ++ ": ";

    w.writeAll(prefix) catch unreachable;
    w.print(format, args) catch unreachable;
    w.writeAll(reset ++ "\n") catch unreachable;
}
