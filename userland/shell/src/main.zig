const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;

    std.log.info("Hello!", .{});

    std.debug.print("Please enter your name: ", .{});
    const file_stdin = std.Io.File.stdin();
    var reader_stdin = file_stdin.reader(init.io, &buf);
    const stdin = &reader_stdin.interface;

    const name = try stdin.takeDelimiterExclusive('\n');
    std.debug.print("Hello {s}\n", .{name});
}
