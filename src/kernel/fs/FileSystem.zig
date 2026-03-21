const std = @import("std");
const Disk = @import("../Disk.zig");
const Iso9660 = @import("Iso9660.zig");

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

pub const FileSysetmType = enum { iso9660 }; // TODO: add fat32
pub const FsVtable = struct {
    read_file: *const fn (fs: *AnyFs, handle: *Handle, buf: []u8) anyerror!usize,
    open_file: *const fn (fs: *AnyFs, path: []const u8) anyerror!Handle,
    stat: *const fn (fs: *AnyFs, path: []const u8) anyerror!FileInfo,
};

pub const AnyFs = struct {
    disk: Disk, // the disk the filesystem is on
    vtable: FsVtable,
    fs_type: FileSysetmType,

    state: [4096]u8 align(8) = undefined, // filesystem state manage by the filesystem
};

pub const MAX_HANDLES = 16;

const Self = @This();

inner: AnyFs,
handles: [MAX_HANDLES]Handle = [_]Handle{.{}} ** MAX_HANDLES,

pub fn init(disk_num: u8) !Self {
    var disk = try Disk.init(disk_num);

    var anyfs = if (try detectIso9660(&disk)) blk: {
        break :blk try Iso9660.mount(&disk);
    } else return error.UnknownFileSystem;

    anyfs.disk = disk;

    return Self{
        .inner = anyfs,
        .handles = [_]Handle{.{}} ** MAX_HANDLES,
    };
}

fn allocHandle(self: *Self) !struct { *Handle, u8 } {
    for (self.handles, 0..) |h, i| {
        if (!h.opened) {
            self.handles[i].opened = true;
            return .{ &self.handles[i], @intCast(i) };
        }
    }
    return error.NoFreeHandles;
}

pub fn open(self: *Self, path: []const u8) anyerror!u8 {
    const handle = try self.inner.vtable.open_file(&self.inner, path);
    const h, const i = try self.allocHandle();
    h.* = handle;

    return i;
}

pub fn read(self: *Self, handle: u8, buf: []u8) anyerror!usize {
    const h = &self.handles[handle];

    return try self.inner.vtable.read_file(&self.inner, h, buf);
}

pub fn stat(self: *Self, path: []const u8) anyerror!FileInfo {
    return try self.inner.vtable.stat(&self.inner, path);
}

pub fn close(self: *Self, handle: u8) void {
    self.handles[handle].opened = false;
}

// DETECTION FUNCTIONS
fn detectIso9660(disk: *Disk) !bool {
    var buf: [2048]u8 = undefined;
    try disk.read(16, &buf); // sector 16
    return std.mem.eql(u8, buf[1..6], "CD001");
}

fn detectFat32(disk: *Disk) !bool {
    var buf: [512]u8 = undefined;
    try disk.read(0, &buf);
    // check boot sector signature
    if (buf[510] != 0x55 or buf[511] != 0xAA) return false;
    // check FAT type string at offset 82
    return std.mem.eql(u8, buf[82..90], "FAT32   ");
}
