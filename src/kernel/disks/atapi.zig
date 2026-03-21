//! ATAPI (SCSI-over-ATA) implementation - stateless functions

const io = @import("../arch.zig").io;
const ata = @import("ata.zig");
const std = @import("std");

pub const CMD_IDENTIFY_PACKET = 0xA1;
pub const CMD_PACKET = 0xA0;

// SCSI opcodes
pub const SCSI_READ_10 = 0x28;
pub const SCSI_READ_CAPACITY = 0x25;

pub const SECTOR_SIZE: u32 = 2048;

pub fn identify(base: u16, drive_info: *[256]u16) !void {
    io.outb(base + ata.DRIVE_REGISTER, 0xA0);
    io.outb(base + ata.SECTOR_COUNT_REGISTER, 0);
    io.outb(base + ata.LBA_LOW_REGISTER, 0);
    io.outb(base + ata.LBA_MID_REGISTER, 0);
    io.outb(base + ata.LBA_HIGH_REGISTER, 0);
    io.outb(base + ata.COMMAND_REGISTER, CMD_IDENTIFY_PACKET);
    ata.delay400ns(base);

    const status_byte = io.inb(base + ata.STATUS_REGISTER);
    if (status_byte == 0xFF) return error.NoDevice;
    if (status_byte == 0x00) return error.DriveNotFound;

    try ata.waitBusy(base);
    try ata.waitDrq(base);

    for (drive_info) |*d| {
        d.* = io.inw(base + ata.DATA_REGISTER);
    }
}

const Packet = extern struct {
    opcode: u8,
    flags: u8 = 0,
    lba: [4]u8, // big-endian manually
    reserved: u8 = 0,
    count: [2]u8, // big-endian manually
    control: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },

    pub fn init(opcode: u8, lba: u32, count: u16) Packet {
        return .{
            .opcode = opcode,
            .lba = .{
                @truncate(lba >> 24),
                @truncate(lba >> 16),
                @truncate(lba >> 8),
                @truncate(lba),
            },
            .count = .{
                @truncate(count >> 8),
                @truncate(count),
            },
        };
    }

    pub fn getBytes(self: *const Packet) *const [12]u8 {
        return @ptrCast(self);
    }
};

comptime {
    std.debug.assert(@sizeOf(Packet) == 12);
}

fn sendPacket(base: u16, packet: Packet, byte_count: u16) !void {
    io.outb(base + ata.DRIVE_REGISTER, 0xA0);
    ata.delay400ns(base);
    try ata.waitBusy(base);
    io.outb(base + ata.FEATURES_REGISTER, 0); // PIO mode
    io.outb(base + ata.LBA_MID_REGISTER, @truncate(byte_count));
    io.outb(base + ata.LBA_HIGH_REGISTER, @truncate(byte_count >> 8));
    io.outb(base + ata.COMMAND_REGISTER, CMD_PACKET);

    ata.delay400ns(base);

    try ata.waitBusy(base);
    try ata.waitDrq(base);

    const packet_bytes = packet.getBytes();

    // write 12 byte packet as 6 words
    var i: usize = 0;
    while (i < 12) : (i += 2) {
        const word = @as(u16, packet_bytes[i]) | (@as(u16, packet_bytes[i + 1]) << 8);
        io.outw(base + ata.DATA_REGISTER, word);
    }
}

pub const Sector = [SECTOR_SIZE]u8;

pub fn readSectors(base: u16, lba: u32, buf: []Sector) !void {
    std.debug.assert(buf.len <= std.math.maxInt(u16));

    const packet = Packet.init(SCSI_READ_10, lba, @intCast(buf.len));
    try sendPacket(base, packet, SECTOR_SIZE);
    for (buf) |*sector| {
        try ata.waitBusy(base);
        try ata.waitDrq(base);

        // drive tells us how many bytes it wants to transfer this round
        const lo = io.inb(base + ata.LBA_MID_REGISTER);
        const hi = io.inb(base + ata.LBA_HIGH_REGISTER);
        const bytes = @as(u16, lo) | (@as(u16, hi) << 8);
        const words = bytes / 2;

        var i: usize = 0;
        while (i < words) : (i += 1) {
            const w = io.inw(base + ata.DATA_REGISTER);
            sector[i * 2] = @truncate(w);
            sector[i * 2 + 1] = @truncate(w >> 8);
        }
    }
}
