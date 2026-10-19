const TTY = @import("TTY.zig");
const root = @import("root");
const Process = root.proc.Process;
const File = root.fs.File;

var tty: TTY = .{};

const metadata: root.fs.FileSystem.Metadata = .{
    .device_id = root.fs.FileSystem.TTY_DEVICE_ID,
    .inode = 1,
    .kind = .character_device,
    .perm = 0o600,
    .uid = 0,
    .gid = 0,
    .link_count = 1,
    .size = 0,
    .block_size = 4096,
    .blocks = 0,
    .special_device_id = 0, // Placeholder until I assign device numbers.
    .accessed = .{ .seconds = 0, .nanoseconds = 0 },
    .modified = .{ .seconds = 0, .nanoseconds = 0 },
    .changed = .{ .seconds = 0, .nanoseconds = 0 },
};

pub const stdout: File = .{
    .private = &tty,
    .handle = .{
        .flags = .{ .writable = true, .readable = false, .seekable = false, .executable = false },
        .ctx = 0,
        .size = 0,
        .opened = true,
        .pos = 0,
        .metadata = metadata,
    },
    .f_ops = &TTY.vtable,
};

pub const stdin: File = .{
    .private = &tty,
    .handle = .{
        .flags = .{ .writable = false, .readable = true, .seekable = false, .executable = false },
        .ctx = 0,
        .size = 0,
        .opened = true,
        .pos = 0,
        .metadata = metadata,
    },
    .f_ops = &TTY.vtable,
};

pub const stderr: File = .{
    .private = &tty,
    .handle = .{
        .flags = .{ .writable = true, .readable = false, .seekable = false, .executable = false },
        .ctx = 0,
        .size = 0,
        .opened = true,
        .pos = 0,
        .metadata = metadata,
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
