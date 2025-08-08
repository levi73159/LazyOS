const hal = @import("hal/hal.zig");
const io = @import("arch/x86_64/io.zig");
const console = @import("console.zig");
const std = @import("std");
const KernelBootInfo = @import("boot_info.zig").KernelBootInfo;

const log = std.log.scoped(.kernel);

var paniced = false;

pub extern const __kernel_boot_info: *const KernelBootInfo;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = console.logFn,
    .page_size_min = 1024,
    .page_size_max = 1024,
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
    hal.init();

    main(__kernel_boot_info); // call main function

    io.hlt();
}

fn main(_: *const KernelBootInfo) void {
    // Print startup messages
    log.info("LazyOS v0.1.4", .{});
    while (true) {
        asm volatile ("sti");
    }
}
