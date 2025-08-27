const std = @import("std");
const arch = @import("arch.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const hal = @import("hal.zig");
const kb = @import("keyboard.zig");
const BumpAllocator = @import("memory/BumpAllocator.zig");
const mouse = @import("mouse.zig");

const Screen = @import("Screen.zig");
const Color = @import("Color.zig");

const regs = arch.registers;

const log = std.log.scoped(.kernel);

var ticks: u64 = 0;

extern const __kernel_end: u8;

fn tick(_: *regs.InterruptFrame) void {
    // ticks +%= 1;
    // screen.drawRect(x, y, 100, 100, Color.init(@truncate(ticks % 256 + 100), @truncate(ticks % 256), 50));
}

pub fn _start(mb: *arch.MultibootInfo) callconv(.c) void {
    const framebuffer = mb.getFramebuffer(u32);
    const screen = Screen.init(framebuffer, mb.framebuffer_width, mb.framebuffer_height);

    console.init(screen);
    console.clear();

    hal.init();

    // init hardware
    arch.irq.register(0, tick);
    arch.irq.enable(0);
    kb.init();
    mouse.init() catch |err| {
        log.err("Mouse init failed: {s}", .{@errorName(err)});
    };

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

    var start: bool = false;
    const free_region: arch.Multiboot.MemoryMapEntry =
        get: for (entries) |entry| {
            if (!start) {
                // skip first one because it usally small
                start = true;
                continue;
            }

            if (entry.type == .available and entry.addr != 0) {
                log.debug("Free region: {x} | next: {x} | size: {x} | type: {s}", .{
                    entry.addr,
                    entry.next,
                    entry.size,
                    @tagName(entry.type),
                });

                break :get entry;
            }
        } else {
            @panic("No free region");
        };

    // get the region
    const kernel_end_addr = @intFromPtr(&__kernel_end);
    const addr: usize = @intCast(free_region.addr + kernel_end_addr);
    const ptr: [*]u8 = @ptrFromInt(addr);
    const region = ptr[0..@intCast(free_region.size)];

    std.log.debug("heap size: {x}", .{region.len});
    var bump_allocator = BumpAllocator.init(region);
    const allocator = bump_allocator.allocator();

    screen.createDoubleBuffer(allocator) catch |err| {
        log.err("Failed to create double buffer: {s}", .{@errorName(err)});
    };

    io.sti();
    main(screen, allocator);

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

fn main(screen: *Screen, _: std.mem.Allocator) void {
    std.log.debug("main", .{});

    // NEXT ADD ALOCATOR!!!
    // while (true) {
    //     screen.clear(Color.white());
    //
    //     const key = kb.getKey();
    //     if (!key.pressed) continue;
    //     if (key.scancode == .w) {
    //         y -|= 1;
    //     }
    //     if (key.scancode == .s) {
    //         y += 1;
    //     }
    //     if (key.scancode == .a) {
    //         x -|= 1;
    //     }
    //     if (key.scancode == .d) {
    //         x += 1;
    //     }
    // }

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
    console.print("Ticks: {d}\n", .{ticks});
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
