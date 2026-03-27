pub const Read12Packet = extern struct {
    const Self = @This();

    opcode: u8 = 0xA8,
    flags: u8 = 0, // bit 3 = FUA, rest reserved
    lba: [4]u8, // big-endian ✓
    count: [4]u8, // big-endian, 32-bit transfer length
    reserved: u8 = 0,
    control: u8 = 0,

    pub fn init(lba: u32, count: u32) Self {
        return .{
            .lba = .{
                @truncate(lba >> 24),
                @truncate(lba >> 16),
                @truncate(lba >> 8),
                @truncate(lba),
            },
            .count = .{
                @truncate(count >> 24),
                @truncate(count >> 16),
                @truncate(count >> 8),
                @truncate(count),
            },
        };
    }

    pub fn getBytes(self: *const Self) *const [12]u8 {
        return @ptrCast(self);
    }
};
