//! ATA PIO implementation - stateless functions, pass base address explicitly

const std = @import("std");
const io = @import("root").io;
const log = std.log.scoped(.ata);

// ATA Commands
pub const CMD_READ_SECTORS = 0x20;
pub const CMD_WRITE_SECTORS = 0x30;
pub const CMD_IDENTIFY = 0xEC;
pub const CMD_FLUSH_CACHE = 0xE7;

// Register offsets from base
pub const DATA_REGISTER = 0;
pub const ERROR_REGISTER = 1;
pub const FEATURES_REGISTER = 1;
pub const SECTOR_COUNT_REGISTER = 2;
pub const LBA_LOW_REGISTER = 3;
pub const LBA_MID_REGISTER = 4;
pub const LBA_HIGH_REGISTER = 5;
pub const DRIVE_REGISTER = 6;
pub const STATUS_REGISTER = 7;
pub const COMMAND_REGISTER = 7;
pub const CONTROL_REGISTER: u16 = 0x206;
pub const DRIVE_ADDRESS_REGISTER: u16 = 0x207;

pub const SECTOR_SIZE: u32 = 512;

pub const StatusRegister = packed struct(u8) {
    err: bool,
    idx: bool,
    corrected_data: bool,
    drq: bool,
    srv: bool,
    drive_fault: bool,
    ready: bool,
    busy: bool,
};

pub const ErrorRegister = packed struct(u8) {
    amnf: bool,
    tkznf: bool,
    abrt: bool,
    mcr: bool,
    idnf: bool,
    mc: bool,
    unc: bool,
    bbk: bool,

    pub fn getError(self: ErrorRegister) ?DriveError {
        if (self.amnf) return error.AddressMarkNotFound;
        if (self.tkznf) return error.TrackZeroNotFound;
        if (self.abrt) return error.AbortedCommand;
        if (self.mcr) return error.MediaChangeRequest;
        if (self.idnf) return error.IDNotFound;
        if (self.mc) return error.MediaChanged;
        if (self.unc) return error.UncorrectableDataError;
        if (self.bbk) return error.BadBlockDetected;
        return null;
    }
};

pub const DriveError = error{
    DriveFault,
    AddressMarkNotFound,
    TrackZeroNotFound,
    AbortedCommand,
    MediaChangeRequest,
    IDNotFound,
    MediaChanged,
    UncorrectableDataError,
    BadBlockDetected,
    UnknownError,
    NoDevice,
    DriveNotFound,
    DriveIsATAPI,
    DriveNotATA,
};

pub fn readStatus(base: u16) StatusRegister {
    return @bitCast(io.inb(base + STATUS_REGISTER));
}

pub fn readAlternateStatus(base: u16) StatusRegister {
    return @bitCast(io.inb(base + CONTROL_REGISTER));
}

pub fn readError(base: u16) DriveError {
    const err: ErrorRegister = @bitCast(io.inb(base + ERROR_REGISTER));
    return err.getError() orelse error.UnknownError;
}

pub const DeviceControl = packed struct(u8) {
    _reserved: u1 = 0,
    nien: bool, // set to TRUE to DISABLE interrupts
    srst: bool, // software reset
    _reserved2: u4 = 0,
    hob: bool, // high order byte (LBA48)
};

pub fn setInterrupts(base: u16, enabled: bool) void {
    const ctrl = DeviceControl{
        .nien = !enabled, // nien=1 disables, nien=0 enables
        .srst = false,
        .hob = false,
    };
    io.outb(base + CONTROL_REGISTER, @bitCast(ctrl));
}

pub fn delay400ns(base: u16) void {
    _ = readAlternateStatus(base);
    _ = readAlternateStatus(base);
    _ = readAlternateStatus(base);
    _ = readAlternateStatus(base);
}

pub fn waitBusy(base: u16) !void {
    var status = readStatus(base);
    while (status.busy) {
        status = readStatus(base);
    }
    if (status.err) return readError(base);
    if (status.drive_fault) return error.DriveFault;
}

pub fn waitDrq(base: u16) !void {
    var status = readStatus(base);
    while (!status.drq) {
        if (status.err) return readError(base);
        if (status.drive_fault) return error.DriveFault;
        status = readStatus(base);
    }
}

/// Returns drive_info buffer on success.
/// Returns error.DriveIsATAPI if an ATAPI device is detected — caller
/// should hand off to atapi.identify().
pub fn identify(base: u16, drive_info: *[256]u16) !void {
    setInterrupts(base, false);
    io.outb(base + DRIVE_REGISTER, 0xA0);
    io.outb(base + SECTOR_COUNT_REGISTER, 0);
    io.outb(base + LBA_LOW_REGISTER, 0);
    io.outb(base + LBA_MID_REGISTER, 0);
    io.outb(base + LBA_HIGH_REGISTER, 0);
    io.outb(base + COMMAND_REGISTER, CMD_IDENTIFY);
    delay400ns(base);

    const status_byte = io.inb(base + STATUS_REGISTER);
    if (status_byte == 0xFF) return error.NoDevice;
    if (status_byte == 0x00) return error.DriveNotFound;

    // ATAPI devices abort IDENTIFY — catch it and check signature
    waitBusy(base) catch |err| {
        if (err != error.AbortedCommand) return err;
    };

    const mid = io.inb(base + LBA_MID_REGISTER);
    const high = io.inb(base + LBA_HIGH_REGISTER);
    if (mid == 0x14 and high == 0xEB) return error.DriveIsATAPI;
    if (mid != 0 or high != 0) return error.DriveNotATA;

    try waitDrq(base);

    for (drive_info) |*d| {
        d.* = io.inw(base + DATA_REGISTER);
    }
}

pub const Sector = [SECTOR_SIZE]u8;

pub fn readSectors(base: u16, lba: u32, buf: []Sector) !void {
    std.debug.assert(buf.len <= 255);
    const sector_count = buf.len;

    try waitBusy(base);

    io.outb(base + DRIVE_REGISTER, 0xE0 | @as(u8, @truncate(lba >> 24)));
    io.outb(base + SECTOR_COUNT_REGISTER, @truncate(sector_count));
    io.outb(base + LBA_LOW_REGISTER, @truncate(lba));
    io.outb(base + LBA_MID_REGISTER, @truncate(lba >> 8));
    io.outb(base + LBA_HIGH_REGISTER, @truncate(lba >> 16));
    io.outb(base + COMMAND_REGISTER, CMD_READ_SECTORS);
    delay400ns(base);

    var sector: usize = 0;
    while (sector < sector_count) : (sector += 1) {
        try waitBusy(base);
        try waitDrq(base);

        var i: usize = 0;
        while (i < SECTOR_SIZE) : (i += 2) {
            const w = io.inw(base + DATA_REGISTER);
            buf[sector][i] = @truncate(w);
            buf[sector][i + 1] = @truncate(w >> 8);
        }
    }
}

pub fn writeSectors(base: u16, lba: u32, data: []const Sector) !void {
    std.debug.assert(data.len <= 255);
    const sector_count = data.len;

    try waitBusy(base);

    io.outb(base + DRIVE_REGISTER, 0xE0 | @as(u8, @truncate(lba >> 24)));
    io.outb(base + SECTOR_COUNT_REGISTER, @truncate(sector_count));
    io.outb(base + LBA_LOW_REGISTER, @truncate(lba));
    io.outb(base + LBA_MID_REGISTER, @truncate(lba >> 8));
    io.outb(base + LBA_HIGH_REGISTER, @truncate(lba >> 16));
    io.outb(base + COMMAND_REGISTER, CMD_WRITE_SECTORS);
    delay400ns(base);

    var sector: usize = 0;
    while (sector < sector_count) : (sector += 1) {
        try waitBusy(base);
        try waitDrq(base);

        var i: usize = 0;
        while (i < SECTOR_SIZE) : (i += 2) {
            const word: u16 = @as(u16, data[sector][i]) | (@as(u16, data[sector][i + 1]) << 8);
            io.outw(base + DATA_REGISTER, word);
            // tinny tinny delay of 5 cpu ticks
            for (0..5) |_| {}
        }
    }

    io.outb(base + COMMAND_REGISTER, CMD_FLUSH_CACHE);
    try waitBusy(base);
}
