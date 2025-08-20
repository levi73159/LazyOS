const std = @import("std");
const Color = @import("Color.zig");

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

pub fn clear(self: *Self, color: Color) void {
    const buffer = self.getBuffer();
    for (buffer) |*pixel| {
        pixel.* = color.get();
    }
}

pub fn swapBuffers(self: *Self) void {
    if (self.use_double_buffer) {
        std.log.debug("Swapping double buffer", .{});
        @memcpy(self.buffer, self.double_buffer.?);
    }
}
