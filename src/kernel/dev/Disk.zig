//! start out using the ATA PIO and ATAPI

const std = @import("std");
const io = @import("root").io;
const log = std.log.scoped(._disk);

const ata = @import("disks/ata.zig");
const atapi = @import("disks/atapi.zig");
const ahci = @import("disks/ahci.zig");
const pci = @import("pci.zig");

// Primary and Secondary ATA bus, and are almost always controlled by IO ports 0x1F0 through 0x1F7 and 0x170 through 0x177
// Device Control Registers/Alternate Status ports are IO ports 0x3F6, and 0x376
// standard IRQ for the Primary bus is IRQ14 and IRQ15 for the Secondary bus
const Self = @This();

const DISK_0 = 0x1F0;
const DISK_1 = 0x170;

pub const DriveType = enum { ata, atapi, ahci };

var ports: AHCIPortArray = .{
    .ports = undefined,
    .len = 0,
};

pub const BaseUnion = union {
    legacy_base: u16,
    port: *const ahci.Port,
};

const AHCIPortArray = struct {
    ports: [32]?ahci.Port,
    len: usize = 0,

    pub fn get(self: *const @This(), index: usize) ?*const ahci.Port {
        if (index >= self.len) return null;
        if (self.ports[index] == null) return null;
        return &self.ports[index].?;
    }
};

var disks: [32]?Self = .{null} ** 32;

base: BaseUnion,
drive_info: [256]u16,
drive_type: DriveType,
read_only: bool = false,

pub const DiskError = error{
    InvalidDisk,
    UnalignedBuffer,
} || ata.DriveError || ahci.DiskError;

pub const DiskInitError = error{
    PortNotFound,
    UnusedPort,
} || DiskError;

pub fn loadDisks() void {
    for (0..ports.len) |i| {
        if (ports.get(i) != null) {
            disks[i] = Self.init(@intCast(i)) catch |err| {
                log.err("Failed to init disk {d}: {s}", .{ i, @errorName(err) });
                continue;
            };
        }
    }
}

pub fn get(disk: u8) ?*Self {
    if (disk >= disks.len) return null;
    if (disks[disk] == null) return null;
    return &disks[disk].?;
}

pub fn init(disk: u8) DiskInitError!Self {
    if (disk >= ports.len) return DiskInitError.PortNotFound;
    if (ports.get(disk)) |port| {
        var drive_info: [256]u16 = undefined;
        ahci.identify(port, &drive_info) catch |err| {
            log.err("Failed to identify disk {d}: {s}", .{ disk, @errorName(err) });
            return err;
        };

        return Self{
            .drive_info = drive_info,
            .drive_type = .ahci,
            .base = .{ .port = port },
            .read_only = false,
        };
    } else {
        return DiskInitError.UnusedPort;
    }
}

pub fn initLegacy(disk: u8) DiskError!Self {
    const base: u16 = if (disk == 0) DISK_0 else if (disk == 1) DISK_1 else return error.InvalidDisk;
    var self = Self{
        .base = .{ .legacy_base = base },
        .drive_info = undefined,
        .drive_type = .ata,
        .read_only = false,
    };

    ata.identify(self.base.legacy_base, &self.drive_info) catch |err| {
        if (err == error.DriveIsATAPI) {
            self.drive_type = DriveType.atapi;
            self.read_only = true;
            try atapi.identify(self.base.legacy_base, &self.drive_info);
        } else {
            return err;
        }
    };
    return self;
}

// much faster if BUFFER_IS_ALIGNED
pub fn read(self: Self, lba: u32, buf: []u8) DiskError!usize {
    if (buf.len == 0) return 0;

    switch (self.drive_type) {
        .ata => {
            if (buf.len % ata.SECTOR_SIZE != 0) return self.unalignedRead(lba, buf);
            const sectors = std.mem.bytesAsSlice(ata.Sector, buf);
            try ata.readSectors(self.base.legacy_base, lba, sectors);
            return buf.len;
        },
        .atapi => {
            if (buf.len % atapi.SECTOR_SIZE != 0) return self.unalignedRead(lba, buf);
            const sectors = std.mem.bytesAsSlice(atapi.Sector, buf);
            try atapi.readSectors(self.base.legacy_base, lba, sectors);
            return buf.len;
        },
        .ahci => {
            if (buf.len % ahci.SECTOR_SIZE != 0) return self.unalignedRead(lba, buf);
            const sectors = std.mem.bytesAsSlice(ahci.Sector, buf);
            return ahci.readSectors(self.base.port, lba, sectors);
        },
    }
}

pub fn readAll(self: Self, lba: u32, buf: []u8) DiskError!void {
    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        bytes_read += try self.read(lba, buf[bytes_read..]);
    }
}

fn unalignedRead(self: Self, lba: u32, buf: []u8) DiskError!usize {
    switch (self.drive_type) {
        .ata => {
            var tmp_buf: [ata.SECTOR_SIZE]u8 = undefined;
            return self.__inner_unalignedRead(lba, &tmp_buf, buf);
        },
        .atapi => {
            var tmp_buf: [atapi.SECTOR_SIZE]u8 = undefined;
            return self.__inner_unalignedRead(lba, &tmp_buf, buf);
        },
        .ahci => {
            var tmp_buf_max: [ahci.MAX_SECTOR_SIZE]u8 = undefined;
            const tmp_buf = tmp_buf_max[0..ahci.sectorSize(self.base.port)];
            return self.__inner_unalignedRead(lba, tmp_buf, buf);
        },
    }
}

fn __inner_unalignedRead(self: Self, lba: u32, tmp_buf: []u8, buf: []u8) DiskError!usize {
    const sector_count = (buf.len + tmp_buf.len - 1) / tmp_buf.len; // round up to nearest sector
    for (0..sector_count) |i| {
        const sector_offset = i * tmp_buf.len;
        const actual_lba: u32 = @intCast(lba + i);

        switch (self.drive_type) {
            .ata => {
                const sectors = std.mem.bytesAsSlice(ata.Sector, tmp_buf);
                try ata.readSectors(self.base.legacy_base, actual_lba, sectors);
            },
            .atapi => {
                const sectors = std.mem.bytesAsSlice(atapi.Sector, tmp_buf);
                try atapi.readSectors(self.base.legacy_base, actual_lba, sectors);
            },
            .ahci => {
                const sectors = std.mem.bytesAsSlice(ahci.Sector, tmp_buf);
                _ = try ahci.readSectors(self.base.port, actual_lba, sectors);
            },
        }

        @memcpy(tmp_buf[0..], buf[sector_offset..][0..tmp_buf.len]);
    }

    return buf.len;
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
        .ahci => {
            // TODO
            @panic("TODO: ahci write");
        },
    }
}

// copies the ports to a internal struct
pub fn loadAHCIPorts(p: *[32]?ahci.Port, len: usize) void {
    ports.ports = p.*;
    ports.len = len;
}
