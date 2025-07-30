const std = @import("std");
const DirEntry = @import("DirectoryEntry.zig");

const Self = @This();

jump_bytes: [3]u8,
oem_name: [8]u8,
bytes_per_sector: u16,
sectors_per_cluster: u8,
reserved_sectors: u16,
fat_count: u8,
dir_entries_count: u16,
total_sectors: u16,
media_descriptor_type: u8,
sectors_per_fat: u16,
sectors_per_track: u16,
heads: u16,
hidden_sectors: u32,
large_sector_count: u32,

// extended boot record
ebr_drive_number: u8,
ebr_signature: u8,
ebr_volume_id: [4]u8,
ebr_volume_label: [11]u8,
ebr_system_id: [8]u8,

const RootDir = struct {
    ptr: [*]DirEntry,
    end: u32,
};

pub fn fromReader(reader: std.fs.File.Reader) !Self {
    var self: Self = undefined;

    self.jump_bytes = try reader.readBytesNoEof(3);
    self.oem_name = try reader.readBytesNoEof(8);

    self.bytes_per_sector = try reader.readInt(u16, .little);
    self.sectors_per_cluster = try reader.readByte();
    self.reserved_sectors = try reader.readInt(u16, .little);

    self.fat_count = try reader.readByte();
    self.dir_entries_count = try reader.readInt(u16, .little);

    self.total_sectors = try reader.readInt(u16, .little);

    self.media_descriptor_type = try reader.readByte();

    self.sectors_per_fat = try reader.readInt(u16, .little);
    self.sectors_per_track = try reader.readInt(u16, .little);
    self.heads = try reader.readInt(u16, .little);
    self.hidden_sectors = try reader.readInt(u32, .little);

    self.large_sector_count = try reader.readInt(u32, .little);

    self.ebr_drive_number = try reader.readByte();
    self.ebr_signature = try reader.readByte();

    self.ebr_volume_id = try reader.readBytesNoEof(4);
    self.ebr_volume_label = try reader.readBytesNoEof(11);
    self.ebr_system_id = try reader.readBytesNoEof(8);
    return self;
}

/// self.bytes_per_sector * count must be <= bufferOut.len otherwise it will assert
pub fn readSectors(self: Self, disk: std.fs.File, lba: u32, count: u32, bufferOut: []u8) ![]u8 {
    const size_to_read = self.bytes_per_sector * count;
    std.debug.assert(size_to_read <= bufferOut.len);

    try disk.seekTo(lba * self.bytes_per_sector);
    const bytes_read = try disk.readAll(bufferOut[0..size_to_read]);

    if (bytes_read < size_to_read) {
        return error.EndOfDisk;
    }

    return bufferOut[0..size_to_read];
}

pub fn readFat(self: Self, allocator: std.mem.Allocator, disk: std.fs.File) ![]u8 {
    const bytes = try allocator.alloc(u8, @as(usize, self.sectors_per_fat) * self.bytes_per_sector);
    return self.readSectors(disk, self.reserved_sectors, self.sectors_per_fat, bytes);
}

pub fn readRootDirectory(self: Self, allocator: std.mem.Allocator, disk: std.fs.File) !RootDir {
    const lba = self.reserved_sectors + self.sectors_per_fat * self.fat_count;
    const size = DirEntry.getSizeOf() * self.dir_entries_count;
    var sectors = (size / self.bytes_per_sector);

    if (size % self.bytes_per_sector > 0)
        sectors += 1;

    const bytes = try allocator.alloc(u8, sectors * self.bytes_per_sector);
    defer allocator.free(bytes);

    const bytes_read = try self.readSectors(disk, lba, sectors, bytes);
    var reader = std.io.fixedBufferStream(bytes_read);

    const root = try allocator.alloc(DirEntry, self.dir_entries_count);
    for (root) |*entry| {
        entry.* = try DirEntry.fromReader(reader.reader());
    }
    return RootDir{ .ptr = root.ptr, .end = lba + sectors };
}

pub fn findEntry(self: Self, name: []const u8, root: RootDir) ?DirEntry {
    for (root.ptr[0..self.dir_entries_count]) |entry| {
        if (std.mem.eql(u8, name, &entry.name)) {
            return entry;
        }
    }
    return null;
}

pub fn readFile(self: Self, root: RootDir, entry: DirEntry, fat: []u8, disk: std.fs.File, output_buf: []u8) !void {
    var current_cluster: u16 = entry.cluster_low;

    var output_index: usize = 0;

    while (current_cluster < 0x0FF8) {
        const lba: u32 = root.end + (current_cluster - 2) * self.sectors_per_cluster;

        const bytes = try self.readSectors(disk, lba, self.sectors_per_cluster, output_buf[output_index..]);
        output_index += bytes.len;

        const fat_index: u32 = current_cluster * 3 / 2;
        const fat16: []u16 = @ptrCast(@alignCast(fat[fat_index..]));
        if (current_cluster % 2 == 0) {
            current_cluster = fat16[0] & 0x0FFF;
        } else {
            current_cluster = fat16[0] >> 4;
        }
    }
}
