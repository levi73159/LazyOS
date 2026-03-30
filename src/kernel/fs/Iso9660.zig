//! Sector 0-15:   System area (unused, legacy)
//! Sector 16:     Primary Volume Descriptor (PVD)
//! Sector 17+:    More volume descriptors (ended by Volume Descriptor Set Terminator)
//! After VDs:     Path tables, directories, files
//! Sector size

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(._iso9660);
const iterator = @import("iterator.zig");
const Allocator = std.mem.Allocator;
const FS = @import("FileSystem.zig");

const Disk = @import("../Disk.zig");

pub const VolumeDescriptorType = enum(u8) {
    boot_record = 0,
    primary = 1,
    supplementary = 2,
    partition = 3,
    terminator = 255,
};

pub const GenericVolumeDescriptor = extern struct {
    type_code: VolumeDescriptorType,
    id: [5]u8, // always "CD001"
    version: u8, // always 1
    data: [2041]u8,

    pub fn verify(self: *const GenericVolumeDescriptor) bool {
        return std.mem.eql(u8, &self.id, "CD001") and self.version == 1;
    }
};

pub const Int32LSB_MSB = extern struct {
    little_endian_int: u32 align(1),
    big_endian_int: u32 align(1),

    pub fn value(self: *const Int32LSB_MSB) u32 {
        if (builtin.cpu.arch.endian() == .little) {
            return self.little_endian_int;
        } else {
            return self.big_endian_int;
        }
    }

    pub fn set(self: *Int32LSB_MSB, v: u32) void {
        if (builtin.cpu.arch.endian() == .little) {
            self.little_endian_int = v;
            std.mem.writeInt(u32, std.mem.asBytes(&self.big_endian_int), v, .big);
        } else {
            self.big_endian_int = v;
            std.mem.writeInt(u32, std.mem.asBytes(&self.little_endian_int), v, .little);
        }
    }
};

pub const Int16LSB_MSB = extern struct {
    little_endian_int: u16 align(1),
    big_endian_int: u16 align(1),

    pub fn value(self: *const Int16LSB_MSB) u16 {
        if (builtin.cpu.arch.endian() == .little) {
            return self.little_endian_int;
        } else {
            return self.big_endian_int;
        }
    }

    pub fn set(self: *Int16LSB_MSB, v: u16) void {
        if (builtin.cpu.arch.endian() == .little) {
            self.little_endian_int = v;
            std.mem.writeInt(u16, std.mem.asBytes(&self.big_endian_int), v, .big);
        } else {
            self.big_endian_int = v;
            std.mem.writeInt(u16, std.mem.asBytes(&self.little_endian_int), v, .little);
        }
    }
};

pub const BootRecord = extern struct {
    type_code: VolumeDescriptorType, // should be boot_record(0)
    id: [5]u8, // always "CD001"
    version: u8,
    system_id: [32]u8,
    boot_id: [32]u8,
    reserved: [1977]u8, // use by the boot system, since we are in kernel we won't care
};

pub const PrimaryVolumeDescriptor = extern struct {
    type_code: VolumeDescriptorType, // should be primary(1)
    id: [5]u8, // always "CD001"
    version: u8,
    __unused1: u8 = 0,
    system_id: [32]u8,
    volume_id: [32]u8,
    __unused2: u64 = 0,
    volume_space_size: Int32LSB_MSB,
    __unused3: [32]u8 = [_]u8{0} ** 32,
    volume_set_size: Int16LSB_MSB,
    volume_sequence_number: Int16LSB_MSB,
    logical_block_size: Int16LSB_MSB,
    path_table_size: Int32LSB_MSB,
    type_l: u32,
    opt_type_l: u32,
    type_m: u32,
    opt_type_m: u32,
    dir_entry: DirEntry,
    volume_set_id: [128]u8,
    publisher_id: [128]u8,
    data_preparer_id: [128]u8,
    application_id: [128]u8,
    copyright_file_id: [37]u8,
    abstract_file_id: [37]u8,
    biblio_file_id: [37]u8,
    create_date_time: [17]u8,
    modify_date_time: [17]u8,
    expire_date_time: [17]u8,
    effective_date_time: [17]u8,
    file_structure_version: u8,
    __unused4: u8 = 0,
    application_used: [512]u8, // contents not defined by ISO 9660
    __reserved: [653]u8,
};

pub const FileFlags = packed struct(u8) {
    /// If set, the existence of this file need not be made known to the user (basically a 'hidden' flag.
    hidden: bool = false,
    /// If set, this record describes a directory (in other words, it is a subdirectory extent).
    directory: bool = false,
    // If set, this file is an "Associated File".
    asscociated: bool = false,
    /// If set, the extended attribute record contains information about the format of this file.
    extended: bool = false,
    /// If set, owner and group permissions are set in the extended attribute record.
    permissions: bool = false,
    __reserved: u2 = 0,
    // If set, this is not the final directory record for this file (for files spanning several extents, for example files over 4GiB long.
    fragmented: bool = false,
};

pub const DateTime = extern struct {
    year: u8, // number of years since 1900
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23
    minute: u8, // 0-59
    second: u8, // 0-59
    offset_from_gmt: u8, // Offset from GMT in 15 minute intervals from -48 (West) to +52 (East)
};

pub const DirEntry = extern struct {
    length: u8,
    extended_attribute_length: u8,
    location_of_extent: Int32LSB_MSB,
    data_length: Int32LSB_MSB,
    date_time: DateTime,
    file_flags: FileFlags,
    file_unit_size: u8,
    interleave_gap_size: u8,
    volume_sequence_number: Int16LSB_MSB,
    len_of_file_name: u8,
    name_first_byte: u8,

    pub fn fileName(self: *const DirEntry) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return base[@sizeOf(DirEntry) - 1 .. @sizeOf(DirEntry) - 1 + self.len_of_file_name];
    }

    pub fn systemUse(self: *const DirEntry) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        // name + padding byte if name length is even
        const name_end = @sizeOf(DirEntry) + self.len_of_file_name - 1;
        const padded_end = if (self.len_of_file_name % 2 == 0) name_end + 1 else name_end;
        const total = self.length;
        if (padded_end >= total) return &.{};
        return base[padded_end..total];
    }

    pub fn next(self: *const DirEntry) ?*const DirEntry {
        if (self.length == 0) return null;
        const base: [*]const u8 = @ptrCast(self);
        return @ptrCast(@alignCast(base + self.length));
    }

    pub fn isCurrentDir(self: *const DirEntry) bool {
        return self.name_first_byte == 0x00; // 0x00 == '.'
    }

    pub fn isParentDir(self: *const DirEntry) bool {
        return self.name_first_byte == 0x01; // 0x01 == '..'
    }

    pub fn isDirectory(self: *const DirEntry) bool {
        return self.file_flags.directory;
    }

    // strips ";1" version suffix from filenames and trailing .
    pub fn fileNameClean(self: *const DirEntry) []const u8 {
        var name = self.fileName();
        if (std.mem.indexOf(u8, name, ";")) |i| {
            name = name[0..i];
        }
        if (std.mem.endsWith(u8, name, ".")) {
            name = name[0 .. name.len - 1];
        }
        return name;
    }
};

pub const PathTable = extern struct {
    length: u8,
    extended_attribute_length: u8, // length of extended attribute
    location_of_extent: u32 align(1), // format depening on where it is L-Table (little endian) or M-Table (big endian)
    index: u16 align(1),

    pub fn getName(self: *const PathTable) [*]const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return base[@sizeOf(PathTable)..];
    }
};

fn comptimeEql(comptime a: anytype, comptime b: anytype) void {
    if (a != b) {
        @compileError(std.fmt.comptimePrint("size mismatch: {} != {}", .{ a, b }));
    }
}

comptime {
    comptimeEql(@sizeOf(GenericVolumeDescriptor), 2048);
    comptimeEql(@sizeOf(BootRecord), 2048);
    comptimeEql(@sizeOf(PrimaryVolumeDescriptor), 2048);
    comptimeEql(@sizeOf(DateTime), 7);
    comptimeEql(@sizeOf(Int32LSB_MSB), 8);
    comptimeEql(@sizeOf(Int16LSB_MSB), 4);
    comptimeEql(@sizeOf(FileFlags), 1);
    comptimeEql(@sizeOf(DirEntry), 34);
}

const Self = @This();

disk: *Disk,
pvd: PrimaryVolumeDescriptor,

pub fn init(disk: *Disk) !Self {
    var buf: [2048]u8 align(@alignOf(PrimaryVolumeDescriptor)) = undefined;
    try disk.readAll(16, &buf);

    const generic: *const GenericVolumeDescriptor = @ptrCast(&buf);
    if (!generic.verify()) return error.NotISO9660;

    const pvd: *const PrimaryVolumeDescriptor = @ptrCast(&buf);
    if (pvd.type_code != .primary) return error.NoPrimaryVolumeDescriptor;

    log.info("Volume id: {s}", .{pvd.volume_id});

    return Self{
        .disk = disk,
        .pvd = pvd.*,
    };
}

pub fn readSector(self: *const Self, lba: u32, buf: *[2048]u8) !void {
    if (lba >= self.pvd.volume_space_size.value()) {
        log.err("LBA {d} out of range (max {d})", .{ lba, self.pvd.volume_space_size.value() });
        return error.LBAOutOfRange;
    }
    try self.disk.readAll(lba, buf);
}

pub fn rootDir(self: *const Self) *const DirEntry {
    return &self.pvd.dir_entry;
}

const IteratorContext = struct {
    disk: *Disk,
    dir: *const DirEntry,
    buf: [2048]u8,
    bytes_read: u32,
    sector: u32,
    offset: u32,

    pub fn readSector(self: *IteratorContext, _lba: u32, buf: *[2048]u8) !void {
        try self.disk.read(_lba, buf);
    }

    pub fn init(disk: *Disk, dir: *const DirEntry) IteratorContext {
        var self: IteratorContext = undefined;
        self.disk = disk;
        self.dir = dir;
        self.reset();
        return self;
    }

    pub fn size(self: *const IteratorContext) u32 {
        return self.dir.data_length.value();
    }

    pub fn sectors(self: *const IteratorContext) u32 {
        return std.math.divCeil(u32, self.size(), 2048) catch unreachable;
    }

    pub fn lba(self: *const IteratorContext) u32 {
        return self.dir.location_of_extent.value();
    }

    pub fn reset(self: *IteratorContext) void {
        self.bytes_read = 0;
        self.sector = 0;
        self.offset = 0;
        self.readSector(self.lba(), &self.buf) catch |err| {
            log.err("Failed to read sector: {}", .{err});
            return;
        };
    }

    pub fn next(self: *IteratorContext) !?*const DirEntry {
        if (self.sector >= self.sectors()) return null;
        if (self.bytes_read >= self.size()) return null;

        if (self.offset >= self.buf.len) {
            self.offset = 0;
            self.sector += 1;
            try self.readSector(self.lba() + self.sector, &self.buf);
        }

        const entry: *const DirEntry = @ptrCast(@alignCast(&self.buf[self.offset]));
        if (entry.length == 0) return null;
        self.bytes_read += entry.length;
        self.offset += entry.length;

        if (entry.isCurrentDir() or entry.isParentDir()) {
            return self.next();
        }

        return entry;
    }
};

/// NOTE: does not iterate recursively, only iterates one level
pub const Iterator = iterator.Iterator(DirEntry, IteratorContext, .{ .next = &IteratorContext.next, .reset = &IteratorContext.reset });
pub fn it(self: *const Self, entry: *const DirEntry) Iterator {
    return Iterator{ .ctx = IteratorContext.init(self.disk, entry) };
}

/// If callback returns true, exit early
pub fn walk(self: *const Self, dir: *const DirEntry, ctx: anytype, callback: *const fn (c: @TypeOf(ctx), *const DirEntry) bool) !void {
    if (!dir.isDirectory()) return error.NotDirectory;

    const size = dir.data_length.value();
    const lba = dir.location_of_extent.value();

    const sectors = std.math.divCeil(u32, size, 2048);

    var buf: [2048]u8 = undefined;
    var bytes_read: u32 = 0;

    var s: u32 = 0;
    while (s < sectors) : (s += 1) {
        try self.readSector(lba + s, &buf);
        var offset: usize = 0;
        while (offset < buf.len) {
            const entry: *const DirEntry = @ptrCast(@alignCast(&buf[offset]));
            if (entry.length == 0) break; // end of entries sectors
            if (bytes_read >= size) return; // end of directory
            if (!entry.isCurrentDir() and !entry.isParentDir()) {
                if (callback(ctx, entry)) return;
            }
            bytes_read += entry.length;
            offset += entry.length;
        }
    }
}

// memory used here will be freed
pub fn find(self: *const Self, path: []const u8) !?DirEntry {
    return vfsFind(self.disk, &self.pvd, path);
}

// VFS compatiable find
fn vfsFind(disk: *Disk, pvd: *const PrimaryVolumeDescriptor, path: []const u8) !?DirEntry {
    var current = pvd.dir_entry;
    var remaining = path;

    remaining = std.mem.trim(u8, remaining, "/");
    if (remaining.len == 0) return current;

    while (remaining.len > 0) {
        if (!current.isDirectory()) {
            log.err("File is not a directory", .{});
            return error.NotDirectory;
        }

        const slash = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
        const name = remaining[0..slash];
        const entry = try vfsFindEntry(disk, &current, name) orelse return null;
        current = entry;

        if (slash == remaining.len) break;
        remaining = remaining[slash + 1 ..];
    }

    return current;
}

// FIND A FILE IN DIRECTORY, and only in that directory, make sure to to not pass a path to it
fn vfsFindEntry(disk: *Disk, dir: *const DirEntry, name: []const u8) !?DirEntry {
    if (name.len == 1 and name[0] == '.') return dir.*;

    const lba = dir.location_of_extent.value();
    const size = dir.data_length.value();

    const sectors = std.math.divCeil(u32, size, 2048) catch unreachable;

    var buf: [2048]u8 = undefined;
    var s: u32 = 0;

    log.debug("find {s} in {x} - {x}", .{ name, lba, lba + sectors });

    while (s < sectors) : (s += 1) {
        try disk.readAll(lba + s, &buf);
        var offset: usize = 0;
        while (offset < buf.len) {
            const entry: *const DirEntry = @ptrCast(@alignCast(&buf[offset]));
            if (entry.length == 0) break; // end of entries sectors
            if (std.mem.eql(u8, name, "..") and entry.isParentDir()) {
                return entry.*;
            }
            if (!entry.isCurrentDir() and !entry.isParentDir()) {
                if (std.ascii.eqlIgnoreCase(entry.fileNameClean(), name)) {
                    return entry.*;
                }
            }
            offset += entry.length;
        }
    }

    return null;
}

pub fn readFile(self: *const Self, entry: *const DirEntry, buf: []u8) ![]u8 {
    if (entry.isDirectory()) return error.NotFile;
    const lba = entry.location_of_extent.value();
    const size = entry.data_length.value();

    const sectors = std.math.divCeil(u32, size, 2048) catch unreachable;

    var i: usize = 0;

    var sector: u32 = 0;

    var read_buf: [2048]u8 = undefined;
    while (sector < sectors) : (sector += 1) {
        try self.readSector(lba + sector, &read_buf);
        const read_size = @min(read_buf.len, size - i);
        @memcpy(buf[i..][0..read_size], read_buf[0..read_size]);
        i += read_size;
    }

    return buf[0..size];
}

// -----------------------------
// VFS Implementation of functions
// -----------------------------
// pub const FsVtable = struct {
//     read_file: *const fn (fs: *AnyFs, handle: *Handle, buf: []u8) anyerror!usize,
//     open_file: *const fn (fs: *AnyFs, path: []const u8) anyerror!Handle,
//     stat: *const fn (fs: *AnyFs, path: []const u8) anyerror!FileInfo,
// };

fn vfsOpenFile(fs: *FS.AnyFs, path: []const u8) anyerror!FS.Handle {
    const self: *const Self = @ptrCast(&fs.state);

    const entry = try self.find(path) orelse return error.FileNotFound;
    if (entry.isDirectory()) return error.NotFile;

    return FS.Handle{
        .pos = 0,
        .size = entry.data_length.value(),
        .ctx = entry.location_of_extent.value(),
        .opened = true,
    };
}

fn vfsReadFile(fs: *FS.AnyFs, handle: *FS.Handle, buf: []u8) anyerror!usize {
    const self: *const Self = @ptrCast(&fs.state);

    if (handle.pos >= handle.size) return 0; // EOF

    const lba: u32 = @truncate(handle.ctx);
    const remaining = handle.size - handle.pos;
    const to_read = @min(remaining, buf.len);

    var secotr_buf: [2048]u8 = undefined;
    var done: u32 = 0;

    while (done < to_read) {
        const abs_pos = handle.pos + done;
        const sector_off = abs_pos / 2048;
        const byte_off = abs_pos % 2048;

        try self.readSector(lba + sector_off, &secotr_buf);

        const chunk = @min(2048 - byte_off, to_read - done);
        @memcpy(buf[done..][0..chunk], secotr_buf[byte_off..][0..chunk]);
        done += chunk;
    }

    handle.pos += done;
    return done;
}

fn vfsStat(fs: *FS.AnyFs, path: []const u8) anyerror!FS.FileInfo {
    const self: *const Self = @ptrCast(&fs.state);

    const entry = try self.find(path) orelse return error.FileNotFound;

    return FS.FileInfo{
        .size = entry.data_length.value(),
        .type = if (entry.isDirectory()) .directory else .file,
    };
}

const VfsDirIterCtx = struct {
    disk: *Disk,
    lba: u32,
    size: u32,
    sectors: u32,
    buf: [2048]u8 align(@alignOf(DirEntry)),
    bytes_read: u32,
    sector: u32,
    offset: u32,

    pub fn init(disk: *Disk, entry: *const DirEntry) VfsDirIterCtx {
        var ctx: VfsDirIterCtx = undefined;
        ctx.disk = disk;
        ctx.lba = entry.location_of_extent.value();
        ctx.size = entry.data_length.value();
        ctx.sectors = std.math.divCeil(u32, ctx.size, 2048) catch unreachable;
        ctx.bytes_read = 0;
        ctx.sector = 0;
        ctx.offset = 0;
        disk.readAll(ctx.lba, &ctx.buf) catch {};
        return ctx;
    }

    pub fn next(raw: *[4096]u8) anyerror!?FS.DirIterator.Entry {
        const ctx: *VfsDirIterCtx = @ptrCast(@alignCast(raw));

        while (true) {
            if (ctx.sector >= ctx.sectors) return null;
            if (ctx.bytes_read >= ctx.size) return null;

            if (ctx.offset >= ctx.buf.len) {
                ctx.sector += 1;
                if (ctx.sector >= ctx.sectors) return null;
                ctx.offset = 0;
                try ctx.disk.readAll(ctx.lba + ctx.sector, &ctx.buf);
            }

            const entry: *const DirEntry = @ptrCast(@alignCast(&ctx.buf[ctx.offset]));
            if (entry.length == 0) return null;

            ctx.bytes_read += entry.length;
            ctx.offset += entry.length;

            if (entry.isCurrentDir() or entry.isParentDir()) continue;

            return FS.DirIterator.Entry{
                .name = entry.fileNameClean(),
                .info = .{
                    .size = entry.data_length.value(),
                    .type = if (entry.isDirectory()) .directory else .file,
                },
            };
        }
    }

    pub fn reset(raw: *[4096]u8) void {
        const ctx: *VfsDirIterCtx = @ptrCast(@alignCast(raw));
        ctx.bytes_read = 0;
        ctx.sector = 0;
        ctx.offset = 0;
        ctx.disk.readAll(ctx.lba, &ctx.buf) catch {};
    }
};

const vfs_dir_iter_vtable = FS.DirIterator.VTable{
    .next = VfsDirIterCtx.next,
    .reset = VfsDirIterCtx.reset,
};

fn vfsIterDir(fs: *FS.AnyFs, path: []const u8) anyerror!FS.DirIterator {
    const self: *const Self = @ptrCast(@alignCast(&fs.state));

    const entry = try self.find(path) orelse return error.FileNotFound;
    if (!entry.isDirectory()) return error.NotDirectory;

    var iter = FS.DirIterator{
        .fs = fs,
        .vtable = &vfs_dir_iter_vtable,
    };

    // init the context into the iterator's inline storage
    const ctx: *VfsDirIterCtx = @ptrCast(@alignCast(&iter.ctx));
    ctx.* = VfsDirIterCtx.init(self.disk, &entry);
    return iter;
}

pub fn mount(disk: *Disk) !FS.AnyFs {
    var iso9660 = try init(disk);
    var anyfs = FS.AnyFs{ .vtable = .{
        .read_file = &vfsReadFile,
        .open_file = &vfsOpenFile,
        .stat = &vfsStat,
        .iter_dir = &vfsIterDir,
    }, .fs_type = .iso9660 };
    const bytes = std.mem.asBytes(&iso9660);
    @memcpy(anyfs.state[0..bytes.len], bytes);
    return anyfs;
}
