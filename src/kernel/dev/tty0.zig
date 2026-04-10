const TTY = @import("../fs/TTY.zig");
const Process = @import("../Process.zig");
const File = @import("../fs/File.zig");

var tty: TTY = .{};
var file: File = .{ .f_ops = &TTY.vtable, .private = &tty, .handle = .{
    .size = 0,
    .pos = 0,
    .opened = true,
    .ctx = 0,
} };

pub fn fdInit(fdTable: Process.FdTable) void {
    fdTable[0] = &file; // STDIN
    fdTable[1] = &file; // STDOUT
    fdTable[2] = &file; // STDERR
}
