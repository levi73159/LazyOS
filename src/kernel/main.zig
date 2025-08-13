const std = @import("std");
const arch = @import("arch.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const hal = @import("hal.zig");
const kb = @import("keyboard.zig");

const regs = arch.registers;

const log = std.log.scoped(.kernel);

fn timer(_: *regs.InterruptFrame) void {}

pub fn _start(mb: *arch.MultibootInfo) callconv(.c) void {
    console.clear();

    hal.init();
    arch.irq.register(0, timer);
    arch.irq.register(1, kb.handler);

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

    io.sti();

    main();

    console.write("You reached the end of the kernel, halting...\n");
    io.hlt();
}

fn main() void {
    std.log.info("Hello world!", .{});
    console.clear();

    var buf: [32]u8 = undefined;
    while (true) {
        const line = console.readline(&buf, true) catch |err| switch (err) {
            error.BufferOverflow => @panic("Buffer overflow"),
        };
        console.write("\n");
        console.write(line);
        console.write("\n");
    }
}
