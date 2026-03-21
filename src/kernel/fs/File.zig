const std = @import("std");
const FS = @import("FileSystem.zig");
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
        const handle = r.fs.getHandle(r.fd) catch {
            r.err = error.BadFileHandle;
            return error.ReadFailed;
        };

        if (handle.pos >= handle.size) {
            r.size = handle.size;
            return error.EndOfStream;
        }

        // read into first buffer in the vec
        const dest = data[0];
        const remaining: usize = handle.size - handle.pos;
        const to_read = @min(dest.len, remaining);

        const n = r.fs.read(
            r.fd,
            dest[0..to_read],
        ) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        if (n == 0) {
            r.size = r.pos;
            return error.EndOfStream;
        }

        r.pos += n;
        return n;
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

fs: *FS,
fd: u8,

const Error = FS.Error;
const UnxpectedEOF = error{UnexpectedEOF} || Error;

pub fn close(self: *const Self) void {
    return self.fs.close(self.fd);
}

pub fn read(self: *const Self, buf: []u8) Error!usize {
    return self.fs.read(self.fd, buf);
}

pub fn readAlloc(self: *const Self, allocator: std.mem.Allocator) UnxpectedEOF![]u8 {
    const handle = try self.fs.getHandle(self.fd);
    // calculate how much is left to read
    const left = handle.size - handle.pos;

    const buf = try allocator.alloc(u8, left);
    errdefer allocator.free(buf);

    const size = try self.read(buf);
    if (size != left) return error.UnexpectedEOF; //
    return buf[0..size];
}

pub fn readAll(self: *const Self, buf: []u8) Error![]u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try self.read(buf[total..]);
        if (n == 0) break; // EOF
        total += n;
    }
    return buf[0..total];
}

pub fn reader(self: *const Self, buf: []u8) Reader {
    return Reader.init(self.fs, self.fd, buf);
}
