const std = @import("std");
const msr = @import("msr.zig");
const gdt = @import("gdt.zig");
const root = @import("root");
const scheduler = root.proc.scheduler;
const console = root.console;
const File = root.fs.File;
const errno = @import("syscall/errno.zig");

const sysvfs = @import("syscall/vfs.zig");
const sysmem = @import("syscall/memory.zig");

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

export fn syscallHandler(frame: *SyscallFrame) callconv(.c) void {
    const num = frame.rax;
    const val = switch (num) {
        0 => sysvfs.read(frame),
        1 => sysvfs.write(frame),
        2 => sysvfs.open(frame),
        3 => sysvfs.close(frame),
        9 => sysmem.mmap(frame),
        11 => sysmem.munmap(frame),
        12 => sysmem.brk(frame),
        13 => rt_sigaction(frame),
        16 => sysvfs.ioctl(frame),
        20 => sysvfs.writev(frame),
        231 => sys_exit_group(frame),
        60 => sys_exit(frame),
        158 => sys_arch_prctl(frame),
        39 => sys_getpid(frame),
        186 => sys_gettid(frame),
        218 => sys_gettid(frame), // set_tid_address (stub it with fake TID address of 1 since we don't have threads)
        295 => sysvfs.preadv(frame),
        14 => @as(i64, 0), // rt_sigprocmask — mask signals, stub ok
        131 => @as(i64, 0), // sigaltstack — alternate signal stack, stub ok
        200 => @as(i64, 0), // tkill — send signal to thread, stub ok
        310 => @as(i64, 0), // process_vm_readv — read another process memory, stub ok
        26 => @as(i64, 0), // msync — sync memory to file, stub ok
        257 => sysvfs.openat(frame), // openat — needs real impl for stack traces
        else => errno.ENOSYS,
    };
    log.debug("syscall {d} -> {x}, user_rip={x}", .{ num, val, frame.user_rip });
    frame.rax = @bitCast(val);
}

fn sys_getpid(_: *SyscallFrame) i64 {
    return scheduler.currentTask();
}

fn sys_gettid(_: *SyscallFrame) i64 {
    return scheduler.currentTask();
}

fn rt_sigaction(_: *SyscallFrame) i64 {
    return 0;
}

fn sys_arch_prctl(frame: *SyscallFrame) i64 {
    const SET_FS = 0x1002;
    const code = frame.rdi;
    const addr = frame.rsi;
    log.debug("arch_prctl: {x} to {x}", .{ code, addr });

    switch (code) {
        SET_FS => {
            msr.write(msr.MSR_FSBASE, addr);
            scheduler.getCurrentTask().fs_base = addr;
        },
        else => {
            log.err("Unknown arch_prctl code {d}", .{code});
            return errno.EINVAL;
        },
    }
    return 0;
}

fn sys_exit(frame: *SyscallFrame) i64 {
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

fn sys_exit_group(frame: *SyscallFrame) i64 {
    scheduler.taskExit(frame.rdi);
    unreachable;
}

extern fn syscallEntry() callconv(.naked) noreturn;
