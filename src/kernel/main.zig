// const hal = @import("hal/hal.zig");
const io = @import("arch/x86/io.zig");
const console = @import("console.zig");
const std = @import("std");
const KernelBootInfo = @import("boot_info.zig").KernelBootInfo;

var paniced = false;

pub extern const __kernel_boot_info: *const KernelBootInfo;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = console.logFn,
};

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    console.panic(message);
}

// Kernel entry point (_start but this function is called and it calls _main)
export fn __zig_entry() noreturn {
    asm volatile (
        \\mov %rsp, __stack_top
    );
    // Initialize required hardware

    console.init(__kernel_boot_info);
    // hal.init();

    main(__kernel_boot_info); // call main function

    io.hlt();
}

fn main(_: *const KernelBootInfo) void {
    // Print startup messages
    console.write("LazyOS v0.1.0\n");

    var n = [_]u8{0} ** 20;
    console.dbg("Hello world!\n");
    n[0] = 'H';
    console.write(n[0..]);
}
