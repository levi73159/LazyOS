const std = @import("std");
const root = @import("root");
const SyscallFrame = @import("../syscall.zig").SyscallFrame;
const errno = @import("errno.zig");
const scheduler = root.proc.scheduler;
const File = root.fs.File;
const saftey = @import("safety.zig");

const log = std.log.scoped(._sysvfs);

// check these things:
// - is in user space
// - don't overflow
// - everypage is useraccess
// - access is equal to page access (write for sys_read)
// returns true for valid
// false for invalid
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

    pub fn fromMetadata(meta: *const root.fs.FileSystem.Metadata) error{Overflow}!LinuxStat {
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
            return error.Overflow;
        const block_size = std.math.cast(i64, meta.block_size) orelse
            return error.Overflow;
        const blocks = std.math.cast(i64, meta.blocks) orelse
            return error.Overflow;

        return LinuxStat{
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
    }
};

comptime {
    std.debug.assert(@sizeOf(LinuxStat) == 144);
    std.debug.assert(@offsetOf(LinuxStat, "st_mode") == 24);
    std.debug.assert(@offsetOf(LinuxStat, "st_size") == 48);
    std.debug.assert(@offsetOf(LinuxStat, "st_atime") == 72);
}

const validateUserRange = saftey.validateUserRange;

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

fn copyUserIovecs(addr: usize, count: usize, access: saftey.UserAccess, buffer: []File.iovec) i64 {
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
    const n = file.read(ptr[0..count]) catch |err| switch (err) {
        error.PermissionDenied => {
            return errno.EACCES;
        },
        error.Interrupted => {
            return errno.EINTR;
        },
        else => {
            log.err("Error reading file: {s}", .{@errorName(err)});
            return errno.EIO;
        },
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

// TODO: impl this
pub fn openat(frame: *SyscallFrame) i64 {
    var path_buffer: [MAX_PATH]u8 = undefined;
    const path = copyUserPath(frame.rsi, &path_buffer) catch |err| {
        return if (err == error.NameTooLong) errno.ENAMETOOLONG else errno.EFAULT;
    };
    log.warn("openat: path={s}", .{path});
    return errno.ENOENT;
}

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

    if (request > std.math.maxInt(u32)) {
        log.err("request is to big: must be within u32 limit, request: 0x{x}, {0d}", .{request});
        return errno.EINVAL;
    }

    const info = file.ioctlInfo(@intCast(request)) orelse return errno.ENOTTY;
    const access: saftey.UserAccess = @enumFromInt(@intFromEnum(info.access));
    if (!validateUserRange(arg, info.size, access)) return errno.EFAULT;

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

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    log.info("Opening file: {s}", .{path});

    const flags: std.os.linux.O = @bitCast(@as(u32, @intCast(frame.rsi)));
    var file = root.fs.FileSystem.getGlobal().openFrom(&process.cwd.handle, path) catch |err| {
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
        const dest: [*]u8 = @ptrFromInt(addr);
        const result = LinuxStat.fromMetadata(&meta) catch return errno.EOVERFLOW;
        @memcpy(dest[0..@sizeOf(LinuxStat)], std.mem.asBytes(&result));
        return 0;
    }

    return errno.EBADF;
}

pub fn lstat(frame: *SyscallFrame) i64 {
    var path_buffer: [MAX_PATH]u8 = undefined;
    const path = copyUserPath(frame.rdi, &path_buffer) catch |err| {
        return if (err == error.NameTooLong)
            errno.ENAMETOOLONG
        else
            errno.EFAULT;
    };

    const addr = frame.rsi;

    const meta = root.fs.FileSystem.getGlobal().stat(path) catch |err| return convertErrorToErrno(err);

    if (!validateUserRange(addr, @sizeOf(LinuxStat), .write)) {
        return errno.EFAULT;
    }

    const result = LinuxStat.fromMetadata(&meta) catch return errno.EOVERFLOW;
    const dest: [*]u8 = @ptrFromInt(addr);
    @memcpy(dest[0..@sizeOf(LinuxStat)], std.mem.asBytes(&result));

    return 0;
}

pub fn getcwd(frame: *SyscallFrame) i64 {
    const buf_addr = frame.rdi;
    const size = frame.rsi;

    const proc = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    const needed = proc.cwd.path.len + 1;
    if (size < needed) return errno.ERANGE;

    if (!validateUserRange(buf_addr, needed, .write)) {
        return errno.EFAULT;
    }

    const dest: [*]u8 = @ptrFromInt(buf_addr);
    @memcpy(dest[0 .. needed - 1], proc.cwd.path);
    dest[needed - 1] = 0;

    return @intCast(needed);
}

pub fn getdents64(frame: *SyscallFrame) i64 {
    const dirent64 = std.os.linux.dirent64;

    const fd = frame.rdi;
    const buf_addr = frame.rsi;
    const count = frame.rdx;

    const proc = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
    const file = proc.getFile(@intCast(fd)) orelse {
        return errno.EBADF;
    };

    if (!file.handle.flags.readable) return errno.EACCES;
    if (file.handle.metadata.kind != .directory) return errno.ENOTDIR;

    if (count == 0) return errno.EINVAL;
    if (count > std.math.maxInt(isize)) return errno.EINVAL;
    if (!validateUserRange(buf_addr, count, .write)) return errno.EFAULT;

    const buf: [*]u8 = @ptrFromInt(buf_addr);
    const slice = buf[0..count];

    if (file.dir_iterator == null) {
        file.dir_iterator = file.it() catch |err| {
            log.err("Failed to get directory iterator for fd {d}: {s}", .{ fd, @errorName(err) });
            return errno.EIO;
        };
    }
    const it = &file.dir_iterator.?;

    var total_written: usize = 0;
    while (true) {
        if (file.dir_pending == null) {
            file.dir_pending = it.next() catch |err| {
                log.err("Failed to read directory entry for fd {d}: {s}", .{ fd, @errorName(err) });
                return if (total_written > 0) @intCast(total_written) else errno.EIO;
            };
        }
        // Keep the entry (and its borrowed name) until it has been copied.
        // Do not advance the iterator while an entry is pending.
        const entry = file.dir_pending orelse break;
        const name = entry.name;
        const name_offset = @offsetOf(dirent64, "name");
        const needed_unaligned = name_offset + name.len + 1;
        const needed = std.mem.alignForward(usize, needed_unaligned, 8);

        if (needed > std.math.maxInt(u16)) {
            log.err("Directory entry too large for fd {d}: needed {d} bytes", .{ fd, needed });
            return if (total_written > 0) @intCast(total_written) else errno.E2BIG;
        }

        if (needed > slice.len - total_written) {
            // Leave pending_entry untouched for the next syscall.
            if (total_written == 0) return errno.EINVAL;
            break;
        }

        const dest = slice[total_written .. total_written + needed];

        const dirent = dirent64{
            .ino = entry.info.inode,
            .off = file.dir_offset + 1,
            .reclen = @intCast(needed),
            .type = switch (entry.info.kind) {
                .regular => std.os.linux.DT.REG,
                .directory => std.os.linux.DT.DIR,
                .character_device => std.os.linux.DT.CHR,
                .block_device => std.os.linux.DT.BLK,
                .symlink => std.os.linux.DT.LNK,
                .pipe => std.os.linux.DT.FIFO,
                .socket => std.os.linux.DT.SOCK,
            },
            .name = undefined,
        };

        @memset(dest, 0);
        @memcpy(dest[0..name_offset], std.mem.asBytes(&dirent)[0..name_offset]);
        @memcpy(dest[name_offset .. name_offset + name.len], name);

        total_written += needed;
        file.dir_offset += 1;
        file.dir_pending = null;
    }

    return @intCast(total_written);
}

pub fn fcntl(frame: *SyscallFrame) i64 {
    const fd = frame.rdi;
    const cmd = frame.rsi;
    const arg = frame.rdx;

    log.debug("fcntl: fd={d}, cmd={d}, arg={x}", .{ fd, cmd, arg });

    if (fd > std.math.maxInt(u8)) return errno.EBADF;
    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    const file = process.getFile(@intCast(fd)) orelse {
        return errno.EBADF;
    };

    switch (cmd) {
        std.os.linux.F.GETFD => {
            return @intCast(process.fd_table.getFlags(@intCast(fd)));
        },
        std.os.linux.F.SETFD => {
            if (arg > std.math.maxInt(u32)) {
                log.err("fcntl: arg is too large for SETFD: {x}", .{arg});
                return errno.EINVAL;
            }
            // TODO: support other flags
            if (arg & ~@as(u64, std.os.linux.FD_CLOEXEC) != 0) {
                log.warn("fcntl: arg has unsupported flags for SETFD: {x}", .{arg});
            }
            process.fd_table.setFlags(@intCast(fd), @intCast(arg));
            return 0;
        },
        std.os.linux.F.GETFL => {
            return if (file.handle.flags.readable and file.handle.flags.writable)
                O_RDWR
            else if (file.handle.flags.readable)
                O_RDONLY
            else if (file.handle.flags.writable)
                O_WRONLY
            else
                0;
        },
        else => {
            log.err("Unsupported fcntl command: {d}", .{cmd});
            return errno.EINVAL;
        },
    }
}

fn getDirHandle(process: *root.proc.Process, dirfd: i32) !*root.fs.FileSystem.Handle {
    if (dirfd == std.os.linux.AT.FDCWD) {
        return &process.cwd.handle;
    }

    if (dirfd < 0 or dirfd > std.math.maxInt(u8)) {
        return error.InvalidFileDescriptor;
    }

    const file = process.getFile(@intCast(dirfd)) orelse {
        return error.InvalidFileDescriptor;
    };

    if (file.handle.metadata.kind != .directory) {
        return error.NotADirectory;
    }

    return &file.handle;
}

pub fn newfstatat(frame: *SyscallFrame) i64 {
    const dirfd: i32 = @bitCast(@as(u32, @truncate(frame.rdi)));
    const user_path = frame.rsi;
    const statbuf = frame.rdx;
    const flags = frame.r10;

    const process = scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    var path_buffer: [MAX_PATH]u8 = undefined;
    const path = copyUserPath(user_path, &path_buffer) catch |err| {
        return if (err == error.NameTooLong) errno.ENAMETOOLONG else errno.EFAULT;
    };

    if (!validateUserRange(statbuf, @sizeOf(LinuxStat), .write)) {
        return errno.EFAULT;
    }

    if (dirfd > std.math.maxInt(u8)) return errno.EBADF;

    const allowed_flags: u64 = std.os.linux.AT.SYMLINK_NOFOLLOW | std.os.linux.AT.EMPTY_PATH | std.os.linux.AT.NO_AUTOMOUNT;
    if (flags & ~allowed_flags != 0) {
        log.err("newfstatat: unsupported flags: {x}", .{flags});
        return errno.EINVAL;
    }

    if (flags & std.os.linux.AT.SYMLINK_NOFOLLOW != 0) {
        log.warn("newfstatat: AT_SYMLINK_NOFOLLOW is not supported, ignoring...", .{});
    }

    const meta = blk: {
        if (flags & std.os.linux.AT.EMPTY_PATH != 0 and path.len == 0) {
            const dir_handle = getDirHandle(process, dirfd) catch |err| {
                return convertErrorToErrno(err);
            };
            break :blk dir_handle.metadata;
        }

        if (path[0] == '/') {
            // abs path ignore dirfd
            break :blk root.fs.FileSystem.getGlobal().stat(path) catch |err| return convertErrorToErrno(err);
        } else {
            // relative path, use dirfd
            if (dirfd == std.os.linux.AT.FDCWD) {
                break :blk root.fs.FileSystem.getGlobal().statFrom(&process.cwd.handle, path) catch |err| return convertErrorToErrno(err);
            }

            if (dirfd < 0) return errno.EBADF;

            const dir = process.getFile(@intCast(dirfd)) orelse {
                return errno.EBADF;
            };

            if (dir.handle.metadata.kind != .directory) return errno.ENOTDIR;

            break :blk root.fs.FileSystem.getGlobal().statFrom(&dir.handle, path) catch |err| return convertErrorToErrno(err);
        }
    };

    const result = LinuxStat.fromMetadata(&meta) catch return errno.EOVERFLOW;

    const dest: [*]u8 = @ptrFromInt(statbuf);
    @memcpy(dest[0..@sizeOf(LinuxStat)], std.mem.asBytes(&result));

    return 0;
}

pub fn convertErrorToErrno(err: anyerror) i64 {
    return switch (err) {
        error.FileNotFound => errno.ENOENT,
        error.PermissionDenied => errno.EACCES,
        error.NotDirectory => errno.ENOTDIR,
        error.NotImplemented => errno.ENOSYS,
        error.InvalidFileDescriptor => errno.EBADF,
        error.InvalidWorkingDirectory => errno.EINVAL,
        error.Overflow => errno.EOVERFLOW,
        error.Interrupted => errno.EINTR,
        error.NotADirectory => errno.ENOTDIR,
        error.InvalidPath => errno.EINVAL,
        error.InvalidArgument => errno.EINVAL,
        error.InvalidHandle => errno.EBADF,
        else => errno.EIO,
    };
}
