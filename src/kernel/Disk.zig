//! start out using the ATA PIO and ATAPI

const std = @import("std");
const io = @import("arch.zig").io;
const log = std.log.scoped(._disk);

const ata = @import("disks/ata.zig");
const atapi = @import("disks/atapi.zig");

// Primary and Secondary ATA bus, and are almost always controlled by IO ports 0x1F0 through 0x1F7 and 0x170 through 0x177
// Device Control Registers/Alternate Status ports are IO ports 0x3F6, and 0x376
// standard IRQ for the Primary bus is IRQ14 and IRQ15 for the Secondary bus
const Self = @This();

const DISK_0 = 0x1F0;
const DISK_1 = 0x170;

pub const DriveType = enum { ata, atapi };

base: u16,
drive_info: [256]u16,
drive_type: DriveType,
read_only: bool = false,

pub const DiskError = error{
    InvalidDisk,
    UnalignedBuffer,
} || ata.DriveError;

pub fn init(disk: u8) DiskError!Self {
    const base: u16 = if (disk == 0) DISK_0 else if (disk == 1) DISK_1 else return error.InvalidDisk;
    var self = Self{
        .base = base,
        .drive_info = undefined,
        .drive_type = .ata,
        .read_only = false,
    };

    ata.identify(self.base, &self.drive_info) catch |err| {
        if (err == error.DriveIsATAPI) {
            self.drive_type = DriveType.atapi;
            self.read_only = true;
            try atapi.identify(self.base, &self.drive_info);
        } else {
            return err;
        }
    };
    return self;
}

pub fn read(self: Self, lba: u32, buf: []u8) DiskError!void {
    if (buf.len == 0) return;

    switch (self.drive_type) {
        .ata => {
            if (buf.len % ata.SECTOR_SIZE != 0) return error.UnalignedBuffer;
            const sectors = std.mem.bytesAsSlice(ata.Sector, buf);
            try ata.readSectors(self.base, lba, sectors);
        },
        .atapi => {
            if (buf.len % atapi.SECTOR_SIZE != 0) return error.UnalignedBuffer;
            const sectors = std.mem.bytesAsSlice(atapi.Sector, buf);
            try atapi.readSectors(self.base, lba, sectors);
        },
    }
}

pub fn write(self: Self, lba: u32, data: []const u8) DiskError!void {
    if (data.len == 0) return;
    if (self.read_only) return error.ReadOnlyDisk;

    switch (self.drive_type) {
        .ata => {
            if (data.len % ata.SECTOR_SIZE != 0) return error.UnalignedBuffer;
            const sectors = std.mem.bytesAsSlice(ata.Sector, data);
            try ata.writeSectors(self.base, lba, sectors);
        },
        .atapi => {
            return error.ReadOnlyDisk; // atapi is read-only because it is cdrom
        },
    }
}
