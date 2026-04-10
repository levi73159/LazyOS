const std = @import("std");
const console = @import("../console.zig");
const keyboard = @import("../keyboard.zig");
const io = @import("../arch/io.zig");
const scheduler = @import("../scheduler.zig");
const File = @import("File.zig");
const linux = std.os.linux;
const T = linux.T;

const log = std.log.scoped(.tty);

const BUF_SIZE = 4096;

const Self = @This();

input_buf: [BUF_SIZE]u8 = undefined,
read_pos: usize = 0,
write_pos: usize = 0,
line_ready: bool = false,
col: usize = 0,
termios: linux.termios = .{
    .iflag = .{ .ICRNL = true, .IXON = true, .IUTF8 = true },
    .oflag = .{ .OPOST = true, .OCRNL = true },
    .cflag = .{ .CSIZE = .CS8, .CREAD = true, .HUPCL = true },
    .lflag = .{
        .ISIG = false, // We don't have signals yet
        .ICANON = true,
        .ECHO = true,
        .ECHOE = true,
        .ECHOK = true,
        .IEXTEN = true,
        .ECHOCTL = true,
        .ECHOKE = true,
    },
    .line = 0,
    .cc = .{
        3, // VINTR    Ctrl+C
        28, // VQUIT    Ctrl+\
        127, // VERASE   Backspace/DEL
        21, // VKILL    Ctrl+U
        4, // VEOF     Ctrl+D
        0, // VTIME
        1, // VMIN
        0, // VSWTC
        17, // VSTART   Ctrl+Q
        19, // VSTOP    Ctrl+S
        26, // VSUSP    Ctrl+Z
        0, // VEOL
        18, // VREPRINT Ctrl+R
        15, // VDISCARD Ctrl+O
        23, // VWERASE  Ctrl+W
        22, // VLNEXT   Ctrl+V
        0, // VEOL2
        0,
        0,
    },
    .ispeed = 0,
    .ospeed = 0,
},
winsize: linux.winsize = .{
    .row = 25,
    .col = 80,
    .xpixel = 0,
    .ypixel = 0,
},

pub fn hasData(self: *Self) bool {
    return self.line_ready or self.read_pos != self.write_pos;
}

pub fn putChar(self: *Self, c: u8) void {
    if (self.termios.lflag.ISIG) {
        log.err("Signals not supported", .{});
    }

    if (self.termios.lflag.ICANON) {
        self.procesICANON(c);
    } else {
        // raw mode — no line discipline, every char is available immediately
        if (self.write_pos < BUF_SIZE - 1) {
            self.input_buf[self.write_pos] = c;
            self.write_pos += 1;

            if (self.termios.lflag.ECHO) {
                console.putchar(c);
                console.complete();
            }

            // in raw mode, VMIN/VTIME control when read returns
            // for now wake immediately
            self.line_ready = true;
            scheduler.wakeInputWaiters();
        }
    }
}

fn procesICANON(self: *Self, c: u8) void {
    const cc = self.termios.cc;

    if (c == cc[linux.V.ERASE] or c == 8) {
        if (self.write_pos > 0) {
            self.write_pos -= 1;
            if (self.termios.lflag.ECHO and self.termios.lflag.ECHOE) {
                console.backspace();
            }
        }
        return;
    }

    if (c == cc[linux.V.KILL]) {
        if (self.termios.lflag.ECHO and self.termios.lflag.ECHOK) {
            // erase all characters written
            while (self.write_pos > 0) {
                self.write_pos -= 1;
                console.backspace();
            }
        } else {
            self.write_pos = 0;
        }
        if (self.termios.lflag.ECHO and self.termios.lflag.ECHOK) {
            console.putchar('\n');
            console.complete();
        }
        return;
    }

    if (c == cc[linux.V.EOF]) {
        self.line_ready = true;
        scheduler.wakeInputWaiters();
        return;
    }

    const actual_c = if (self.termios.iflag.ICRNL and c == '\r') '\n' else c;
    const is_eol = actual_c == '\n' or actual_c == cc[linux.V.EOL] or actual_c == cc[linux.V.EOL2];

    if (self.write_pos < BUF_SIZE - 1) {
        self.input_buf[self.write_pos] = actual_c;
        self.write_pos += 1;

        if (self.termios.lflag.ECHO) {
            if (actual_c < 32 and actual_c != '\n' and self.termios.lflag.ECHOCTL) {
                console.putchar('^');
                console.putchar('@' + actual_c);
            } else {
                console.putchar(actual_c);
            }
            console.complete();
        }

        if (is_eol or actual_c == '\n') {
            self.line_ready = true;
            scheduler.wakeInputWaiters();
        }
    }
}

pub fn read(self: *Self, buf: []u8) usize {
    if (!self.line_ready) return 0; // nothing to read
    var i: usize = 0;
    while (i < buf.len and self.read_pos < self.write_pos) {
        buf[i] = self.input_buf[self.read_pos];
        self.read_pos += 1;
        i += 1;
        if (buf[i - 1] == '\n') break;
    }
    if (self.read_pos >= self.write_pos) {
        self.read_pos = 0;
        self.write_pos = 0;
        self.line_ready = false;
    }
    return i;
}

pub fn processOutput(self: *Self, c: u8) void {
    // OPOST — if not set, raw output, no processing
    if (!self.termios.oflag.OPOST) {
        console.putchar(c);
        return;
    }

    switch (c) {
        '\n' => {
            // ONLCR — translate NL to CR+NL
            if (self.termios.oflag.ONLCR) {
                console.putchar('\r');
                console.putchar('\n');
            }
            // ONLRET — NL performs CR function
            else if (self.termios.oflag.ONLRET) {
                console.putchar('\n');
            } else {
                console.putchar('\n');
            }
        },
        '\r' => {
            // OCRNL — translate CR to NL
            if (self.termios.oflag.OCRNL) {
                processOutput(self, '\n');
                return;
            }
            // ONOCR — don't output CR at column 0
            if (self.termios.oflag.ONOCR) {
                // TODO: track column position
                console.putchar('\r');
            } else {
                console.putchar('\r');
            }
        },
        '\t' => {
            // TABDLY — tab delay / expansion
            // XTABS / TAB3 — expand tabs to spaces
            if (@as(u32, @bitCast(self.termios.oflag)) & 0x1800 == 0x1800) {
                // expand tab to spaces up to next 8-column boundary
                const spaces = 8 - (self.col % 8);
                var i: usize = 0;
                while (i < spaces) : (i += 1) {
                    console.putchar(' ');
                    self.col += 1;
                }
                return;
            }
            console.putchar('\t');
        },
        '\x08' => { // backspace
            console.putchar('\x08');
            if (self.col > 0) self.col -= 1;
        },
        else => {
            console.putchar(c);
        },
    }

    // track column position for ONOCR and tab expansion
    switch (c) {
        '\n', '\r' => self.col = 0,
        '\x08' => if (self.col > 0) {
            self.col -= 1;
        },
        else => self.col += 1,
    }
}

pub fn ttyRead(file: *File, buf: []u8) File.Error!usize {
    const tty: *Self = @ptrCast(file.private);
    return tty.read(buf);
}

pub fn ttyWrite(file: *File, buf: []const u8) File.Error!usize {
    const tty: *Self = @ptrCast(file.private);
    for (buf) |c| {
        tty.processOutput(c);
    }
    return buf.len;
}

pub fn ttyClose(file: *File) void {
    const tty: *Self = @ptrCast(file.private);
    tty.line_ready = false;
    tty.write_pos = 0;
    tty.read_pos = 0;
    tty.col = 0;
}

pub fn ttyIoCtl(file: *File, request: u32, arg: usize) File.Error!i64 {
    const tty: *Self = @ptrCast(file.private);
    switch (request) {
        T.CGETS => {
            const ptr: *linux.termios = @ptrFromInt(arg);
            ptr.* = tty.termios;
            return 0;
        },
        T.CSETS => {
            const ptr: *linux.termios = @ptrFromInt(arg);
            tty.termios = ptr.*;
            return 0;
        },
        T.IOCGWINSZ => {
            const ptr: *linux.winsize = @ptrFromInt(arg);
            ptr.* = tty.winsize;
            return 0;
        },
        T.IOCSWINSZ => {
            const ptr: *linux.winsize = @ptrFromInt(arg);
            tty.winsize = ptr.*;
            return 0;
        },
        T.IOCGPGRP => {
            const ptr: *u32 = @ptrFromInt(arg);
            ptr.* = 1; // WARN: fake process group
            return 0;
        },
        else => {
            log.warn("TTY: Unsupported ioctl: {x}", .{request});
            return -25; // ENOTTY
        },
    }
}

pub const vtable = File.FileOps{
    .read = ttyRead,
    .write = ttyWrite,
    .ioctl = ttyIoCtl,
    .seek = null,
    .close = ttyClose,
};
