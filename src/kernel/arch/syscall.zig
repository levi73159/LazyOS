const std = @import("std");
const msr = @import("msr.zig");
const gdt = @import("gdt.zig");
const scheduler = @import("../scheduler.zig");
const console = @import("../console.zig");

const log = std.log.scoped(._syscall);

pub const SyscallFrame = extern struct {
    rbp: u64,
    rsi: u64,
    rdi: u64,

    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    // r11 is the rflags
    r10: u64,
    r9: u64,
    r8: u64,

    rdx: u64,
    // rcx is the rip
    rbx: u64,
    rax: u64,

    /// AKA the return address (syscall puts this in the rcx register)
    user_rip: u64,
    /// syscall puts this in the r11 register for sysret
    user_rflags: u64,
};

pub export var user_rsp: u64 = 0xdeadbeef1;
pub export var kernel_rsp: u64 = 0xdeadbeef2; // set by the kernel before calling user code

pub const SUCCESS: u64 = 0;
pub const EPERM: u64 = 1;
pub const ENOENT: u64 = 2;
pub const ESRCH: u64 = 3;
pub const EINTR: u64 = 4;
pub const EIO: u64 = 5;
pub const EBADF: u64 = 9;
pub const EAGAIN: u64 = 11;
pub const ENOMEM: u64 = 12;
pub const EACCES: u64 = 13;
pub const EFAULT: u64 = 14;
pub const EINVAL: u64 = 22;
pub const ENOSYS: u64 = 38;

pub const FD_FILE_START = 3;
pub const FD_STDIN = 0;
pub const FD_STDOUT = 1;
pub const FD_STDERR = 2;

export fn syscallHandler(frame: *SyscallFrame) callconv(.c) void {
    log.debug("Syscall {d}", .{frame.rax});
    frame.rax = switch (frame.rax) {
        0 => sys_test(frame),
        1 => sys_write(frame),
        60 => sys_exit(frame),
        else => ENOSYS,
    };
}

fn sys_test(frame: *SyscallFrame) u64 {
    _ = frame;

    @import("std").log.debug("sys_test", .{});

    return 0;
}

fn sys_write(frame: *SyscallFrame) u64 {
    const fd = frame.rdi;
    const buf: [*]const u8 = @ptrFromInt(frame.rsi);
    const count = frame.rdx;

    const string = buf[0..count];
    switch (fd) {
        FD_STDIN => {
            log.err("Can't write to stdin", .{});
            return EPERM;
        },
        FD_STDOUT => {
            console.write(string);
            return count;
        },
        FD_STDERR => {
            console.write(string);
            return count;
        },
        else => {
            log.err("Can't write to fd {d}", .{fd});
            return EBADF;
        },
    }
}

fn sys_exit(frame: *SyscallFrame) u64 {
    const code = frame.rdi;

    scheduler.taskExit(code);
    return code;
}

pub fn init() void {
    const boot = @import("root");
    kernel_rsp = @intFromPtr(&boot.kernel_stack) + boot.KERNEL_STACK_SIZE;

    const efer = msr.read(msr.MSR_EFER);
    msr.write(msr.MSR_EFER, efer | 1); // enable SCE

    // STAR: kernel CS at bits 47:32 user CS at bits 63:48
    const star: u64 =
        (@as(u64, @intFromEnum(gdt.Selector.kernel_code)) << 32) |
        (@as(u64, @intFromEnum(gdt.Selector.kernel_data)) << 48);
    msr.write(msr.MSR_STAR, star);

    // LSTAR: syscall entry point
    msr.write(msr.MSR_LSTAR, @intFromPtr(&syscallEntry));

    msr.write(msr.MSR_FMASK, 0x200 | 0x400);
}

extern fn syscallEntry() callconv(.naked) noreturn;
