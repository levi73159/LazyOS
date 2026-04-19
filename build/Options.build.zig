const std = @import("std");

const Self = @This();

debug_int: bool,
stal: bool,
display: []const u8,
optimize: std.builtin.OptimizeMode,

pub fn parse(b: *std.Build) Self {
    return .{
        .debug_int = b.option(bool, "int", "turn on interrupt logging") orelse false,
        .stal = b.option(bool, "stal", "no reboot/shutdown") orelse false,
        .display = b.option([]const u8, "display", "qemu display") orelse "sdl,gl=on",
        .optimize = b.option(std.builtin.OptimizeMode, "optimize", "set the optimization mode") orelse switch (b.release_mode) {
            .off => std.builtin.OptimizeMode.ReleaseSafe,
            .any => std.builtin.OptimizeMode.ReleaseSafe,
            .fast => std.builtin.OptimizeMode.ReleaseFast,
            .safe => std.builtin.OptimizeMode.ReleaseSafe,
            .small => std.builtin.OptimizeMode.ReleaseSmall,
        },
    };
}
