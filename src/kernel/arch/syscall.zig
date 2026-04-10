const std = @import("std");
const msr = @import("msr.zig");
const gdt = @import("gdt.zig");
const scheduler = @import("../scheduler.zig");
const console = @import("../console.zig");
const File = @import("../fs/File.zig");

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
    const num = frame.rax;
    const val = switch (num) {
        0 => sys_read(frame),
        1 => sys_write(frame),
        13 => rt_sigaction(frame),
        16 => sys_ioctl(frame),
        20 => sys_writev(frame),
        231 => sys_exit_group(frame),
        60 => sys_exit(frame),
        158 => sys_arch_prctl(frame),
        39 => sys_getpid(frame),
        186 => sys_gettid(frame),
        218 => sys_gettid(frame), // set_tid_address (stub it with fake TID address of 1 since we don't have threads)
        295 => sys_preadv(frame),
        14 => @as(i64, 0), // rt_sigprocmask — mask signals, stub ok
        131 => @as(i64, 0), // sigaltstack — alternate signal stack, stub ok
        200 => @as(i64, 0), // tkill — send signal to thread, stub ok
        310 => @as(i64, 0), // process_vm_readv — read another process memory, stub ok
        26 => @as(i64, 0), // msync — sync memory to file, stub ok
        257 => sys_openat(frame), // openat — needs real impl for stack traces
        else => ENOSYS,
    };
    frame.rax = @bitCast(val);
    log.debug("syscall {d} -> {x}, user_rip={x}", .{ num, frame.rax, frame.user_rip });
}

fn sys_preadv(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const iov: [*]const iovec = @ptrFromInt(frame.rsi);
    const count = frame.rdx;

    if (fd != FD_STDIN) {
        log.err("Can't read from fd {d}", .{fd});
        return EBADF;
    }

    if (count == 0) return 0;

    var total: usize = 0;
    @import("io.zig").sti();
    for (iov[0..count]) |vec| {
        if (vec.len == 0) continue;
        if (vec.base == 0) continue;

        const ptr: [*]u8 = @ptrFromInt(vec.base);
        const buf = ptr[0..vec.len];

        var i: usize = 0;
        while (i < buf.len) {
            const key = @import("../keyboard.zig").getKey();
            if (!key.pressed) continue;

            if (key.getChar()) |c| {
                buf[i] = c;
                i += 1;
                console.putchar(c);
                console.complete();
                if (c == '\n') break;
            }
        }
        total += i;
    }

    return @intCast(total);
}

fn sys_openat(frame: *SyscallFrame) i64 {
    const path_ptr: [*:0]const u8 = @ptrFromInt(frame.rsi);
    const path = std.mem.span(path_ptr);
    log.warn("openat: path={s}", .{path});
    return ENOENT;
}

fn sys_getpid(_: *SyscallFrame) i64 {
    return scheduler.currentTask();
}

fn sys_gettid(_: *SyscallFrame) i64 {
    return scheduler.currentTask();
}

fn sys_read(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const count = frame.rdx;

    if (fd != FD_STDIN) {
        log.err("Can't read from fd {d}", .{fd});
        return EBADF;
    }
    log.debug("Reading {d} bytes from stdin", .{count});

    const ptr: [*]u8 = @ptrFromInt(frame.rsi);
    var i: usize = 0;
    // enable interrupts
    @import("io.zig").sti();
    while (i < count) {
        const kb = @import("../keyboard.zig");
        const key = kb.getKey();
        if (!key.pressed) continue;

        if (key.getChar()) |c| {
            ptr[i] = c;
            i += 1;
            // echo character back
            console.putchar(c); // put char dones't swap buffers, must call complete
            console.complete();
            if (c == '\n') break;
        }
    }

    return @intCast(i);
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
    const process = scheduler.getCurrentProcess() orelse {
        log.err("No current process", .{});
        return EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) {
        return EBADF;
    }

    const file = process.getFile(@intCast(fd)) orelse {
        return EBADF;
    };

    const written = file.write(string) catch |err| {
        log.err("Failed to write to file {d}: {s}", .{ fd, err });
        return EIO;
    };

    return @intCast(written);
}

const iovec = struct {
    base: usize,
    len: usize,
};

fn sys_writev(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const iov: [*]const File.iovec = @ptrFromInt(frame.rsi);
    const count = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        log.err("No current process", .{});
        return EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) {
        return EBADF;
    }

    const file = process.getFile(@intCast(fd)) orelse {
        return EBADF;
    };

    const n = file.writev(iov[0..count]) catch |err| {
        log.err("Failed to write to file {d}: {s}", .{ fd, err });
        return EIO;
    };

    return @intCast(n);
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

fn sys_exit_group(frame: *SyscallFrame) i64 {
    scheduler.taskExit(frame.rdi);
    unreachable;
}

extern fn syscallEntry() callconv(.naked) noreturn;
