const std = @import("std");
const arch = @import("arch.zig");
const pmem = @import("memory/pmem.zig");
const gdt = @import("arch/gdt.zig");
const paging = @import("arch/paging.zig");
const io = @import("arch/io.zig");

pub const USER_CODE_BASE = 0x400000;
pub const USER_STACK_TOP = 0x00007FFFFFFFE000;
pub const USER_STACK_SIZE = 12 * 1024; // 12kb

pub fn run(code_addr: u64, stack_top: u64) void {
    asm volatile (
        \\ cli
        \\ mov %[data_seg], %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ push %[data_seg]
        \\ push %[stack_top]
        \\ pushfq 
        \\ push %[code_seg]
        \\ push %[code_addr]
        \\ iretq
        :
        : [data_seg] "i" (gdt.Segment.user_data),
          [stack_top] "r" (stack_top),
          [code_seg] "i" (gdt.Segment.user_code),
          [code_addr] "r" (code_addr),
    );
}

pub fn mapCode(phys: u64, len: u64) u64 {
    const phys_aligned = std.mem.alignBackward(u64, phys, paging.PAGE_SIZE);
    paging.mapRange(USER_CODE_BASE, phys_aligned, len, .{ .present = true, .writeable = false, .execute_disable = false, .user = true });
    // get first 12 bits of phys aka the offset
    const offset = phys & 0x00000FFF;
    // get offset from user_code
    return USER_CODE_BASE + offset;
}

/// returns STACK TOP
pub fn mapStack(phys: u64, len: u64) u64 {
    const phys_aligned = std.mem.alignBackward(u64, phys, paging.PAGE_SIZE);
    const bottom = USER_STACK_TOP - len;
    const bottom_aligned = std.mem.alignBackward(u64, bottom, paging.PAGE_SIZE);
    paging.mapRange(bottom_aligned, phys_aligned, len, .{ .present = true, .writeable = true, .execute_disable = true, .user = true });
    // get offset from user_code
    return USER_STACK_TOP;
}
