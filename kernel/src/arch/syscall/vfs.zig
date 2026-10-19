const std = @import("std");
const root = @import("root");
const SyscallFrame = @import("../syscall.zig").SyscallFrame;
const errno = @import("errno.zig");
const scheduler = root.proc.scheduler;
const File = root.fs.File;

const log = std.log.scoped(._sysvfs);

// check these things:
// - is in user space
// - don't overflow
// - everypage is useraccess
// - access is equal to page access (write for sys_read)
// returns true for valid
// false for invalid
const UserAccess = enum { read, write };
const MAX_IOVECS = 1024;
const MAX_PATH = 4096;

const LinuxStat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atime: u64,
    st_atime_nsec: u64,
    st_mtime: u64,
    st_mtime_nsec: u64,
    st_ctime: u64,
    st_ctime_nsec: u64,
    unused: [3]i64,
};

fn validateUserRange(addr: usize, len: usize, access: UserAccess) bool {
    const USER_SPACE_END: usize = 0x0000_8000_0000_0000;
    if (len == 0) return true;

    if (addr == 0) return false;
    if (addr >= USER_SPACE_END) return false;
    if (len > USER_SPACE_END - addr) return false;

    const lastaddr = addr + len - 1;
    var page = std.mem.alignBackward(usize, addr, root.PAGE_SIZE);
    const lastPage = std.mem.alignBackward(usize, lastaddr, root.PAGE_SIZE);

    const current_process = root.proc.scheduler.getCurrentProcess().?;
    const vmem = &current_process.vmem;
    while (true) : (page += root.PAGE_SIZE) {
        _ = vmem.get(page, true, access == .write) orelse return false; // no mapping exist return false

        if (page == lastPage) break;
    }

    return true;
}

// Copy only checked bytes; a terminator may occur before an unmapped page.
fn copyUserPath(addr: usize, buffer: []u8) error{ InvalidAddress, NameTooLong }![]const u8 {
    var copied: usize = 0;
    while (copied < buffer.len) {
        const current = std.math.add(usize, addr, copied) catch return error.InvalidAddress;
        const count = @min(buffer.len - copied, root.PAGE_SIZE - current % root.PAGE_SIZE);

        if (!validateUserRange(current, count, .read)) return error.InvalidAddress;

        const source: [*]const u8 = @ptrFromInt(current);
        // OPTIMIZE: may be faster if we use @memcpy and std.mem.indexOfScalar here
        for (source[0..count]) |byte| {
            if (byte == 0) return buffer[0..copied];
            buffer[copied] = byte;
            copied += 1;
        }
    }
    return error.NameTooLong;
}

fn copyUserIovecs(addr: usize, count: usize, access: UserAccess, buffer: []File.iovec) i64 {
    // Bounds the multiplication and kernel stack usage before accessing memory.
    if (count > MAX_IOVECS or count > buffer.len) return errno.EINVAL;
    if (count == 0) return 0;
    const size = count * @sizeOf(File.iovec);
    if (!validateUserRange(addr, size, .read)) return errno.EFAULT;
    const source: [*]const u8 = @ptrFromInt(addr);

    @memcpy(std.mem.sliceAsBytes(buffer[0..count]), source[0..size]);

    var total: usize = 0;
    for (buffer[0..count]) |vec| {
        if (vec.len > @as(usize, std.math.maxInt(isize)) - total) return errno.EINVAL;
        total += vec.len;
        if (!validateUserRange(vec.base, vec.len, access)) return errno.EFAULT;
    }
    return 0;
}

pub fn read(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const count = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
    const file = process.getFile(@intCast(fd)) orelse {
        log.err("Invalid file descriptor {d}", .{fd});
        return errno.EBADF;
    };

    if (!file.handle.flags.readable) return errno.EACCES;
    if (count == 0) return 0;
    if (count > std.math.maxInt(isize)) return errno.EINVAL;
    if (!validateUserRange(frame.rsi, count, .write)) return errno.EFAULT;

    const ptr: [*]u8 = @ptrFromInt(frame.rsi);
    const n = file.read(ptr[0..count]) catch |err| {
        if (err == error.PermissionDenied) {
            return errno.EACCES;
        }
        log.err("Error reading file: {s}", .{@errorName(err)});
        return errno.EIO;
    };

    return @intCast(n);
}

pub fn preadv(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;

    const count = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
    const file = process.getFile(@intCast(fd)) orelse {
        log.err("Invalid file descriptor {d}", .{fd});
        return errno.EBADF;
    };

    if (!file.handle.flags.readable) return errno.EACCES;

    var iov: [MAX_IOVECS]File.iovec = undefined;
    const status = copyUserIovecs(frame.rsi, count, .write, &iov);

    if (status != 0) return status;
    if (count == 0) return 0;
    const total = file.readv(iov[0..count]) catch |err| {
        if (err == error.PermissionDenied) {
            return errno.EACCES;
        }
        log.err("Failed to read from file {d}: {s}", .{ fd, @errorName(err) });
        return errno.EIO;
    };

    return @intCast(total);
}

pub fn openat(frame: *SyscallFrame) i64 {
    var path_buffer: [MAX_PATH]u8 = undefined;
    const path = copyUserPath(frame.rsi, &path_buffer) catch |err| {
        return if (err == error.NameTooLong) errno.ENAMETOOLONG else errno.EFAULT;
    };
    log.warn("openat: path={s}", .{path});
    return errno.ENOENT;
}

/// BUG: accesses user buffers without request-specific checks.
pub fn ioctl(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const request = frame.rsi;
    const arg = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
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
    const count = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
    const file = process.getFile(@intCast(fd)) orelse {
        return errno.EBADF;
    };

    if (!file.handle.flags.writable) return errno.EACCES;
    if (count == 0) return 0;
    if (count > std.math.maxInt(isize)) return errno.EINVAL;
    if (!validateUserRange(frame.rsi, count, .read)) return errno.EFAULT;

    const buf: [*]const u8 = @ptrFromInt(frame.rsi);
    const written = file.write(buf[0..count]) catch |err| {
        if (err == error.PermissionDenied) {
            return errno.EACCES;
        }
        log.err("Failed to write to file {d}: {s}", .{ fd, @errorName(err) });
        return errno.EIO;
    };

    return @intCast(written);
}

pub fn writev(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const count = frame.rdx;

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
    const file = process.getFile(@intCast(fd)) orelse {
        return errno.EBADF;
    };

    if (!file.handle.flags.writable) return errno.EACCES;

    var iov: [MAX_IOVECS]File.iovec = undefined;
    const status = copyUserIovecs(frame.rsi, count, .read, &iov);

    if (status != 0) return status;
    if (count == 0) return 0;
    const n = file.writev(iov[0..count]) catch |err| {
        if (err == error.PermissionDenied) {
            return errno.EACCES;
        }
        log.err("Failed to write to file {d}: {s}", .{ fd, @errorName(err) });
        return errno.EIO;
    };

    return @intCast(n);
}

pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;
pub const O_ACCMODE = 3;

pub fn open(frame: *SyscallFrame) i64 {
    var path_buffer: [MAX_PATH]u8 = undefined;
    const path = copyUserPath(frame.rdi, &path_buffer) catch |err| {
        return if (err == error.NameTooLong) errno.ENAMETOOLONG else errno.EFAULT;
    };

    log.info("Opening file: {s}", .{path});

    const flags: std.os.linux.O = @bitCast(@as(u32, @intCast(frame.rsi)));
    var file = root.fs.FileSystem.getGlobal().open(path) catch |err| {
        if (err == error.FileNotFound) {
            return errno.ENOENT;
        }
        log.err("Failed to open file {s}: {s}", .{ path, @errorName(err) });
        return errno.EIO;
    };

    switch (flags.ACCMODE) {
        .RDONLY => {
            file.handle.flags = .{
                .readable = true,
                .writable = false,
                .executable = false,
                .seekable = true,
            };
        },
        .WRONLY => {
            file.handle.flags = .{
                .readable = false,
                .writable = true,
                .executable = false,
                .seekable = true,
            };
        },
        .RDWR => {
            file.handle.flags = .{
                .readable = true,
                .writable = true,
                .executable = false,
                .seekable = true,
            };
        },
    }

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (process.fd_table.allocAndSet(file)) |fd| {
        return fd;
    } else {
        return errno.EMFILE;
    }
}

pub fn close(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
    if (process.getFile(@intCast(fd))) |file| {
        file.close();
        process.fd_table.freeHandle(@intCast(fd));
        return 0;
    }

    return errno.EBADF;
}

pub fn fstat(frame: *SyscallFrame) i64 {
    if (frame.rdi > std.math.maxInt(u8)) {
        return errno.EBADF;
    }

    const fd = frame.rdi;
    const addr = frame.rsi;

    if (!validateUserRange(addr, @sizeOf(LinuxStat), .write)) {
        return errno.EFAULT;
    }

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (process.getFile(@intCast(fd))) |file| {
        const meta = file.stat();
        const type_bits: u32 = switch (meta.kind) {
            .regular => 0o100000,
            .directory => 0o040000,
            .character_device => 0o020000,
            .block_device => 0o060000,
            .symlink => 0o120000,
            .pipe => 0o010000,
            .socket => 0o140000,
        };

        const size = std.math.cast(i64, meta.size) orelse
            return errno.EOVERFLOW;
        const block_size = std.math.cast(i64, meta.block_size) orelse
            return errno.EOVERFLOW;
        const blocks = std.math.cast(i64, meta.blocks) orelse
            return errno.EOVERFLOW;

        const result = LinuxStat{
            .st_ino = meta.inode,
            .st_mode = type_bits | @as(u32, meta.perm & 0o7777),
            .st_blksize = block_size,
            .st_blocks = blocks,
            .st_gid = meta.gid,
            .st_uid = meta.uid,
            .st_size = size,
            .st_dev = meta.device_id,
            .st_rdev = meta.special_device_id,
            .st_atime = @bitCast(meta.accessed.seconds),
            .st_atime_nsec = meta.accessed.nanoseconds,
            .st_ctime = @bitCast(meta.changed.seconds),
            .st_ctime_nsec = meta.changed.nanoseconds,
            .st_mtime = @bitCast(meta.modified.seconds),
            .st_mtime_nsec = meta.modified.nanoseconds,
            .st_nlink = meta.link_count,
            .pad0 = 0,
            .unused = std.mem.zeroes([3]i64),
        };

        const dest: [*]u8 = @ptrFromInt(addr);
        @memcpy(dest[0..@sizeOf(LinuxStat)], std.mem.asBytes(&result));
        return 0;
    }

    return errno.EBADF;
}
