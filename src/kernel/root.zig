pub const arch = @import("arch/arch.zig");
pub const memory = @import("memory/memory.zig");
pub const proc = @import("proc/proc.zig");
pub const fs = @import("fs/fs.zig");
pub const dev = @import("dev/dev.zig");
pub const graphics = @import("graphics/graphics.zig");
pub const acpi = @import("acpi/acpi.zig");
pub const debug = @import("debug/debug.zig");
pub const lib = @import("lib/lib.zig");

// top level
pub const boot = @import("boot.zig");
pub const hal = @import("hal.zig");
pub const pit = arch.pit;
pub const Shell = @import("shell/Shell.zig");

comptime {
    _ = boot; // ← forces the symbol to be emitted
}

// commonly accessed directly
pub const console = graphics.console;
pub const io = arch.io;
pub const pmem = memory.pmem;
pub const heap = memory.heap;

// boot constants used via @import("root")
pub const KERNEL_STACK_SIZE = boot.KERNEL_STACK_SIZE;
pub const kernel_stack = &boot.kernel_stack;

// ─────────────────────────────────────────────────────────────────────────────
// Zig hooks
// ─────────────────────────────────────────────────────────────────────────────

const std = @import("std");
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = console.logFn,
    .page_size_min = 4096,
    .page_size_max = 4096,
};

pub fn panic(msg: []const u8, stack: ?*std.builtin.StackTrace, ret: ?usize) noreturn {
    @branchHint(.cold);
    @import("panic_handler.zig").panic(msg, stack, ret);
}
