const std = @import("std");
const vga = @import("vga.zig");
const io = @import("arch.zig").io;
const arch = @import("arch.zig");
const kb = @import("keyboard.zig");
const Screen = @import("Screen.zig");
const Color = @import("Color.zig");
const font = @import("fonts/Basic.zig");

const charmap = @import("fonts/charmap.zig");

const host = @import("std").log.scoped(.host);

var terminal_row: u16 = 0;
var terminal_column: u16 = 0;

var terminal_foreground: Color = Color.white();
var terminal_background: Color = Color.black();

var screen: *Screen = undefined;
var initialized: bool = false;

var echo_to_host: bool = false;

const pixels_per_scanline = 32;

pub fn init(_screen: *Screen) void {
    std.log.debug("Initializing console", .{});
    screen = _screen;
    initialized = true;
}

pub fn echoToHost(enabled: bool) void {
    echo_to_host = enabled;
}

pub fn clear() void {
    screen.clear(terminal_background);
    terminal_row = 0;
    terminal_column = 0;
    drawCursor();
}

pub fn drawChar(char_index: u8, x: u16, y: u16) void {
    const width = font.width;
    const height = font.height;
    if (width > 16) {
        @panic("Fonts wider than 16 pixels are illegal as of now! ");
    }
    const char_start: usize = char_index * @as(usize, height);

    const base_x: u16 = x * width;
    const base_y: u16 = y * height;
    var col: u4 = 0;
    var row: u8 = 0;
    while (row < height) : ({
        row += 1;
        col = 0;
    }) {
        while (col < width) : (col += 1) {
            const x_pos: u16 = base_x + col;
            const y_pos: u16 = base_y + row;
            const value = font.font_data[char_start + row] & @as(u16, 1) << (width - col);
            screen.setPixel(x_pos, y_pos, if (value == 0) terminal_background else terminal_foreground);
        }
    }
}

pub fn getTextWidth() u32 {
    return @divFloor(screen.width, font.width);
}

pub fn getTextHeight() u32 {
    return @divFloor(screen.height, font.height);
}

fn dbgc(c: u8) void {
    io.out(0xe9, c);
}

pub fn putchar(c: u8) void {
    if (!initialized) {
        dbgc(c);
        return;
    }
    if (echo_to_host) {
        dbgc(c);
    }
    defer drawCursor();
    if (c == '\n') {
        drawChar(' ', terminal_column, terminal_row); // remove the cursor
        terminal_column = 0;
        if (terminal_row < getTextHeight() - 1) {
            terminal_row += 1;
        }
    } else {
        drawChar(c, terminal_column, terminal_row);
        terminal_column += 1;
        if (terminal_column == getTextWidth()) {
            terminal_column = 0;
            if (terminal_row < getTextHeight() - 1) {
                terminal_row += 1;
            }
        }
    }

    if (terminal_row >= getTextHeight() - 1) {
        scroll();
        terminal_row -= 1;
    }
}

pub fn backspace() void {
    if (!initialized) {
        dbgc('\x7f');
        return;
    }
    if (terminal_column == 0) {
        return;
    }
    drawChar(' ', terminal_column, terminal_row);
    terminal_column -= 1;
    drawChar(' ', terminal_column, terminal_row);
    drawCursor();

    complete();
}

// should be an underline
pub fn drawCursor() void {
    drawChar('_', terminal_column, terminal_row);
}

pub fn complete() void {
    if (initialized) screen.swapBuffers();
}

pub fn write(data: []const u8) void {
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    var ib: usize = 0;

    while (i < data.len) {
        const c = data[i];
        if (!initialized) {
            dbgc(c);
            i += 1;
            continue;
        }

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
                    if (echo_to_host) {
                        dbgPrint("\x1b[{d}m", .{code});
                    }
                    setAnsiColor(code);
                }
            }
            i += 1;
            continue;
        }

        putchar(c);
        i += 1;
    }

    complete();
}

pub fn dbg(data: []const u8) void {
    for (data) |c| {
        io.outb(0xe9, c);
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer().print(fmt, args) catch {};
}

// print to both the terminal and the dbg port
pub fn printB(comptime fmt: []const u8, args: anytype) void {
    print(fmt, args);
    dbgPrint(fmt, args);
}

pub fn dbgPrint(comptime fmt: []const u8, args: anytype) void {
    dbgWriter().print(fmt, args) catch {};
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // white on red
    dbg("\x1b[97;41m");
    dbgPrint("!!! KERNEL PANIC !!!\n{s}\n", .{msg});

    dbgPrint("return address: {?x}\n", .{ret_addr});
    io.hlt();
}

pub fn writeFn(comptime func: fn ([]const u8) void) fn (
    w: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
) std.Io.Writer.Error!usize {
    const Inner = struct {
        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            _ = w;
            _ = splat; // if unused

            var total: usize = 0;

            for (data) |chunk| {
                func(chunk);
                total += chunk.len;
            }

            return total;
        }
    };

    return Inner.drain;
}

pub fn getVTable(comptime func: fn ([]const u8) void) std.Io.Writer.VTable {
    return .{
        .drain = writeFn(func),
        .sendFile = std.Io.Writer.unimplementedSendFile,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.defaultRebase,
    };
}

const ConVtable = getVTable(write);
const DbgVtable = getVTable(dbg);

var con_writer = std.Io.Writer{ .buffer = &.{}, .vtable = &ConVtable };
var dbg_writer = std.Io.Writer{ .buffer = &.{}, .vtable = &DbgVtable };

fn writer() *std.Io.Writer {
    return &con_writer;
}

fn dbgWriter() *std.Io.Writer {
    return &dbg_writer;
}

pub fn setFg(fg: vga.Color) void {
    terminal_foreground = fg.to32bitColor();
}

pub fn setBg(bg: vga.Color) void {
    terminal_background = bg.to32bitColor();
}

pub fn setFgBg(fg: vga.Color, bg: vga.Color) void {
    terminal_foreground = fg.to32bitColor();
    terminal_background = bg.to32bitColor();
}

fn setAnsiColor(code: u8) void {
    switch (code) {
        // Reset
        0 => setFgBg(.light_grey, .black),

        // Foreground colors 30–37
        30 => setFg(.black),
        31 => setFg(.red),
        32 => setFg(.green),
        33 => setFg(.brown),
        34 => setFg(.blue),
        35 => setFg(.magenta),
        36 => setFg(.cyan),
        37 => setFg(.light_grey),

        // Foreground bright colors 90–97
        90 => setFg(.dark_grey),
        91 => setFg(.light_red),
        92 => setFg(.light_green),
        93 => setFg(.yellow),
        94 => setFg(.light_blue),
        95 => setFg(.light_magenta),
        96 => setFg(.light_cyan),
        97 => setFg(.white),

        // Background colors 40–47
        40 => setBg(.black),
        41 => setBg(.red),
        42 => setBg(.green),
        43 => setBg(.brown),
        44 => setBg(.blue),
        45 => setBg(.magenta),
        46 => setBg(.cyan),
        47 => setBg(.light_grey),

        // Background bright colors 100–107
        100 => setBg(.dark_grey),
        101 => setBg(.light_red),
        102 => setBg(.light_green),
        103 => setBg(.yellow),
        104 => setBg(.light_blue),
        105 => setBg(.light_magenta),
        106 => setBg(.light_cyan),
        107 => setBg(.white),

        else => {},
    }
}

// Helper to get current fg/bg from terminal_color
fn terminal_fg() vga.Color {
    return .white;
}
fn terminal_bg() vga.Color {
    return .black;
}

// will end with a \n character
// echo will print what was typed
// include will include the \n
pub fn readline(buf: []u8, echo: bool) error{BufferOverflow}![]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const key = kb.getKey();
        if (!key.pressed) continue;

        if (key.getChar()) |c| {
            if (c == '\n') break;
            if (echo) {
                putchar(c);
                complete();
            }
            buf[i] = c;
            i += 1;
        }

        if (key.scancode == .backspace) {
            if (i > 0) {
                i -= 1;
                if (echo) {
                    backspace();
                }
            }
        }
    } else {
        return error.BufferOverflow;
    }
    return buf[0..i];
}

fn scroll() void {
    // Move each row up
    // var row: usize = 1;
    // while (row < vga.VGA_HEIGHT) : (row += 1) {
    //     var col: usize = 0;
    //     while (col < vga.VGA_WIDTH) : (col += 1) {
    //         const entry = vga.getEntry(row * vga.VGA_WIDTH + col);
    //         vga.writeEntry((row - 1) * vga.VGA_WIDTH + col, entry);
    //     }
    // }
    var row: u16 = 1;
    while (row < getTextHeight()) : (row += 1) {
        var col: u16 = 0;
        while (col < getTextWidth()) : (col += 1) {
            var pixelY: u32 = 0;
            while (pixelY < font.height) : (pixelY += 1) {
                var pixelX: u32 = 0;
                while (pixelX < font.width) : (pixelX += 1) {
                    const pixel = screen.getPixel(col * font.width + pixelX, row * font.height + pixelY);
                    screen.setPixel32(col * font.width + pixelX, (row - 1) * font.height + pixelY, pixel);
                }
            }
        }
    }

    // Clear last row
    var col: u16 = 0;
    while (col < getTextWidth()) : (col += 1) {
        drawChar(' ', col, @truncate(getTextHeight() - 1));
    }

    screen.swapBuffers();
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
