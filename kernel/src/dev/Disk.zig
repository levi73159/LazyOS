//! Disk interface

const std = @import("std");
const root = @import("root");
const bootinfo = root.arch.bootinfo;
const io = @import("root").io;
const log = std.log.scoped(._disk);

const ata = @import("disks/ata.zig");
const atapi = @import("disks/atapi.zig");
const ahci = @import("disks/ahci.zig");
const BlockCache = @import("disks/BlockCache.zig");
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

pub var disks: [32 + 2]?Self = .{null} ** (32 + 2);

pub const DMA_BUF_SECTORS: usize = 128;
pub const MAX_SECTOR_SIZE: usize = 512;
pub const DMA_BUF_PAGES: usize = (DMA_BUF_SECTORS * MAX_SECTOR_SIZE) / 0x1000;

base: BaseUnion,
drive_info: [256]u16,
drive_type: DriveType,
read_only: bool = false,
dma_buf: usize = 0,

partitions: []?Partition = &.{},
block_cache: BlockCache = .{}, // SCSI doesn't use this block cache (because 512 byte sectors hardcoded when scsi is 2048 byte sectors)

pub const DiskError = error{
    InvalidDisk,
    UnalignedBuffer,
    ReadOnlyDisk,
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

    disks[32] = Self.initLegacy(0) catch |err| blk: {
        log.err("Failed to init disk {d}: {s}", .{ 32, @errorName(err) });
        break :blk null;
    };
    disks[33] = Self.initLegacy(1) catch |err| blk: {
        log.err("Failed to init disk {d}: {s}", .{ 33, @errorName(err) });
        break :blk null;
    };

    log.debug("Disks loaded with legacy disks", .{});
}

pub fn get(disk: u8) ?*Self {
    if (disk >= disks.len) {
        return null;
    }
    if (disks[disk] == null) {
        return null;
    }
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

        const dma_buf = root.pmem.kernel().allocPagesV(DMA_BUF_PAGES) catch |err| {
            log.err("Failed to allocate DMA buffer for disk {d}: {s}", .{ disk, @errorName(err) });
            return error.PortNotFound;
        };

        return Self{
            .drive_info = drive_info,
            .drive_type = .ahci,
            .base = .{ .port = port },
            .read_only = false,
            .dma_buf = dma_buf,
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
    log.info("Init legacy disk {d}", .{disk});
    return self;
}

const DiskReader = struct {
    disk: *Self,

    pub fn read(self: @This(), lba: u32, buf: *[BlockCache.BLOCK_SIZE]u8) DiskError!void {
        return self.disk.readSectorRaw(lba, buf);
    }
};

// one raw sector directly from hardware, no cache
fn readSectorRaw(self: *Self, lba: u32, buf: *[BlockCache.BLOCK_SIZE]u8) DiskError!void {
    switch (self.drive_type) {
        .ata => {
            const sectors = std.mem.bytesAsSlice(ata.Sector, buf);
            try ata.readSectors(self.base.legacy_base, lba, sectors);
        },
        .ahci => {
            const dma_virt: *[BlockCache.BLOCK_SIZE]u8 = @ptrFromInt(self.dma_buf);
            const sectors = std.mem.bytesAsSlice(ahci.Sector, dma_virt);
            _ = try ahci.readSectors(self.base.port, lba, sectors);
            @memcpy(buf, dma_virt);
        },
        .atapi => unreachable, // 2048-byte sectors, never routed here
    }
}

fn readCached(self: *Self, lba: u32, buf: *[BlockCache.BLOCK_SIZE]u8) DiskError!void {
    try self.block_cache.read(lba, buf, DiskReader{ .disk = self });
}

// much faster if BUFFER_IS_ALIGNED
pub fn read(self: *Self, lba: u32, buf: []u8) DiskError!usize {
    if (buf.len == 0) return 0;

    switch (self.drive_type) {
        .ahci => {
            // SATAPI: 2048-byte sectors, old path
            if (ahci.sectorSize(self.base.port) != BlockCache.BLOCK_SIZE) {
                if (buf.len % ahci.SECTOR_SIZE != 0) return self.unalignedRead(lba, buf);
                const sectors = std.mem.bytesAsSlice(ahci.Sector, buf);
                return ahci.readSectors(self.base.port, lba, sectors);
            }
            // bulk path — read through large DMA bounce buffer
            return self.readBulkAHCI(lba, buf);
        },
        .ata => {
            if (buf.len % BlockCache.BLOCK_SIZE != 0) return self.unalignedRead(lba, buf);
            const sector_count = buf.len / BlockCache.BLOCK_SIZE;
            for (0..sector_count) |i| {
                const cur_lba = lba + @as(u32, @intCast(i));
                const offset = i * BlockCache.BLOCK_SIZE;
                try self.readCached(cur_lba, buf[offset..][0..BlockCache.BLOCK_SIZE]);
            }
            return buf.len;
        },
        .atapi => {
            if (buf.len % atapi.SECTOR_SIZE != 0) return self.unalignedRead(lba, buf);
            const sectors = std.mem.bytesAsSlice(atapi.Sector, buf);
            try atapi.readSectors(self.base.legacy_base, lba, sectors);
            return buf.len;
        },
    }
}

fn readBulkAHCI(self: *Self, lba: u32, buf: []u8) DiskError!usize {
    const dma_capacity = DMA_BUF_SECTORS * ahci.SECTOR_SIZE; // 64KB
    const dma_virt = self.dma_buf;

    var offset: usize = 0;
    var cur_lba = lba;

    while (offset < buf.len) {
        const remaining = buf.len - offset;
        const chunk_bytes = std.mem.alignBackward(usize, @min(remaining, dma_capacity), ahci.SECTOR_SIZE);
        if (chunk_bytes == 0) {
            // sub-sector tail — use unaligned path
            const r = try self.unalignedRead(cur_lba, buf[offset..]);
            offset += r;
            break;
        }
        const chunk_sectors = chunk_bytes / ahci.SECTOR_SIZE;

        const dma_slice: []ahci.Sector = @as([*]ahci.Sector, @ptrFromInt(dma_virt))[0..chunk_sectors];
        _ = try ahci.readSectors(self.base.port, cur_lba, dma_slice);

        @memcpy(buf[offset..][0..chunk_bytes], @as([*]u8, @ptrFromInt(dma_virt))[0..chunk_bytes]);
        offset += chunk_bytes;
        cur_lba += @intCast(chunk_sectors);
    }

    return buf.len;
}

/// Offset is in bytes
pub fn readOffset(self: *Self, offset: usize, buf: []u8) DiskError!usize {
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

pub fn readAll(self: *Self, lba: u32, buf: []u8) DiskError!void {
    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        const real_lba = lba + (@as(u32, @intCast(bytes_read)) / self.sectorSize());
        bytes_read += try self.read(real_lba, buf[bytes_read..]);
    }
}

pub fn readOffsetAll(self: *Self, offset: usize, buf: []u8) DiskError!void {
    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        bytes_read += try self.readOffset(offset + bytes_read, buf[bytes_read..]);
    }
}

fn unalignedRead(self: *Self, lba: u32, buf: []u8) DiskError!usize {
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
    const sector_count = (buf.len + tmp_buf.len - 1) / tmp_buf.len;
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
                // bounce through DMA-safe buffer
                const dma_virt: *[ahci.SECTOR_SIZE]u8 = @ptrFromInt(self.dma_buf);
                const sectors = std.mem.bytesAsSlice(ahci.Sector, dma_virt);
                _ = try ahci.readSectors(self.base.port, actual_lba, sectors);
                @memcpy(tmp_buf, dma_virt[0..tmp_buf.len]);
            },
        }

        const len = @min(tmp_buf.len, buf.len - sector_offset);
        @memcpy(buf[sector_offset..][0..len], tmp_buf[0..len]);
    }

    return buf.len;
}

/// Warning can only read one sector with offset
fn unalignedReadOffset(self: *Self, lba: u32, offset: usize, buf: []u8) DiskError!usize {
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

pub fn writeAll(self: *Self, lba: u32, data: []const u8) DiskError!void {
    var written: usize = 0;
    while (written < data.len) {
        const n = try self.write(lba + @as(u32, @intCast(written / self.sectorSize())), data[written..]);
        written += n;
    }
}

pub fn write(self: *Self, lba: u32, data: []const u8) DiskError!usize {
    if (data.len == 0) return 0;
    if (self.read_only) return error.ReadOnlyDisk;

    var r = data.len;
    switch (self.drive_type) {
        .ata => {
            if (data.len % ata.SECTOR_SIZE != 0) {
                r = try self.unalignedWrite(lba, data);
            } else {
                const sectors = std.mem.bytesAsSlice(ata.Sector, data);
                try ata.writeSectors(self.base.legacy_base, lba, sectors);
                r = data.len;
            }
        },
        .atapi => {
            return error.ReadOnlyDisk; // atapi is read-only because it is cdrom
        },
        .ahci => {
            if (data.len % ahci.sectorSize(self.base.port) != 0) {
                r = try self.unalignedWrite(lba, data);
            } else {
                const sectors = std.mem.bytesAsSlice(ahci.Sector, data);
                r = try ahci.writeSectors(self.base.port, lba, sectors);
            }
        },
    }

    // invalidate cache
    var ilba = lba;
    const end = lba + @as(u32, @intCast(r / self.sectorSize()));
    while (ilba < end) : (ilba += 1) {
        self.block_cache.invalidate(ilba);
    }

    return r;
}

fn unalignedWrite(self: *Self, lba: u32, data: []const u8) DiskError!usize {
    switch (self.drive_type) {
        .ata => {
            var buf: [ata.SECTOR_SIZE]u8 = undefined;
            return self.__inner_unalignedWrite(lba, &buf, data);
        },
        .atapi => {
            return error.ReadOnlyDisk; // atapi is read-only because it is cdrom
        },
        .ahci => {
            var buf_max: [ahci.MAX_SECTOR_SIZE]u8 = undefined;
            const buf = buf_max[0..ahci.sectorSize(self.base.port)];
            return self.__inner_unalignedWrite(lba, buf, data);
        },
    }
}

fn __inner_unalignedWrite(self: *Self, lba: u32, tmp_buf: []u8, buf: []const u8) DiskError!usize {
    const end_aligned = std.mem.alignBackward(usize, buf.len, tmp_buf.len);

    var r: usize = 0;
    switch (self.drive_type) {
        .ata => {
            const sectors = std.mem.bytesAsSlice(ata.Sector, buf[0..end_aligned]);
            try ata.writeSectors(self.base.legacy_base, lba, sectors);
            r = end_aligned;
        },
        .atapi => return error.ReadOnlyDisk,
        .ahci => {
            // write aligned portion through DMA bounce buffer, one sector at a time
            var written: usize = 0;
            while (written < end_aligned) : (written += ahci.SECTOR_SIZE) {
                const dma_virt: *[ahci.SECTOR_SIZE]u8 = @ptrFromInt(self.dma_buf);
                @memcpy(dma_virt, buf[written..][0..ahci.SECTOR_SIZE]);
                const sectors = std.mem.bytesAsSlice(ahci.Sector, dma_virt);
                _ = try ahci.writeSectors(self.base.port, lba + @as(u32, @intCast(written / ahci.SECTOR_SIZE)), sectors);
            }
            r = end_aligned;
        },
    }

    if (r != end_aligned) return r;
    if (buf.len == end_aligned) return r;

    const written_lba = r / tmp_buf.len;
    try self.readAll(@intCast(lba + written_lba), tmp_buf);

    const rest = buf[end_aligned..];
    @memcpy(tmp_buf[0..rest.len], rest);

    switch (self.drive_type) {
        .ata => {
            const sectors = std.mem.bytesAsSlice(ata.Sector, tmp_buf);
            try ata.writeSectors(self.base.legacy_base, lba, sectors);
            r += tmp_buf.len;
        },
        .atapi => return error.ReadOnlyDisk,
        .ahci => {
            const dma_virt: *[ahci.SECTOR_SIZE]u8 = @ptrFromInt(self.dma_buf);
            @memcpy(dma_virt, tmp_buf[0..ahci.SECTOR_SIZE]);
            const sectors = std.mem.bytesAsSlice(ahci.Sector, dma_virt);
            r += try ahci.writeSectors(self.base.port, lba + @as(u32, @intCast(end_aligned / ahci.SECTOR_SIZE)), sectors);
        },
    }

    return r;
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

// if multi is true, return null if multiple partitions are found to match the guid
pub fn getPartitionFromGUID(self: *Self, guid: Partition.Guid, multi: bool) ?*Partition {
    var found_part: ?*Partition = null;
    for (self.partitions) |*maybe_part| if (maybe_part.*) |part| {
        const match = part.guid.eql(guid);
        if (match) {
            if (found_part == null) {
                found_part = &maybe_part.*.?;
                if (!multi) break;
            } else if (found_part != null and multi) {
                found_part = null;
                break;
            }
        }
    };

    return found_part;
}

fn extractAtaString(buf: []const u16, out: []u8) []const u8 {
    var i: usize = 0;
    while (i < buf.len and (i * 2 + 1) < out.len) : (i += 1) {
        const word = buf[i];
        out[i * 2] = @intCast((word >> 8) & 0xFF);
        out[i * 2 + 1] = @intCast(word & 0xFF);
    }

    // trim trailing spaces
    var end = out.len;
    while (end > 0 and out[end - 1] == ' ') : (end -= 1) {}

    return out[0..end];
}

pub fn getModelNumber(self: Self, model_buf: *[40]u8) []const u8 {
    return extractAtaString(self.drive_info[27..47], model_buf);
}

pub fn getSerialNumber(self: Self, serial_buf: *[20]u8) []const u8 {
    return extractAtaString(self.drive_info[10..20], serial_buf);
}

pub fn getFirmwareRevision(self: Self, fw_buf: *[8]u8) []const u8 {
    return extractAtaString(self.drive_info[23..27], fw_buf);
}

pub fn getTotalLBA28(self: Self) u32 {
    const w = self.drive_info;
    return @as(u32, w[60]) |
        (@as(u32, w[61]) << 16);
}

pub fn getTotalLBA48(self: Self) ?u64 {
    if (!self.supportsLBA48()) return null;

    const w = self.drive_info;

    return (@as(u64, w[100])) |
        (@as(u64, w[101]) << 16) |
        (@as(u64, w[102]) << 32) |
        (@as(u64, w[103]) << 48);
}

pub fn getTotalSectors(self: Self) u64 {
    if (self.supportsLBA48()) {
        return self.getTotalLBA48().?;
    }

    return self.getTotalLBA28();
}

pub fn getSectorSize(self: Self) u32 {
    const word = self.drive_info[106];

    log.debug("LBA28: {x}", .{self.getTotalLBA28()});
    log.debug("LBA48: {?x}", .{self.getTotalLBA48()});
    log.debug("word83: {x}", .{self.drive_info[83]});
    log.debug("word60: {x}", .{self.drive_info[60]});
    log.debug("word61: {x}", .{self.drive_info[61]});

    if ((word & (1 << 12)) != 0) {
        const size_low = self.drive_info[117];
        const size_high = self.drive_info[118];
        const size = (@as(u32, size_high) << 16) | size_low;
        if (size != 0) return size;
    }

    return 512;
}

pub fn supportsLBA48(self: Self) bool {
    return ((self.drive_info[83] & (1 << 10)) != 0) and
        ((self.drive_info[86] & (1 << 10)) != 0);
}

pub fn supportsDMA(self: Self) bool {
    return (self.drive_info[49] & (1 << 8)) != 0;
}

pub fn capabilities(self: Self) u16 {
    return self.drive_info[49];
}

pub fn getTotalSize(self: Self) u64 {
    return self.getTotalSectors() * self.getSectorSize();
}

// save the partition table from gpt to disk as gpt format
pub fn savePartitions(self: *Self) void {
    const gpt = @import("disks/gpt.zig");
    const allocator = @import("root").heap.allocator();

    gpt.savePartitions(self, allocator) catch {
        log.err("gpt Failed to save partitions", .{});
    };
}
