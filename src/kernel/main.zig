const std = @import("std");
const arch = @import("arch.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const hal = @import("hal.zig");
const kb = @import("keyboard.zig");
const mouse = @import("mouse.zig");
const pit = @import("pit.zig");
const pmen = @import("memory/pmem.zig");
const BootInfo = @import("bootinfo.zig").BootInfo;

const heap = @import("memory/heap.zig");

const Screen = @import("Screen.zig");
const Color = @import("Color.zig");

const regs = arch.registers;

const log = std.log.scoped(.kernel);

pub fn _start(mb: *BootInfo) callconv(.c) void {
    // const kernel_start: usize = @intFromPtr(&__kernel_start);
    // const kernel_end: usize = @intFromPtr(&__kernel_end);
    // arch.paging.init(kernel_start, kernel_end);
    log.debug("Initializing kernel components...\n", .{});
    hal.init();

    log.debug("Finished paging init", .{});

    const framebuffer = mb.getFramebuffer(u32);

    const screen = Screen.init(framebuffer, mb.framebuffer_width, mb.framebuffer_height);

    console.init(screen);
    console.clear();
    console.echoToHost(true); // echo all prints to the host

    // init hardware
    // pit timer 100Hz
    pit.init(100);
    kb.init();

    // check bit 6 to see if boot info is valid
    if (mb.flags >> 6 & 1 != 1) {
        @panic("Multiboot info is invalid");
    } else {
        log.debug("Multiboot info is valid", .{});
    }

    const entries = mb.getMemoryMap();

    log.debug("Memory map:", .{});
    for (entries) |entry| {
        log.debug("Start addr: {x} | next: {x} | size: {x} | type: {s}", .{
            entry.addr,
            entry.next,
            entry.size,
            @tagName(entry.type),
        });
    }

    const cpu = arch.CPU.init() catch |err| blk: {
        log.err("Failed to get the CPU: {s}", .{@errorName(err)});
        break :blk arch.CPU.unknown;
    };

    pmen.init(mb, heap.allocator());

    console.echoToHost(false);
    io.sti();
    main(cpu, screen) catch |err| {
        log.err("Failed to run main: {s}", .{@errorName(err)});
    };

    console.write("You reached the end of the kernel, halting...\n");
    std.log.debug("HALTING", .{});
    io.hlt();
}

inline fn color(r: u32, g: u32, b: u32) u32 {
    return (r << 16) | (g << 8) | b;
}

fn getFreeRegion(map: []arch.Multiboot.MemoryMapEntry) ?arch.Multiboot.MemoryMapEntry {
    for (map) |entry| {
        if (entry.type == .available and entry.addr != 0) {
            return entry;
        }
    }

    return null;
}

fn main(_: arch.CPU, screen: *Screen) !void {
    screen.createDoubleBuffer(heap.allocator()) catch |err| {
        log.err("Failed to create double buffer: {s}", .{@errorName(err)});
        log.err("Neaded {x} bytes", .{screen.buffer.len * @sizeOf(u32)});
    };
    screen.use_double_buffer = true;

    std.log.debug("main", .{});
    log.info("Waiting 5 seconds...", .{});
    log.debug("5 seconds wait", .{});

    var buf: [256]u8 = undefined;
    while (true) {
        console.write("> ");
        const line = console.readline(&buf, true) catch |err| switch (err) {
            error.BufferOverflow => @panic("Buffer overflow"),
        };
        console.write("\n");

        if (std.mem.eql(u8, line, "draw")) {
            console.clear(); // clears the console
            drawLoop(screen);
            continue;
        }

        const cmd_name = line[0 .. std.mem.indexOf(u8, line, " ") orelse line.len];

        for (commands) |cmd| {
            if (std.mem.eql(u8, cmd_name, cmd.name)) {
                cmd.handler(line) catch |err| {
                    log.err("Command failed: {s}", .{@errorName(err)});
                };
                break;
            }
        } else {
            log.err("Unknown command: {s}", .{line});
            log.info("Try 'help'", .{});
        }
    }
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
    Command{
        .name = "clear",
        .help = "Clears the screen",
        .handler = clear,
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
    console.print("IDK\n", .{});
}

fn clear(_: []const u8) anyerror!void {
    console.clear();
}

fn drawLoop(screen: *Screen) void {
    screen.use_double_buffer = true;
    defer screen.use_double_buffer = false;

    defer kb.flush();

    var x: u32 = 0;
    var y: u32 = 0;

    while (true) {
        screen.clear(Color.white());
        // screen.drawRectWithBorder(x, y, 600, 500, Color.green(), 5, Color.blue());
        // screen.drawRect(x + 5, y + 5, 600 - 10, 30, Color.gray()); // draw window bar
        // screen.drawText(x + 16, y + 5, "Test window", 2, Color.white());

        screen.drawRect(@intCast(mouse.x()), @intCast(mouse.y()), 10, 10, Color.red());

        screen.swapBuffers();

        if (kb.getKeyDown(.w)) y -|= 1;
        if (kb.getKeyDown(.s)) y += 1;
        if (kb.getKeyDown(.a)) x -|= 1;
        if (kb.getKeyDown(.d)) x += 1;
        if (kb.getKeyDown(.q))
            break;
    }
}
