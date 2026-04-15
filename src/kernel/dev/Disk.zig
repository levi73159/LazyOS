//! Disk interface

const std = @import("std");
const io = @import("root").io;
const log = std.log.scoped(._disk);

const ata = @import("disks/ata.zig");
const atapi = @import("disks/atapi.zig");
const ahci = @import("disks/ahci.zig");
const pci = @import("pci.zig");
const Partition = @import("Partition.zig");

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

partitions: []?Partition = &.{},

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

pub fn deinit(self: *Self) void {
    disks[self.base.legacy_base] = null;
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

/// Offset is in bytes
pub fn readOffset(self: Self, offset: usize, buf: []u8) DiskError!usize {
    const sector_size = switch (self.drive_type) {
        .ata => ata.SECTOR_SIZE,
        .atapi => atapi.SECTOR_SIZE,
        .ahci => ahci.sectorSize(self.base.port),
    };

    const lba_start = offset / sector_size;
    const sector_offset = offset % sector_size;

    const end = std.mem.alignBackward(usize, buf.len, sector_size);
    var amount_read: usize = 0;
    if (sector_offset == 0) {
        const r = try self.read(@intCast(lba_start), buf[0..end]);
        amount_read += r;
        if (r != end) return r;
    } else {
        const unaligned_read_needed = @min(sector_size - sector_offset, buf.len);
        var r = try self.unalignedReadOffset(@intCast(lba_start), sector_offset, buf[0..unaligned_read_needed]);
        amount_read += r;
        if (r != unaligned_read_needed or amount_read == buf.len) return amount_read;
        r += try self.read(@intCast(lba_start + 1), buf[unaligned_read_needed..end]);
        amount_read += r;
        if (r != end - unaligned_read_needed) return amount_read;
    }

    if (amount_read == buf.len) return amount_read;

    if (end != buf.len) {
        const tail_offset = offset + end;
        const tail_lba: u32 = @intCast(tail_offset / sector_size);
        const tail_sector_off = tail_offset % sector_size;

        const r = try self.unalignedReadOffset(tail_lba, tail_sector_off, buf[end..]);
        amount_read += r;
    }

    return amount_read;
}

pub fn readAll(self: Self, lba: u32, buf: []u8) DiskError!void {
    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        const real_lba = lba + (@as(u32, @intCast(bytes_read)) / self.sectorSize());
        bytes_read += try self.read(real_lba, buf[bytes_read..]);
    }
}

pub fn readOffsetAll(self: Self, offset: usize, buf: []u8) DiskError!void {
    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        bytes_read += try self.readOffset(offset + bytes_read, buf[bytes_read..]);
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

        const len = @min(tmp_buf.len, buf.len - sector_offset);
        @memcpy(buf[sector_offset..][0..len], tmp_buf[0..len]);
    }

    return buf.len;
}

/// Warning can only read one sector with offset
fn unalignedReadOffset(self: Self, lba: u32, offset: usize, buf: []u8) DiskError!usize {
    switch (self.drive_type) {
        .ata => {
            var tmp_buf: [ata.SECTOR_SIZE]u8 = undefined;
            return self.__inner_unalignedReadOffset(lba, offset, &tmp_buf, buf);
        },
        .atapi => {
            var tmp_buf: [atapi.SECTOR_SIZE]u8 = undefined;
            return self.__inner_unalignedReadOffset(lba, offset, &tmp_buf, buf);
        },
        .ahci => {
            var tmp_buf_max: [ahci.MAX_SECTOR_SIZE]u8 = undefined;
            const tmp_buf = tmp_buf_max[0..ahci.sectorSize(self.base.port)];
            return self.__inner_unalignedReadOffset(lba, offset, tmp_buf, buf);
        },
    }
}

fn __inner_unalignedReadOffset(self: Self, lba: u32, offset: usize, tmp_buf: []u8, buf: []u8) DiskError!usize {
    var r: usize = 0;
    switch (self.drive_type) {
        .ata => {
            try ata.readSectors(self.base.legacy_base, lba, std.mem.bytesAsSlice(ata.Sector, tmp_buf));
            r = tmp_buf.len;
        },
        .atapi => {
            try atapi.readSectors(self.base.legacy_base, lba, std.mem.bytesAsSlice(atapi.Sector, tmp_buf));
            r = tmp_buf.len;
        },
        .ahci => {
            r = try ahci.readSectors(self.base.port, lba, std.mem.bytesAsSlice(ahci.Sector, tmp_buf));
        },
    }

    const len = @min(r - offset, buf.len);
    @memcpy(buf[0..len], tmp_buf[offset..][0..len]);

    return len; // how much we read/copy into buf
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

pub fn sectorSize(self: Self) u32 {
    switch (self.drive_type) {
        .ata => return ata.SECTOR_SIZE,
        .atapi => return atapi.SECTOR_SIZE,
        .ahci => return ahci.sectorSize(self.base.port),
    }
}
