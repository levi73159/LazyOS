const std = @import("std");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const acpi = @import("arch/acpi.zig");
const heap = @import("memory/heap.zig");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // white on red
    if (console.serial) |s| {
        s.writeAll("\x1b[97;41m") catch {};
        s.print("!!! KERNEL PANIC !!!\n{s}\n", .{msg}) catch {};

        s.print("return address: {?x}\n", .{ret_addr}) catch {};

        walkStack(s);

        s.writeAll("\x1b[0m") catch {};
    }

    console.dbg("\x1b[97;41m");
    console.dbgPrint("!!! KERNEL PANIC !!!\n{s}\n", .{msg});

    console.dbgPrint("return address: {?x}\n", .{ret_addr});
    io.hltNoInt();
}

fn walkStack(s: *std.Io.Writer) void {
    var rbp: u64 = @frameAddress();

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (rbp == 0 or rbp & 0xF != 0) break; // misaligned = bad frame

        const ret = @as(*u64, @ptrFromInt(rbp + 8)).*;
        if (ret == 0) break;

        s.print("  #{d}: 0x{x}\n", .{ i, ret }) catch break;

        rbp = @as(*u64, @ptrFromInt(rbp)).*;
    }
}
