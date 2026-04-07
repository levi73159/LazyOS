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

pub const SUCCESS: i64 = 0;
pub const EPERM: i64 = -1;
pub const ENOENT: i64 = -2;
pub const ESRCH: i64 = -3;
pub const EINTR: i64 = -4;
pub const EIO: i64 = -5;
pub const EBADF: i64 = -9;
pub const EAGAIN: i64 = -11;
pub const ENOMEM: i64 = -12;
pub const EACCES: i64 = -13;
pub const EFAULT: i64 = -14;
pub const EINVAL: i64 = -22;
pub const ENOSYS: i64 = -38;

pub const FD_FILE_START = 3;
pub const FD_STDIN = 0;
pub const FD_STDOUT = 1;
pub const FD_STDERR = 2;

export fn syscallHandler(frame: *SyscallFrame) callconv(.c) void {
    log.debug("Syscall {d}", .{frame.rax});
    log.debug("syscall {d} rdi=0x{x} rsi=0x{x} rdx=0x{x}", .{ frame.rax, frame.rdi, frame.rsi, frame.rdx });
    const num = frame.rax;
    const val = switch (num) {
        0 => sys_test(frame),
        1 => sys_write(frame),
        16 => sys_ioctl(frame),
        20 => sys_writev(frame),
        60 => sys_exit(frame),
        158 => sys_arch_prctl(frame),
        218 => 1, // set_tid_address (stub it with fake TID address of 1 since we don't have threads)
        else => ENOSYS,
    };
    frame.rax = @bitCast(val);
    log.debug("syscall {d} -> {x}, user_rip={x}", .{ num, frame.rax, frame.user_rip });
}

fn sys_test(frame: *SyscallFrame) i64 {
    _ = frame;

    @import("std").log.debug("sys_test", .{});

    return 0;
}

fn sys_arch_prctl(frame: *SyscallFrame) i64 {
    const SET_FS = 0x1002;
    const code = frame.rdi;
    const addr = frame.rsi;

    switch (code) {
        SET_FS => {
            msr.write(msr.MSR_FSBASE, addr);
            scheduler.getCurrentTask().fs_base = addr;
        },
        else => {
            log.err("Unknown arch_prctl code {d}", .{code});
            return EINVAL;
        },
    }
    return 0;
}

fn sys_write(frame: *SyscallFrame) i64 {
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
            return @intCast(count);
        },
        FD_STDERR => {
            console.write(string);
            return @intCast(count);
        },
        else => {
            log.err("Can't write to fd {d}", .{fd});
            return EBADF;
        },
    }
}

const iovec = struct {
    base: usize,
    len: usize,
};

fn sys_writev(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const iov: [*]const iovec = @ptrFromInt(frame.rsi);
    const count = frame.rdx;

    var total_len: u64 = 0;
    const iovecs = iov[0..count];
    for (iovecs) |vec| {
        if (vec.base == 0) continue; // skip NULL pointers
        if (vec.len == 0) continue; // skip empty vectors
        const ptr: [*]const u8 = @ptrFromInt(vec.base);
        const slice = ptr[0..vec.len];

        const string = slice[0..vec.len];
        switch (fd) {
            FD_STDIN => {
                log.err("Can't write to stdin", .{});
                return EPERM;
            },
            FD_STDOUT => {
                console.write(string);
                total_len += string.len;
            },
            FD_STDERR => {
                console.write(string);
                total_len += string.len;
            },
            else => {
                log.err("Can't write to fd {d}", .{fd});
                return EBADF;
            },
        }
    }

    return @intCast(total_len);
}

fn sys_exit(frame: *SyscallFrame) i64 {
    const code = frame.rdi;

    scheduler.taskExit(code);
    return code;
}

fn sys_ioctl(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const request = frame.rsi;

    _ = fd;
    _ = request;

    // pretend it's NOT a terminal
    return -25;
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
