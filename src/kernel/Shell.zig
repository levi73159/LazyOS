const std = @import("std");
const FS = @import("fs/FileSystem.zig");
const console = @import("console.zig");
const Command = @import("shell/Command.zig");
const tty0 = @import("dev/tty0.zig");

const log = std.log.scoped(.shell);

const Self = @This();

const global_commands = @import("shell/commands.zig").commands;

cwd: []const u8,
fs: ?*FS,
prompt: []const u8 = "> ",
internal_cmd_buffer: [1024]u8 = undefined,

allocator: std.mem.Allocator,
commands: []Command = &[_]Command{},

pub fn init(allocator: std.mem.Allocator, fs: ?*FS) Self {
    return Self{
        .allocator = allocator,
        .cwd = "/",
        .fs = fs,
    };
}

pub fn run(self: *Self, input: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, input, ' ');
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(self.allocator);

    while (it.next()) |arg| {
        try args.append(self.allocator, arg);
    }

    const cmd = args.items[0];

    for (global_commands) |c| {
        if (std.mem.eql(u8, c.name, cmd)) {
            try c.handler(self, args.items[1..]);
            return;
        }
    }

    return error.CommandNotFound;
}

pub fn inputLoop(self: *Self) !void {
    var buf: [1024]u8 = undefined;
    self.cwd = try self.prettyCWD();
    defer self.allocator.free(self.cwd);

    while (true) {
        console.print("{s}{s}", .{ self.cwd, self.prompt });
        var n = tty0.get().waitAndRead(&buf);
        const input = if (buf[n - 1] != '\n') buf[0..n] else buf[0 .. n - 1];
        if (input.len == 0) continue;

        if (std.mem.eql(u8, input, "exit")) {
            console.print("Are you sure you wanna exit? (y/N)\n", .{});
            n = tty0.get().waitAndRead(&buf);
            if (n == 0) continue;
            if (buf[0] != 'y' and buf[0] != 'Y') {
                continue;
            }
            break;
        }

        self.run(input) catch |err| {
            console.print("Error: {s}\n", .{@errorName(err)});
        };
    }
}

pub fn prettyCWD(self: *Self) ![]const u8 {
    // convert the cwd into a pretty string, removing all of the .. and .  parts
    var parts = std.mem.tokenizeScalar(u8, self.cwd, '/');
    var pretty = std.ArrayList(u8).empty;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            // remove all the way to the next /
            _ = pretty.pop();
            while (pretty.items.len > 0 and pretty.items[pretty.items.len - 1] != '/') {
                _ = pretty.pop();
            }
            _ = pretty.pop();
            continue;
        } else if (std.mem.eql(u8, part, ".")) {
            continue;
        }
        try pretty.appendSlice(self.allocator, part);
        try pretty.append(self.allocator, '/');
    }
    // remove / at end
    if (pretty.items.len > 0 and pretty.items[pretty.items.len - 1] == '/') {
        _ = pretty.pop();
    }
    // insert / at beginning
    try pretty.insert(self.allocator, 0, '/');
    return pretty.items;
}

pub fn combinePath(self: *Self, path: []const u8) ![]const u8 {
    if (path.len == 0) return self.cwd;
    if (path[0] == '/') return path;

    return try std.fmt.bufPrint(&self.internal_cmd_buffer, "{s}/{s}", .{ self.cwd, path });
}
