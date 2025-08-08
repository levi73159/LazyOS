const std = @import("std");
const vga = @import("vga.zig");
const io = @import("arch.zig").io;

const host = @import("std").log.scoped(.host);

var terminal_row: u8 = 0;
var terminal_column: u8 = 0;

var terminal_color: u8 = vga.entryColor(.light_grey, .black);

pub fn clear() void {
    const entry = vga.entry(' ', terminal_color);

    var y: u8 = 0;
    while (y < vga.VGA_HEIGHT) : (y += 1) {
        var x: u8 = 0;
        while (x < vga.VGA_WIDTH) : (x += 1) {
            const index = @as(usize, y) * vga.VGA_WIDTH + x;
            vga.writeEntry(index, entry);
        }
    }

    terminal_row = 0;
    terminal_column = 0;

    io.setCursor(0, 0, vga.VGA_WIDTH);
}

pub fn putEntryAt(c: u8, color: u8, x: u8, y: u8) void {
    const index = @as(usize, y) * vga.VGA_WIDTH + x;
    const entry = vga.entry(c, color);

    vga.writeEntry(index, entry);
}

pub fn putchar(c: u8) void {
    if (c == '\n') {
        terminal_column = 0;
        if (terminal_row < vga.VGA_HEIGHT - 1) {
            terminal_row += 1;
        }
        return;
    }

    putEntryAt(c, terminal_color, terminal_column, terminal_row);
    terminal_column += 1;
    if (terminal_column == vga.VGA_WIDTH) {
        terminal_column = 0;
        if (terminal_row < vga.VGA_HEIGHT - 1) {
            terminal_row += 1;
        }
    }

    io.setCursor(terminal_column, terminal_row, vga.VGA_WIDTH);
}

pub fn write(data: []const u8) void {
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    var ib: usize = 0;

    while (i < data.len) {
        const c = data[i];

        if (c == '\x1b' and i + 1 < data.len and data[i + 1] == '[') {
            // We have an escape sequence starting: \x1b[
            i += 2;
            var num: u8 = 0;
            while (true) {
                while (i < data.len and data[i] >= '0' and data[i] <= '9') {
                    num = num * 10 + (data[i] - '0');
                    i += 1;
                }
                buf[ib] = num;
                ib += 1;
                num = 0;
                if (i < data.len and data[i] == ';') {
                    if (ib == buf.len) {
                        @panic("Too many arguments in escape sequence");
                    }
                    i += 1;
                    continue;
                }
                break;
            }

            // Check for 'm' terminator (SGR sequence)
            if (i < data.len and data[i] == 'm') {
                for (buf[0..ib]) |code| {
                    setAnsiColor(code);
                }
            }
            i += 1;
            continue;
        }

        putchar(c);
        i += 1;
    }
}

pub fn dbg(data: []const u8) void {
    for (data) |c| {
        io.outb(0xe9, c);
    }
}

pub fn panic(msg: []const u8) noreturn {
    // white on red
    write("\x1b[97;41m");
    write("!!! KERNEL PANIC !!!\n");
    write(msg);

    dbg("\x1b[97;41m");
    dbg("!!! KERNEL PANIC !!!\n");
    dbg(msg);
    dbg("\x1b[0m\n");
    io.hlt();
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

pub fn setColor(color: vga.Color) void {
    terminal_color = vga.entryColor(color, vga.Color.black);
}

pub fn setFgBg(fg: vga.Color, bg: vga.Color) void {
    terminal_color = vga.entryColor(fg, bg);
}

fn setAnsiColor(code: u8) void {
    switch (code) {
        // Reset
        0 => setFgBg(.light_grey, .black),

        // Foreground colors 30–37
        30 => setFgBg(.black, terminal_bg()),
        31 => setFgBg(.red, terminal_bg()),
        32 => setFgBg(.green, terminal_bg()),
        33 => setFgBg(.brown, terminal_bg()),
        34 => setFgBg(.blue, terminal_bg()),
        35 => setFgBg(.magenta, terminal_bg()),
        36 => setFgBg(.cyan, terminal_bg()),
        37 => setFgBg(.light_grey, terminal_bg()),

        // Foreground bright colors 90–97
        90 => setFgBg(.dark_grey, terminal_bg()),
        91 => setFgBg(.light_red, terminal_bg()),
        92 => setFgBg(.light_green, terminal_bg()),
        93 => setFgBg(.yellow, terminal_bg()),
        94 => setFgBg(.light_blue, terminal_bg()),
        95 => setFgBg(.light_magenta, terminal_bg()),
        96 => setFgBg(.light_cyan, terminal_bg()),
        97 => setFgBg(.white, terminal_bg()),

        // Background colors 40–47
        40 => setFgBg(terminal_fg(), .black),
        41 => setFgBg(terminal_fg(), .red),
        42 => setFgBg(terminal_fg(), .green),
        43 => setFgBg(terminal_fg(), .brown),
        44 => setFgBg(terminal_fg(), .blue),
        45 => setFgBg(terminal_fg(), .magenta),
        46 => setFgBg(terminal_fg(), .cyan),
        47 => setFgBg(terminal_fg(), .light_grey),

        // Background bright colors 100–107
        100 => setFgBg(terminal_fg(), .dark_grey),
        101 => setFgBg(terminal_fg(), .light_red),
        102 => setFgBg(terminal_fg(), .light_green),
        103 => setFgBg(terminal_fg(), .yellow),
        104 => setFgBg(terminal_fg(), .light_blue),
        105 => setFgBg(terminal_fg(), .light_magenta),
        106 => setFgBg(terminal_fg(), .light_cyan),
        107 => setFgBg(terminal_fg(), .white),

        else => {},
    }
}

// Helper to get current fg/bg from terminal_color
fn terminal_fg() vga.Color {
    return @enumFromInt(terminal_color & 0x0F);
}
fn terminal_bg() vga.Color {
    return @enumFromInt((terminal_color >> 4) & 0x0F);
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
