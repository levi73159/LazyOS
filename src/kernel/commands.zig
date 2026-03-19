const std = @import("std");
const console = @import("console.zig");
const arch = @import("arch.zig");
const io = arch.io;
const heap = @import("memory/heap.zig");

pub const Command = struct {
    name: []const u8,
    help: []const u8,
    handler: *const fn (line: []const u8) anyerror!void,
};

pub const commands: []const Command = &[_]Command{
    Command{
        .name = "help",
        .help = "Prints this help message",
        .handler = help,
    },
    Command{
        .name = "hlt",
        .help = "Halt the system",
        .handler = hlt,
    },
    Command{
        .name = "echo",
        .help = "Prints to the screen",
        .handler = echo,
    },
    Command{
        .name = "ticks",
        .help = "Prints the number of ticks",
        .handler = getTicks,
    },
    Command{
        .name = "clear",
        .help = "Clears the screen",
        .handler = clear,
    },
    Command{
        .name = "shutdown",
        .help = "Shuts down the system",
        .handler = shutdown,
    },
    Command{
        .name = "reboot",
        .help = "Reboots the system",
        .handler = reboot,
    },
    Command{
        .name = "dump",
        .help = "Dumps the heap",
        .handler = dumpHeap,
    },
};

fn help(_: []const u8) anyerror!void {
    console.noSwap(); // so we don't constanly swap buffers every command
    defer console.swap();
    for (commands) |cmd| {
        console.print("{s} - {s}\n", .{ cmd.name, cmd.help });
    }
}

fn hlt(_: []const u8) anyerror!void {
    io.hltNoInt();
}

fn echo(line: []const u8) anyerror!void {
    var args = std.mem.tokenizeScalar(u8, line, ' ');
    _ = args.next(); // skip the cmd
    console.write(args.rest());
    console.write("\n");
}

fn getTicks(_: []const u8) anyerror!void {
    console.print("IDK\n", .{});
}

fn clear(_: []const u8) anyerror!void {
    console.clear();
}

fn shutdown(_: []const u8) anyerror!void {
    arch.acpi.shutdown();
    return error.FailedToShutdown;
}

fn reboot(_: []const u8) anyerror!void {
    arch.acpi.reboot();
    return error.FailedToReboot;
}

fn dumpHeap(cmd: []const u8) anyerror!void {
    var args = std.mem.tokenizeScalar(u8, cmd, ' ');
    _ = args.next(); // skip the cmd
    const what = args.next() orelse "";
    if (std.mem.eql(u8, what, "kernel")) {
        heap.get().dump(.all, std.log.debug);
    } else if (std.mem.eql(u8, what, "acpi")) {
        heap.get_acpi().dump(.all, std.log.debug);
    } else if (what.len == 0) {
        heap.get().dump(.all, std.log.debug);
    } else {
        console.print("Unknown heap: {s}\n", .{what});
    }
}
