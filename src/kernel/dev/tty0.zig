const TTY = @import("TTY.zig");
const root = @import("root");
const Process = root.proc.Process;
const File = root.fs.File;

var tty: TTY = .{};

const stdout: File = .{
    .private = &tty,
    .handle = .{
        .flags = .{ .writable = true, .readable = false, .seekable = false, .executable = false },
        .ctx = 0,
        .size = 0,
        .opened = false,
        .pos = 0,
    },
    .f_ops = &TTY.vtable,
};

const stdin: File = .{
    .private = &tty,
    .handle = .{
        .flags = .{ .writable = false, .readable = true, .seekable = false, .executable = false },
        .ctx = 0,
        .size = 0,
        .opened = true,
        .pos = 0,
    },
    .f_ops = &TTY.vtable,
};

const stderr: File = .{
    .private = &tty,
    .handle = .{
        .flags = .{ .writable = true, .readable = false, .seekable = false, .executable = false },
        .ctx = 0,
        .size = 0,
        .opened = true,
        .pos = 0,
    },
    .f_ops = &TTY.vtable,
};

pub fn fdInit(fdTable: *Process.FdTable) void {
    _ = fdTable.allocAndSet(stdin);
    _ = fdTable.allocAndSet(stdout);
    _ = fdTable.allocAndSet(stderr);
}

pub fn get() *TTY {
    return &tty;
}
