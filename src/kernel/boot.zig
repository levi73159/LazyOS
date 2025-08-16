const std = @import("std");
const main = @import("main.zig");
const console = @import("console.zig");

const arch = @import("arch.zig");

const ALIGN = 1 << 0;
const MEMINFO = 1 << 1;
const VIDEOINFO = 1 << 2;
const AOUT_KLUDGE = 0x00010000;

// #define MULTIBOOT_AOUT_KLUDGE                   0x00010000
const MAGIC = arch.Multiboot.HEADER_MAGIC;
const FLAGS = ALIGN | MEMINFO | VIDEOINFO;

// multiboot header
const MultibootHeader = extern struct {
    magic: i32 = MAGIC,
    flags: u32 = FLAGS,
    checksum: i32,

    header_addr: u32 = 0,
    load_addr: u32 = 0,
    load_end_addr: u32 = 0,
    bss_end_addr: u32 = 0,
    entry_addr: u32 = 0,

    mode_type: u32,
    width: u32,
    height: u32,
    depth: u32,

    // /* Must be MULTIBOOT_MAGIC - see above. */
    // multiboot_uint32_t magic;
    //
    // /* Feature flags. */
    // multiboot_uint32_t flags;
    //
    // /* The above fields plus this one must equal 0 mod 2^32. */
    // multiboot_uint32_t checksum;
    //
    // /* These are only valid if MULTIBOOT_AOUT_KLUDGE is set. */
    // multiboot_uint32_t header_addr;
    // multiboot_uint32_t load_addr;
    // multiboot_uint32_t load_end_addr;
    // multiboot_uint32_t bss_end_addr;
    // multiboot_uint32_t entry_addr;
    //
    // /* These are only valid if MULTIBOOT_VIDEO_MODE is set. */
    // multiboot_uint32_t mode_type;
    // multiboot_uint32_t width;
    // multiboot_uint32_t height;
    // multiboot_uint32_t depth;
};

export var multiboot: MultibootHeader align(16) linksection(".multiboot") = MultibootHeader{
    .flags = FLAGS,
    .checksum = -(MAGIC + FLAGS),
    .mode_type = 0,
    .width = 1024,
    .height = 768,
    .depth = 32,
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
