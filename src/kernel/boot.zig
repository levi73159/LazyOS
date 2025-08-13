const std = @import("std");
const main = @import("main.zig");
const console = @import("console.zig");

const arch = @import("arch.zig");

const ALIGN = 1 << 0;
const MEMINFO = 1 << 1;
const MAGIC = arch.Multiboot.HEADER_MAGIC;
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

// Kernel entry point (_start but this function is called and it calls _main)
export fn __kernel_start() callconv(.naked) noreturn {
    asm volatile (
    // make sure interrupts are disabled
    // set up the stack
        \\ cli
        \\ movl %[stack_top], %%esp
        \\ movl %%esp, %%ebp
        // get ebx (multiboot info from grub) and pass it to _start with the
        // also get eax (multiboot magic c_uint) and pass it to _start
        // start must be _start(multiboot_info, multiboot_magic)
        :
        : [stack_top] "r" (@as([*]align(16) u8, @ptrCast(&stack_bytes)) + @sizeOf(@TypeOf(stack_bytes))),
    );

    // get info addr from ebx
    const mb_info_addr = asm ("mov %%ebx, %[res]"
        : [res] "=r" (-> usize),
    );

    asm volatile (
        \\ push %[info]
        \\ call %[_start:P]
        :
        : [info] "r" (mb_info_addr),
          [_start] "X" (&main._start),
    );
    while (true) {
        asm volatile ("cli");
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
