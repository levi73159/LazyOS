const std = @import("std");
const io = @import("arch.zig").io;
const console = @import("console.zig");

pub fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
    // white on red
    if (console.serial) |s| {
        s.writeAll("\x1b[97;41m") catch {};
        s.print("!!! KERNEL PANIC !!!\n{s}\n", .{msg}) catch {};

        s.print("return address: {?x}\n", .{ret_addr}) catch {};
    }

    console.dbg("\x1b[97;41m");
    console.dbgPrint("!!! KERNEL PANIC !!!\n{s}\n", .{msg});

    console.dbgPrint("return address: {?x}\n", .{ret_addr});
    io.hltNoInt();
}
