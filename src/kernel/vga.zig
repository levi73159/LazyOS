// VGA text mode constants
pub const VGA_WIDTH = 80;
pub const VGA_HEIGHT = 25;

const VGA_MEMORY = @as(*volatile [VGA_HEIGHT * VGA_WIDTH]u16, @ptrFromInt(0xB8000));

pub const Color = enum(u8) {
    black,
    blue,
    green,
    cyan,
    red,
    magenta,
    brown,
    light_grey,
    dark_grey,
    light_blue,
    light_green,
    light_cyan,
    light_red,
    light_magenta,
    /// Alias for light brown
    yellow,
    white,

    pub inline fn toEntry(fg: Color, bg: Color) u8 {
        return entryColor(fg, bg);
    }
};

pub fn entryColor(fg: Color, bg: Color) u8 {
    return @intFromEnum(fg) | (@intFromEnum(bg) << 4);
}

pub fn entry(uc: u8, color_entry: u8) u16 {
    return @as(u16, uc) | (@as(u16, color_entry) << 8);
}

pub fn writeEntry(index: usize, en: u16) void {
    VGA_MEMORY[index] = en;
}

pub fn getEntry(index: usize) u16 {
    return VGA_MEMORY[index];
}
