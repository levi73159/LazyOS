const std = @import("std");
const FS = @import("FileSystem.zig");
const File = @import("File.zig");
const IOReader = std.Io.Reader;
const IOWriter = std.Io.Writer;

const Self = @This();

pub const IoctlInfo = struct {
    size: usize,
    // Access to the user's buffer, from the kernel's perspective.
    access: enum { read, write },
};

pub const FileOps = struct {
    read: *const fn (f: *File, buf: []u8) Error!usize,
    write: *const fn (f: *File, buf: []const u8) Error!usize,
    seek: ?*const fn (f: *File, offset: u32) Error!void,
    ioctl: ?*const fn (f: *File, req: u32, arg: usize) Error!i64,
    ioctlInfo: ?*const fn (f: *File, req: u32) ?IoctlInfo = null,
    it: ?*const fn (f: *File) Error!FS.DirIterator = null,
    close: *const fn (f: *File) void,
};

f_ops: *const FileOps,
handle: FS.Handle,
private: *anyopaque, // AnyFS for a file/dir, TTY for stdin/stdout/stderr

dir_iterator: ?FS.DirIterator = null,
dir_pending: ?FS.DirIterator.Entry = null,
dir_offset: u64 = 0,

pub const Error = FS.Error;
const UnxpectedEOF = error{UnexpectedEOF} || Error;
const AllocReadError = std.mem.Allocator.Error || UnxpectedEOF;

pub fn close(self: *Self) void {
    if (self.dir_iterator) |*iter| iter.deinit();
    self.dir_iterator = null;
    self.dir_pending = null;
    self.dir_offset = 0;
    return self.f_ops.close(self);
}

pub fn read(self: *Self, buf: []u8) Error!usize {
    if (!self.handle.flags.readable) return error.PermissionDenied;
    return self.f_ops.read(self, buf);
}

pub fn ioctl(self: *Self, req: u32, arg: usize) Error!i64 {
    if (self.f_ops.ioctl) |f| return f(self, req, arg);
    return error.NotImplemented;
}

pub fn ioctlInfo(self: *Self, req: u32) ?IoctlInfo {
    if (self.f_ops.ioctl == null) return null;
    if (self.f_ops.ioctlInfo) |f| return f(self, req);
    return null;
}

pub fn readAlloc(self: *Self, allocator: std.mem.Allocator) AllocReadError![]u8 {
    const handle = self.handle;

    // calculate how much is left to read, also adds a check for overflow
    const left = if (handle.pos >= handle.size)
        0
    else
        handle.size - handle.pos;

    const buf = try allocator.alloc(u8, left);
    errdefer allocator.free(buf);

    const result = try self.readAll(buf);
    if (result.len != left) {
        @branchHint(.unlikely);
        std.log.err("Size mismatch: expected {d}, got {d}", .{
            left, result.len,
        });
        return error.UnexpectedEOF;
    }
    return result;
}

pub fn readAll(self: *Self, buf: []u8) Error![]u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try self.read(buf[total..]);
        if (n == 0) break; // EOF
        total += n;
    }
    return buf[0..total];
}

pub fn write(self: *Self, buf: []const u8) Error!usize {
    if (!self.handle.flags.writable) return error.PermissionDenied;
    return self.f_ops.write(self, buf);
}

pub inline fn stat(self: *Self) FS.Metadata {
    return self.handle.metadata;
}

pub const iovec = struct {
    base: u64,
    len: u64,
};

pub fn writev(self: *Self, iovecs: []const iovec) Error!usize {
    if (!self.handle.flags.writable) return error.PermissionDenied;
    var written: u64 = 0;
    for (iovecs) |vec| {
        if (vec.len == 0) continue; // skip empty vectors
        if (vec.base == 0) continue; // skip NULL pointers
        const ptr: [*]const u8 = @ptrFromInt(vec.base);
        const slice = ptr[0..vec.len];
        const n = try self.write(slice);
        written += n;
        if (n < slice.len) break;
    }

    return written;
}

pub fn readv(self: *Self, iovecs: []const iovec) Error!usize {
    var total: u64 = 0;
    for (iovecs) |vec| {
        if (vec.len == 0) continue; // skip empty vectors
        if (vec.base == 0) continue; // skip NULL pointers
        const ptr: [*]u8 = @ptrFromInt(vec.base);
        const slice = ptr[0..vec.len];
        const n = try self.read(slice);
        total += n;
        if (n < slice.len) break;
    }
    return total;
}

/// Creates an iterator at the start of this directory. Caller must deinit it.
pub fn it(self: *Self) Error!FS.DirIterator {
    if (!self.handle.opened) return error.BadFileHandle;
    if (self.handle.metadata.kind != .directory) return error.NotDirectory;
    if (self.f_ops.it) |func| return func(self);
    return error.NotImplemented;
}
