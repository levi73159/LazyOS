const std = @import("std");
const Disk = @import("../Disk.zig");
const Iso9660 = @import("Iso9660.zig");

pub const File = @import("File.zig");

pub const FileType = enum { file, directory };
pub const FileInfo = struct {
    size: u32,
    type: FileType,
};

pub const Handle = struct {
    pos: u32 = 0,
    size: u32 = 0,
    ctx: u64 = 0, // LBA for iso9660, cluster for fat32
    opened: bool = false,
};

pub const FileSysetmType = enum { iso9660 }; // TODO: add fat32/fat16
pub const FsVtable = struct {
    read_file: *const fn (fs: *AnyFs, handle: *Handle, buf: []u8) anyerror!usize,
    open_file: *const fn (fs: *AnyFs, path: []const u8) anyerror!Handle,
    stat: *const fn (fs: *AnyFs, path: []const u8) anyerror!FileInfo,
    iter_dir: *const fn (fs: *AnyFs, path: []const u8) anyerror!DirIterator,
};

pub const DirIterator = struct {
    fs: *AnyFs,
    ctx: [4096]u8 align(8) = undefined, // filesystem stores its state here
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ctx: *[4096]u8) anyerror!?Entry,
        reset: *const fn (ctx: *[4096]u8) void,
    };

    pub const Entry = struct {
        name: []const u8,
        info: FileInfo,
    };

    pub fn next(self: *DirIterator) !?Entry {
        return self.vtable.next(&self.ctx);
    }

    pub fn reset(self: *DirIterator) void {
        self.vtable.reset(&self.ctx);
    }
};

pub const AnyFs = struct {
    vtable: FsVtable,
    fs_type: FileSysetmType,

    state: [4096]u8 align(8) = undefined, // filesystem state manage by the filesystem
};

pub const MAX_HANDLES = 16;

const Self = @This();

pub const Error = error{
    UnknownFileSystem,
    NoFreeHandles,
    FileNotFound,
    NotFile,
    NotDirectory,
    IsADirectory,
    ReadOnlyDisk,
    UnalignedBuffer,
    BadFileHandle,
    Unexpected,
    InvalidSeek,
} || Disk.DiskError;

inner: AnyFs,
handles: [MAX_HANDLES]Handle = [_]Handle{.{}} ** MAX_HANDLES,

var global: ?Self = null;

pub fn init(disk: *Disk) Error!Self {
    const anyfs = if (try detectIso9660(disk)) blk: {
        break :blk Iso9660.mount(disk) catch |err| return convertToError(err);
    } else return error.UnknownFileSystem;

    return Self{
        .inner = anyfs,
        .handles = [_]Handle{.{}} ** MAX_HANDLES,
    };
}

pub fn setGlobal(fs: Self) void {
    global = fs;
}

pub fn getGlobal() *Self {
    return &global.?;
}

fn convertToError(err: anyerror) Error {
    inline for (@typeInfo(Error).error_set.?) |f| {
        if (err == @field(Error, f.name)) return @field(Error, f.name);
    }
    return error.Unexpected;
}

fn allocHandle(self: *Self) Error!struct { *Handle, u8 } {
    for (self.handles, 0..) |h, i| {
        if (!h.opened) {
            self.handles[i].opened = true;
            return .{ &self.handles[i], @intCast(i) };
        }
    }
    return error.NoFreeHandles;
}

pub fn open(self: *Self, path: []const u8) Error!File {
    const handle = self.inner.vtable.open_file(&self.inner, path) catch |err| return convertToError(err);
    const h, const i = try self.allocHandle();
    h.* = handle;

    return File{
        .fs = self,
        .fd = i,
    };
}

pub fn read(self: *Self, handle: u8, buf: []u8) Error!usize {
    if (handle >= MAX_HANDLES) return error.BadFileHandle;
    const h = &self.handles[handle];

    return self.inner.vtable.read_file(&self.inner, h, buf) catch |err| return convertToError(err);
}

pub fn stat(self: *Self, path: []const u8) Error!FileInfo {
    return self.inner.vtable.stat(&self.inner, path) catch |err| return convertToError(err);
}

pub fn seek(self: *Self, handle: u8, offset: u32) Error!void {
    if (handle >= MAX_HANDLES) return error.BadFileHandle;
    const h = &self.handles[handle];

    if (offset > h.size) return error.InvalidSeek;
    h.pos = offset;
}

pub fn close(self: *Self, handle: u8) void {
    if (handle >= MAX_HANDLES) return;
    self.handles[handle].opened = false;
}

pub fn getHandle(self: *Self, handle: u8) error{BadFileHandle}!*Handle {
    if (handle >= MAX_HANDLES) return error.BadFileHandle;
    return &self.handles[handle];
}

pub fn it(self: *Self, path: []const u8) Error!DirIterator {
    const iter = self.inner.vtable.iter_dir(&self.inner, path) catch |err| return convertToError(err);
    return iter;
}

// DETECTION FUNCTIONS
fn detectIso9660(disk: *Disk) Disk.DiskError!bool {
    var buf: [2048]u8 = undefined;
    try disk.readAll(16, &buf); // sector 16
    return std.mem.eql(u8, buf[1..6], "CD001");
}

fn detectFat32(disk: *Disk) !bool {
    var buf: [512]u8 = undefined;
    try disk.readAll(0, &buf);
    // check boot sector signature
    if (buf[510] != 0x55 or buf[511] != 0xAA) return false;
    // check FAT type string at offset 82
    return std.mem.eql(u8, buf[82..90], "FAT32   ");
}
