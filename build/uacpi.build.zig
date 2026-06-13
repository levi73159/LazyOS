const std = @import("std");
const exit = std.process.exit;

pub fn link(b: *std.Build, mod: *std.Build.Module) void {
    const path = "vendor/uACPI/source/";
    const dir = b.build_root.handle.openDir(b.graph.io, path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open {s}: {s}", .{ path, @errorName(err) });
        exit(1);
    };
    defer dir.close(b.graph.io);

    var walker = dir.walk(b.allocator) catch |err| {
        std.log.err("Failed to walk {s}: {s}", .{ path, @errorName(err) });
        exit(1);
    };
    defer walker.deinit();

    while (walker.next(b.graph.io) catch |err| @panic(@errorName(err))) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".c")) {
            mod.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ path, entry.path })), .flags = &.{} });
        }
    }
}
