//! Sector 0-15:   System area (unused, legacy)
//! Sector 16:     Primary Volume Descriptor (PVD)
//! Sector 17+:    More volume descriptors (ended by Volume Descriptor Set Terminator)
//! After VDs:     Path tables, directories, files

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.iso9660);

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
        return std.mem.eql(u8, self.id, "CD001") and self.version == 1;
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
        return base[@sizeOf(DirEntry) .. @sizeOf(DirEntry) + self.len_of_file_name];
    }

    pub fn systemUse(self: *const DirEntry) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        // name + padding byte if name length is even
        const name_end = @sizeOf(DirEntry) + self.len_of_file_name;
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
        return self.name_first_byte == 0x00;
    }

    pub fn isParentDir(self: *const DirEntry) bool {
        return self.name_first_byte == 0x01;
    }

    pub fn isDirectory(self: *const DirEntry) bool {
        return self.file_flags.directory;
    }

    // strips ";1" version suffix from filenames
    pub fn fileNameClean(self: *const DirEntry) []const u8 {
        const name = self.fileName();
        if (std.mem.indexOf(u8, name, ";")) |i| {
            return name[0..i];
        }
        return name;
    }
};

pub const PathTable = extern struct {
    length: u8,
    extended_attribute_length: u8, // length of extended attribute
    location_of_extent: u32, // format depening on where it is L-Table (little endian) or M-Table (big endian)
    index: u16,

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

fn getPVD() *const PrimaryVolumeDescriptor {}
