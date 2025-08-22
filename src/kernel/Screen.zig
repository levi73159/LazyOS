const std = @import("std");
const Color = @import("Color.zig");
const font = @import("fonts/Basic.zig");

const Self = @This();

const default_width = 1024;
const default_height = 768;

buffer: []u32,
double_buffer: ?[]u32 = null,
width: u32,
height: u32,

use_double_buffer: bool = false,

pub fn init(buffer: []u32, width: u32, height: u32) Self {
    return Self{
        .buffer = buffer,
        .width = width,
        .height = height,
    };
}

pub fn createDoubleBuffer(self: *Self, allocator: std.mem.Allocator) !void {
    self.double_buffer = try allocator.alloc(u32, self.buffer.len);
    @memset(self.double_buffer.?, 0);
}

pub fn getBuffer(self: *Self) []u32 {
    if (self.use_double_buffer) {
        return self.double_buffer orelse @panic("No double buffer");
    }
    return self.buffer;
}

pub fn getBufferConst(self: Self) []const u32 {
    if (self.use_double_buffer) {
        return self.double_buffer orelse @panic("No double buffer");
    }
    return self.buffer;
}

pub fn getPixel(self: Self, x: u32, y: u32) u32 {
    return self.getBufferConst()[y * self.width + x];
}

pub fn getPixelMut(self: *Self, x: u32, y: u32) *u32 {
    return &self.getBuffer()[y * self.width + x];
}

pub fn setPixel(self: *Self, x: u32, y: u32, color: Color) void {
    const index = y * self.width + x;
    self.getBuffer()[index] = color.get();
}

pub fn setPixel32(self: *Self, x: u32, y: u32, color: u32) void {
    const index = y * self.width + x;
    self.getBuffer()[index] = color;
}

pub fn drawRect(self: *Self, x: u32, y: u32, width: u32, height: u32, color: Color) void {
    var i: u32 = 0;
    while (i < height) : (i += 1) {
        var j: u32 = 0;
        while (j < width) : (j += 1) {
            self.setPixel(x + j, y + i, color);
        }
    }
}

pub fn drawOutlineRect(self: *Self, x: u32, y: u32, width: u32, height: u32, color: Color) void {
    self.drawRect(x, y, width, 1, color);
    self.drawRect(x, y + height - 1, width, 1, color);
    self.drawRect(x, y, 1, height, color);
    self.drawRect(x + width - 1, y, 1, height, color);
}

pub fn drawRectWithBorderInvert(self: *Self, x: u32, y: u32, width: u32, height: u32, color: Color, border_width: u32, border_color: Color) void {
    var i: u32 = 0;
    while (i < height) : (i += 1) {
        var j: u32 = 0;
        while (j < width) : (j += 1) {
            const is_border = i == 0 or i == height - 1 or j == 0 or j == width - 1;
            const not_in_border = i >= border_width and i < height - border_width and j >= border_width and j < width - border_width;
            if (is_border or not_in_border) {
                self.setPixel(x + j, y + i, border_color);
            } else {
                self.setPixel(x + j, y + i, color);
            }
        }
    }
}

pub fn drawRectWithBorder(self: *Self, x: u32, y: u32, width: u32, height: u32, color: Color, border_width: u32, border_color: Color) void {
    var i: u32 = 0;
    while (i < height) : (i += 1) {
        var j: u32 = 0;
        while (j < width) : (j += 1) {
            const is_border = i == 0 or i == height - 1 or j == 0 or j == width - 1;
            const in_border = !(i >= border_width and i < height - border_width and j >= border_width and j < width - border_width);
            if (is_border or in_border) {
                self.setPixel(x + j, y + i, border_color);
            } else {
                self.setPixel(x + j, y + i, color);
            }
        }
    }
}

pub fn drawChar(self: *Self, char_index: u8, x: u32, y: u32, scale: u32, color: Color) void {
    const width = font.width;
    const height = font.height;

    if (width > 16) {
        @panic("Fonts wider than 16 pixels are illegal as of now!");
    }

    const char_start: usize = char_index * @as(usize, height);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const bitmask = @as(u16, 1) << @truncate(width - 1 - col);
            const value = font.font_data[char_start + row] & bitmask;

            if (value != 0) {
                var sy: u32 = 0;
                while (sy < scale) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < scale) : (sx += 1) {
                        self.setPixel(
                            x + col * scale + sx,
                            y + row * scale + sy,
                            color,
                        );
                    }
                }
            }
        }
    }
}

pub fn drawText(self: *Self, x: u32, y: u32, text: []const u8, scale: u32, color: Color) void {
    var i: u32 = 0;
    while (i < text.len) : (i += 1) {
        self.drawChar(text[i], x + i * font.width * scale, y, scale, color);
    }
}

pub fn clear(self: *Self, color: Color) void {
    const buffer = self.getBuffer();
    for (buffer) |*pixel| {
        pixel.* = color.get();
    }
}

pub fn swapBuffers(self: *Self) void {
    if (self.use_double_buffer) {
        @memcpy(self.buffer, self.double_buffer.?);
    }
}
