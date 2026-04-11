const std = @import("std");
const root = @import("root");
const SyscallFrame = @import("../syscall.zig").SyscallFrame;
const errno = @import("errno.zig");
const scheduler = root.proc.scheduler;
const File = root.fs.File;

const log = std.log.scoped(._sysvfs);

pub fn read(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const count = frame.rdx;
    const ptr: [*]u8 = @ptrFromInt(frame.rsi);

    const process = scheduler.getCurrentProcess() orelse {
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    const file = process.getFile(@intCast(fd)) orelse {
        log.err("Invalid file descriptor {d}", .{fd});
        return errno.EBADF;
    };

    const n = file.read(ptr[0..count]) catch |err| {
        log.err("Error reading file: {s}", .{@errorName(err)});
        return errno.EIO;
    };

    return @intCast(n);
}

pub fn preadv(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const iov: [*]const File.iovec = @ptrFromInt(frame.rsi);
    const count = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    const file = process.getFile(@intCast(fd)) orelse {
        log.err("Invalid file descriptor {d}", .{fd});
        return errno.EBADF;
    };

    const total = file.readv(iov[0..count]) catch |err| {
        log.err("Failed to read from file {d}: {s}", .{ fd, @errorName(err) });
        return errno.EIO;
    };

    return @intCast(total);
}

pub fn openat(frame: *SyscallFrame) i64 {
    const path_ptr: [*:0]const u8 = @ptrFromInt(frame.rsi);
    const path = std.mem.span(path_ptr);
    log.warn("openat: path={s}", .{path});
    return errno.ENOENT;
}

pub fn ioctl(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const request = frame.rsi;
    const arg = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) {
        return errno.EBADF;
    }

    const file = process.getFile(@intCast(fd)) orelse {
        return errno.EBADF;
    };

    return file.ioctl(@intCast(request), arg) catch |err| {
        log.err("Failed to ioctl file {d}: {s}", .{ fd, @errorName(err) });
        return errno.EIO;
    };
}

pub fn write(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const buf: [*]const u8 = @ptrFromInt(frame.rsi);
    const count = frame.rdx;

    const string = buf[0..count];
    const process = scheduler.getCurrentProcess() orelse {
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) {
        return errno.EBADF;
    }

    const file = process.getFile(@intCast(fd)) orelse {
        return errno.EBADF;
    };

    const written = file.write(string) catch |err| {
        log.err("Failed to write to file {d}: {s}", .{ fd, @errorName(err) });
        return errno.EIO;
    };

    return @intCast(written);
}

pub fn writev(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const iov: [*]const File.iovec = @ptrFromInt(frame.rsi);
    const count = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) {
        return errno.EBADF;
    }

    const file = process.getFile(@intCast(fd)) orelse {
        return errno.EBADF;
    };

    const n = file.writev(iov[0..count]) catch |err| {
        log.err("Failed to write to file {d}: {s}", .{ fd, @errorName(err) });
        return errno.EIO;
    };

    return @intCast(n);
}
