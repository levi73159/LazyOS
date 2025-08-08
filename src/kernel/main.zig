// const hal = @import("hal/hal.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const std = @import("std");

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

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    console.panic(message);
}

// Kernel entry point (_start but this function is called and it calls _main)
export fn __kernel_start() callconv(.naked) noreturn {
    asm volatile (
    // make sure interrupts are disabled
        \\ cli
        // set up the stack
        \\ movl %[stack_top], %%esp
        \\ movl %%esp, %%ebp
        \\ call %[_start:P]
        :
        : [stack_top] "i" (@as([*]align(16) u8, @ptrCast(&stack_bytes)) + @sizeOf(@TypeOf(stack_bytes))),
          // We let the compiler handle the reference to kmain by passing it as an input operand as well.
          [_start] "X" (&_start),
    );
}

fn _start() void {
    // startup functions
    console.clear();

    main();
    @panic("YOU DIED");
    // while (true) {
    //     io.hlt();
    // }
}

fn main() void {
    std.log.info("Hello world!", .{});
}
