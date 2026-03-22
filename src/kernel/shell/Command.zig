const std = @import("std");
const Shell = @import("../Shell.zig");

name: []const u8,
help: []const u8,
handler: *const fn (s: *Shell, args: []const []const u8) anyerror!void,
