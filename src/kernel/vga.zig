// VGA text mode constants
pub const VGA_WIDTH = 80;
pub const VGA_HEIGHT = 25;

const bit32Color = @import("Color.zig");

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

    pub fn to32bitColor(self: Color) bit32Color {
        return switch (self) {
            .black => bit32Color.init(0, 0, 0),
            .blue => bit32Color.init(0, 0, 255),
            .green => bit32Color.init(0, 255, 0),
            .cyan => bit32Color.init(0, 255, 255),
            .red => bit32Color.init(255, 0, 0),
            .magenta => bit32Color.init(255, 0, 255),
            .brown => bit32Color.init(165, 42, 42),
            .light_grey => bit32Color.init(192, 192, 192),
            .dark_grey => bit32Color.init(128, 128, 128),
            .light_blue => bit32Color.init(128, 128, 255),
            .light_green => bit32Color.init(128, 255, 128),
            .light_cyan => bit32Color.init(128, 255, 255),
            .light_red => bit32Color.init(255, 128, 128),
            .light_magenta => bit32Color.init(255, 128, 255),
            .yellow => bit32Color.init(255, 255, 128),
            .white => bit32Color.init(255, 255, 255),
        };
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
