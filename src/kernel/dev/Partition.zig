const std = @import("std");
const Disk = @import("Disk.zig");

const Self = @This();

pub const Guid = extern struct {
    data1: u32 align(1),
    data2: u16 align(1),
    data3: u16 align(1),
    data4: [8]u8 align(1),

    pub const efi_system = Guid{
        .data1 = 0xC12A7328,
        .data2 = 0xF81F,
        .data3 = 0x11D2,
        .data4 = .{ 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B },
    };

    pub const bios_boot = Guid{
        .data1 = 0x21686148,
        .data2 = 0x6449,
        .data3 = 0x6E6F,
        .data4 = .{ 0x74, 0x4E, 0x65, 0x65, 0x64, 0x45, 0x46, 0x49 },
    };

    // Linux filesystem data partition (generic)
    pub const linux_filesystem = Guid{
        .data1 = 0x0FC63DAF,
        .data2 = 0x8483,
        .data3 = 0x4772,
        .data4 = .{ 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 },
    };

    // Linux root x86_64 (correct GPT type)
    pub const linux_root_x86_64 = Guid{
        .data1 = 0x4F68BCE3,
        .data2 = 0xE8CD,
        .data3 = 0x4DB1,
        .data4 = .{ 0x96, 0xE7, 0xFB, 0xCA, 0xF9, 0x84, 0xB7, 0x09 },
    };

    pub fn fromBytes(bytes: *const [16]u8) Guid {
        return .{
            .data1 = std.mem.readInt(u32, bytes[0..4], .little),
            .data2 = std.mem.readInt(u16, bytes[4..6], .little),
            .data3 = std.mem.readInt(u16, bytes[6..8], .little),
            .data4 = bytes[8..16].*,
        };
    }

    pub fn eql(a: Guid, b: Guid) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{ self.data1, self.data2, self.data3, self.data4[0], self.data4[1], self.data4[2], self.data4[3], self.data4[4], self.data4[5], self.data4[6], self.data4[7] },
        );
    }

    pub fn asString(self: Guid) []const u8 {
        if (self.eql(Guid.efi_system)) {
            return "EFI System";
        }
        if (self.eql(Guid.bios_boot)) {
            return "BIOS Boot";
        }
        if (self.eql(Guid.linux_filesystem)) {
            return "Linux Filesystem";
        }
        if (self.eql(Guid.linux_root_x86_64)) {
            return "Linux Root x86_64";
        }
        return "Unknown";
    }
};

disk: *Disk,
name: [72]u8, // UTF-16
partuuid: Guid,
guid: Guid,
start_lba: u64,
size_lba: u64,

pub fn read(self: *const Self, offset: usize, buf: []u8) Disk.DiskError!usize {
    const start_offset = self.start_lba * self.disk.sectorSize() + offset;
    const size_bytes = self.size_lba * self.disk.sectorSize();

    std.debug.assert(buf.len <= size_bytes); // on the user to ensure this but assert here for safety

    return self.disk.readOffset(start_offset, buf);
}

pub fn readLba(self: *const Self, lba: u64, buf: []u8) Disk.DiskError!usize {
    const size_bytes = self.size_lba * self.disk.sectorSize();

    std.debug.assert(buf.len <= size_bytes); // on the user to ensure this but assert here for safety

    return self.disk.read(lba, buf);
}

pub fn readAll(self: *const Self, offset: usize, buf: []u8) Disk.DiskError!void {
    const start_offset = self.start_lba * self.disk.sectorSize() + offset;
    const size_bytes = self.size_lba * self.disk.sectorSize();

    std.debug.assert(buf.len <= size_bytes); // on the user to ensure this but assert here for safety

    return self.disk.readOffsetAll(start_offset, buf);
}

pub fn readLbaAll(self: *const Self, lba: u64, buf: []u8) Disk.DiskError!void {
    const size_bytes = self.size_lba * self.disk.sectorSize();

    std.debug.assert(buf.len <= size_bytes); // on the user to ensure this but assert here for safety

    return self.disk.readAll(lba, buf);
}

pub fn deinit(self: *const Self, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
}
