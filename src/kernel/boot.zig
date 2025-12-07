const std = @import("std");
const main = @import("main.zig");
const console = @import("console.zig");
const builtin = @import("builtin");

const arch = @import("arch.zig");

const STACK_SIZE = 16 * 1024; // 16 KiB stack
var stack_bytes: [STACK_SIZE]u8 align(16) linksection(".bss.stack") = undefined;

// Kernel entry point (_start but this function is called and it calls _main)
export fn __kernel_entry() callconv(.naked) noreturn {
    // compute stack top (physical address). Do not subtract the KERNEL_ADDR_OFFSET here:
    const phys_stack: [*]u8 = @ptrCast(&stack_bytes);
    const stack_top = phys_stack + @sizeOf(@TypeOf(stack_bytes));
    const virt_stack_top = stack_top;
    // set a simple low stack and call boot_init
    if (builtin.cpu.arch == .x86) {
        asm volatile (
            \\ cli
            \\ movl %[stack_top], %%esp
            \\ movl %%esp, %%ebp
            :
            : [stack_top] "r" (virt_stack_top),
        );
    } else {
        asm volatile (
            \\ cli
            \\ mov %[stack_top], %%rsp
            \\ mov %%rsp, %%rbp
            :
            : [stack_top] "r" (virt_stack_top),
        );
    }
    // call the initializer that does PD/PT fill and paging enable
    asm volatile (
        \\ call boot_init
    );
    while (true) {
        asm volatile ("hlt");
    }
}

extern const bootinfo: usize;

export fn boot_init() noreturn {
    main._start(@ptrFromInt(bootinfo));

    while (true) {
        asm volatile ("hlt");
    }
}
//
// zig stuff
//
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = console.logFn,
    .page_size_min = 1024,
    .page_size_max = 1024,
};

pub fn panic(message: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    console.panic(message, trace, ret_addr);
}
