const std = @import("std");
const Color = @import("Color.zig");

const Self = @This();

buffer: []u32,
width: u32,
height: u32,
pitch: u32,

pub fn init(buffer: []u32, width: u32, height: u32, pitch: u32) Self {
    return Self{ .buffer = buffer, .width = width, .height = height, .pitch = pitch };
}

pub fn getPixel(self: Self, x: u32, y: u32) u32 {
    return self.buffer[y * self.pitch / 4 + x];
}

pub fn getPixelMut(self: Self, x: u32, y: u32) *u32 {
    return &self.buffer[y * self.pitch / 4 + x];
}

pub fn setPixel(self: Self, x: u32, y: u32, color: Color) void {
    self.buffer[y * self.pitch / 4 + x] = color.get();
}

pub fn drawRect(self: Self, x: u32, y: u32, width: u32, height: u32, color: Color) void {
    var i: u32 = 0;
    while (i < height) : (i += 1) {
        var j: u32 = 0;
        while (j < width) : (j += 1) {
            self.setPixel(x + j, y + i, color);
        }
    }
}

pub fn clear(self: Self, color: Color) void {
    for (self.buffer) |*pixel| {
        pixel.* = color.get();
    }
}
