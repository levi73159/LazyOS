const std = @import("std");
const FS = @import("FileSystem.zig");
const File = @import("File.zig");
const IOReader = std.Io.Reader;
const IOWriter = std.Io.Writer;

const Self = @This();

pub const Reader = struct {
    fs: *FS,
    fd: u8,
    err: ?Error = null,
    pos: u64 = 0,
    size: ?u64 = null,
    interface: std.Io.Reader,

    pub fn initInterface(buffer: []u8) std.Io.Reader {
        return std.Io.Reader{
            .vtable = &.{
                .stream = Reader.stream,
                .discard = Reader.discard,
                .readVec = Reader.readVec,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn init(fs: *FS, fd: u8, buffer: []u8) Reader {
        return .{
            .fs = fs,
            .fd = fd,
            .interface = initInterface(buffer),
        };
    }

    // -------------------------------------------------------------------------
    // vtable implementations
    // -------------------------------------------------------------------------

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        var total: usize = 0;

        const handle = r.fs.getHandle(r.fd) catch {
            r.err = error.BadFileHandle;
            return error.ReadFailed;
        };

        for (data) |dest| {
            if (dest.len == 0) continue;
            if (handle.pos >= handle.size) {
                if (total == 0) return error.EndOfStream;
                break;
            }
            const n = r.fs.read(r.fd, dest) catch |err| {
                r.err = err;
                return error.ReadFailed;
            };
            if (n == 0) break;
            r.pos += n;
            total += n;
        }
        return total;
    }

    fn stream(
        io_reader: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const handle = r.fs.getHandle(r.fd) catch return error.ReadFailed;

        if (handle.pos >= handle.size) return error.EndOfStream;

        const remaining: usize = handle.size - handle.pos;
        const to_stream = @min(@intFromEnum(limit), remaining);

        var total: usize = 0;

        while (total < to_stream) {
            // get a writable slice from the writer — as large as possible
            const dest = w.writableSliceGreedy(1) catch return error.WriteFailed;
            const chunk_size = @min(dest.len, to_stream - total);

            const n = r.fs.read(
                r.fd,
                dest[0..chunk_size],
            ) catch |err| {
                r.err = err;
                return error.ReadFailed;
            };

            if (n == 0) {
                r.size = r.pos;
                return error.EndOfStream;
            }

            // tell the writer how many bytes we filled
            w.advance(n);
            total += n;
            r.pos += n;
        }

        return total;
    }

    fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const handle = r.fs.getHandle(r.fd) catch {
            r.err = error.BadFileHandle;
            return error.ReadFailed;
        };

        const remaining = handle.size - handle.pos;
        const delta = @min(@intFromEnum(limit), remaining);

        // advance pos directly — no actual read needed
        handle.pos += @intCast(delta);
        r.pos += delta;
        return delta;
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    pub fn atEnd(r: *Reader) bool {
        const size = r.size orelse return false;
        return r.pos >= size;
    }

    pub fn seekTo(r: *Reader, offset: u64) Error!void {
        const handle = try r.fs.getHandle(r.fd);
        if (offset > handle.size) return error.InvalidSeek;
        handle.pos = @intCast(offset);
        r.pos = offset;
        // invalidate buffer
        r.interface.seek = 0;
        r.interface.end = 0;
    }

    pub fn seekBy(r: *Reader, offset: i64) Error!void {
        const handle = try r.fs.getHandle(r.fd);
        const new_pos = @as(i64, @intCast(handle.pos)) + offset;
        if (new_pos < 0 or new_pos > handle.size) return error.InvalidSeek;
        handle.pos = @intCast(new_pos);
        r.pos = @intCast(new_pos);
        r.interface.seek = 0;
        r.interface.end = 0;
    }
};

pub const FileOps = struct {
    read: *const fn (f: *File, buf: []u8) Error!usize,
    write: *const fn (f: *File, buf: []const u8) Error!usize,
    seek: ?*const fn (f: *File, offset: u32) Error!void,
    ioctl: ?*const fn (f: *File, req: u32, arg: usize) Error!i64,
    close: *const fn (f: *File) void,
};

f_ops: *const FileOps,
handle: FS.Handle,
private: *anyopaque, // AnyFS for a file/dir, TTY for stdin/stdout/stderr

pub const Error = FS.Error;
const UnxpectedEOF = error{UnexpectedEOF} || Error;
const AllocReadError = std.mem.Allocator.Error || Error;

pub fn close(self: *Self) void {
    return self.f_ops.close(self);
}

pub fn read(self: *Self, buf: []u8) Error!usize {
    if (!self.handle.flags.readable) return error.PermissionDenied;
    return self.f_ops.read(self, buf);
}

pub fn ioctl(self: *Self, req: u32, arg: usize) Error!void {
    if (self.f_ops.ioctl) |f| return f(self, req, arg);
    return error.NotImplemented;
}

pub fn readAlloc(self: *Self, allocator: std.mem.Allocator) AllocReadError![]u8 {
    const handle = self.handle;
    // calculate how much is left to read
    const left = handle.size - handle.pos;

    const buf = try allocator.alloc(u8, left);
    errdefer allocator.free(buf);

    const size = try self.read(buf);
    if (size != left) @panic("SIZE MISMATCH: UnexpectedEOF");
    return buf[0..size];
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

pub fn reader(self: *Self, buf: []u8) Reader {
    return Reader.init(self.fs, self.fd, buf);
}
