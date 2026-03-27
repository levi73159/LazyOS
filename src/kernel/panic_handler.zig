const std = @import("std");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const acpi = @import("arch/acpi.zig");
const heap = @import("memory/heap.zig");

pub fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
    // white on red
    if (console.serial) |s| {
        s.writeAll("\x1b[97;41m") catch {};
        s.print("!!! KERNEL PANIC !!!\n{s}\n", .{msg}) catch {};

        s.print("return address: {?x}\n", .{ret_addr}) catch {};

        // s.writeAll("acpi dump:\n") catch {};
        // heap.get_acpi().dump(.all, std.log.scoped(.host).debug);
        //
        // s.writeAll("kernel heap dump:\n") catch {};
        // heap.get().dump(.all, std.log.scoped(.host).debug);
    }

    console.dbg("\x1b[97;41m");
    console.dbgPrint("!!! KERNEL PANIC !!!\n{s}\n", .{msg});

    console.dbgPrint("return address: {?x}\n", .{ret_addr});
    io.hltNoInt();
}
