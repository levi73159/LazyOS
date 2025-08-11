const std = @import("std");
const arch = @import("arch.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const hal = @import("hal.zig");

const log = std.log.scoped(.kernel);

pub fn _start() void {
    console.clear();

    hal.init();

    main();
    console.write("halting...\n");
    while (true) {
        io.hlt();
    }
}

fn main() void {
    std.log.info("Hello world!", .{});

    while (true) {}
}
