const std = @import("std");
const Command = @import("Command.zig");
const console = @import("../console.zig");
const acpi = @import("../arch/acpi.zig");
const Shell = @import("../Shell.zig");

pub const commands = &[_]Command{ Command{
    .name = "echo",
    .help = "Prints to the screen",
    .handler = echo,
}, Command{
    .name = "clear",
    .help = "Clears the screen",
    .handler = clear,
}, Command{
    .name = "help",
    .help = "Prints this help message",
    .handler = help,
}, Command{
    .name = "restart",
    .help = "Restarts the system",
    .handler = restart,
}, Command{
    .name = "shutdown",
    .help = "Shuts down the system",
    .handler = shutdown,
}, Command{
    .name = "pwd",
    .help = "Prints the current working directory",
    .handler = pwd,
}, Command{
    .name = "cd",
    .help = "Changes the current working directory",
    .handler = cd,
}, Command{
    .name = "ls",
    .help = "Lists the contents of the current working directory",
    .handler = ls,
}, Command{
    .name = "cat",
    .help = "Prints the contents of a file",
    .handler = cat,
}, Command{
    .name = "gfx",
    .help = "Open the graphical gui",
    .handler = gfx,
} };

// *const fn (cwd: []const u8, args: []const []const u8) anyerror!void,

pub fn echo(_: *Shell, args: []const []const u8) anyerror!void {
    for (args) |arg| {
        console.print("{s} ", .{arg});
    }
    console.print("\n", .{});
}

pub fn clear(_: *Shell, _: []const []const u8) anyerror!void {
    console.clear();
}

pub fn help(_: *Shell, _: []const []const u8) anyerror!void {
    for (commands) |cmd| {
        console.print("{s}: {s}\n", .{ cmd.name, cmd.help });
    }
}

pub fn restart(_: *Shell, _: []const []const u8) anyerror!void {
    console.print("restarting...\n", .{});
    acpi.reboot();
    std.log.warn("reboot failed", .{});
}

pub fn shutdown(_: *Shell, _: []const []const u8) anyerror!void {
    console.print("shutting down...\n", .{});
    acpi.shutdown();
    std.log.warn("shutdown failed", .{});
}

pub fn pwd(s: *Shell, _: []const []const u8) anyerror!void {
    console.print("{s}\n", .{s.cwd});
}

pub fn cd(s: *Shell, args: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    const old = s.cwd;
    errdefer s.cwd = old;
    if (args.len == 0) {
        s.cwd = "/";
    } else {
        // combine the two using s.internal_cmd_buffer
        const cwd = try s.combinePath(args[0]);
        s.cwd = cwd;
    }

    _ = s.fs.?.stat(s.cwd) catch |err| {
        if (err == error.FileNotFound) {
            console.print("No such directory: {s}\n", .{s.cwd});
            s.cwd = old;
            return;
        } else {
            return err;
        }
    };

    s.allocator.free(old);
    s.cwd = try s.prettyCWD();
}

fn ls(s: *Shell, args: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    const path = if (args.len == 0) s.cwd else try s.combinePath(args[0]);

    const fs = s.fs.?;
    var it = try fs.it(path);
    while (try it.next()) |entry| {
        console.print("{s}\n", .{entry.name});
    }
}

fn cat(s: *Shell, args: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    if (args.len == 0) {
        console.print("Usage: cat <file>\n", .{});
        return;
    }
    const path = try s.combinePath(args[0]);

    const fs = s.fs.?;
    const file = try fs.open(path);
    defer file.close();

    var buf: [4096]u8 = undefined;
    const data = try file.readAll(&buf);
    console.write(data);
}

fn gfx(s: *Shell, _: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    const screen = @import("../graphics/Screen.zig").get();
    @import("../graphics/renderer.zig").drawLoop(screen);
}
