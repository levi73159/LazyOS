const std = @import("std");
const Disk = @import("Disk.zig");

const Self = @This();

pub const PartitionType = enum(u128) {
    bios_boot = 0x4946456465654e746e6f644921686148, // "Hah!IdontNeedEFI" 0x486168214964_6F6E744E65656445_4649
    efi_system = 0x3bc93ec9a0004bba11d2f81fc12a7328,
    linux_filesystem = 0xe47d47d8693d798e477284830fc63daf,
    _,
};

disk: *Disk,
name: [72]u8, // UTF-16
uuid: u128,
type: PartitionType,
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

pub fn deinit(self: *const Self, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
}
