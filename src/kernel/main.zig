const std = @import("std");
const arch = @import("arch.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const hal = @import("hal/hal.zig");

const ALIGN = 1 << 0;
const MEMINFO = 1 << 1;
const MAGIC = 0x1BADB002;
const FLAGS = ALIGN | MEMINFO;

// multiboot header
const MultibootHeader = packed struct {
    magic: i32 = MAGIC,
    flags: i32,
    checksum: i32,
    padding: u32 = 0,
};

export var multiboot: MultibootHeader align(4) linksection(".multiboot") = MultibootHeader{
    .flags = FLAGS,
    .checksum = -(MAGIC + FLAGS),
};

const STACK_SIZE = 16 * 1024;
var stack_bytes: [STACK_SIZE]u8 align(16) linksection(".bss") = undefined;

const log = std.log.scoped(.kernel);

var paniced = false;

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

// Kernel entry point (_start but this function is called and it calls _main)
export fn __kernel_start() callconv(.naked) noreturn {
    asm volatile (
    // make sure interrupts are disabled
    // set up the stack
        \\ cli
        \\ movl %[stack_top], %%esp
        \\ movl %%esp, %%ebp
        \\ call %[_start:P]
        :
        : [stack_top] "i" (@as([*]align(16) u8, @ptrCast(&stack_bytes)) + @sizeOf(@TypeOf(stack_bytes))),
          // We let the compiler handle the reference to kmain by passing it as an input operand as well.
          [_start] "X" (&_start),
    );
    while (true) {}
}

fn _start() void {
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
    arch.idt.disableGate(50);
    asm volatile ("int $50");
}
