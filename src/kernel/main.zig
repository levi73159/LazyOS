const std = @import("std");
const arch = @import("arch.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const hal = @import("hal.zig");
const kb = @import("keyboard.zig");

const Screen = @import("Screen.zig");
const Color = @import("Color.zig");

const regs = arch.registers;

const log = std.log.scoped(.kernel);

var ticks: u64 = 0;
var screen: Screen = undefined;

fn tick(_: *regs.InterruptFrame) void {
    ticks +%= 1;
    screen.drawRect(0, 0, 100, 100, Color.init(@truncate(ticks % 256 + 100), @truncate(ticks % 256), 50));
}

pub fn _start(mb: *arch.MultibootInfo) callconv(.c) void {
    console.clear();

    hal.init();

    // init hardware
    arch.irq.register(0, tick);
    arch.irq.enable(0);
    kb.init();

    // check bit 6 to see if boot info is valid
    if (mb.flags >> 6 & 1 != 1) {
        @panic("Multiboot info is invalid");
    } else {
        log.debug("Multiboot info is valid", .{});
    }

    const entries = mb.getMemoryMap();

    log.info("Memory map:", .{});
    for (entries) |entry| {
        log.info("Start addr: {x} | len: {x} | size: {x} | type: {s}", .{
            entry.addr,
            entry.len,
            entry.size,
            @tagName(entry.type),
        });
    }

    const framebuffer = mb.getFramebuffer(u32);
    screen = Screen.init(framebuffer, mb.framebuffer_width, mb.framebuffer_height, mb.framebuffer_pitch);
    screen.clear(Color.white());

    io.sti();

    main();

    console.write("You reached the end of the kernel, halting...\n");
    std.log.debug("HALTING", .{});
    io.hlt();
}

inline fn color(r: u32, g: u32, b: u32) u32 {
    return (r << 16) | (g << 8) | b;
}

fn main() void {
    std.log.info("Hello world!", .{});
    console.clear();

    screen.drawRect(0, 0, 20, 20, Color.red());
    while (true) {}

    // var buf: [256]u8 = undefined;
    // while (true) {
    //     console.write("> ");
    //     const line = console.readline(&buf, true) catch |err| switch (err) {
    //         error.BufferOverflow => @panic("Buffer overflow"),
    //     };
    //     console.write("\n");
    //
    //     const cmd_name = line[0 .. std.mem.indexOf(u8, line, " ") orelse line.len];
    //
    //     for (commands) |cmd| {
    //         if (std.mem.eql(u8, cmd_name, cmd.name)) {
    //             cmd.handler(line) catch |err| {
    //                 log.err("Command failed: {s}", .{@errorName(err)});
    //             };
    //             break;
    //         }
    //     } else {
    //         log.err("Unknown command: {s}", .{line});
    //         log.info("Try 'help'", .{});
    //     }
    // }
}

const Command = struct {
    name: []const u8,
    help: []const u8,
    handler: *const fn (line: []const u8) anyerror!void,
};

const commands: []const Command = &[_]Command{
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
};

fn help(_: []const u8) anyerror!void {
    for (commands) |cmd| {
        console.print("{s} - {s}\n", .{ cmd.name, cmd.help });
    }
}

fn hlt(_: []const u8) anyerror!void {
    io.hlt();
}

fn echo(line: []const u8) anyerror!void {
    var args = std.mem.tokenizeScalar(u8, line, ' ');
    _ = args.next(); // skip the cmd
    console.write(args.rest());
    console.write("\n");
}

fn getTicks(_: []const u8) anyerror!void {
    console.print("Ticks: {d}\n", .{ticks});
}
