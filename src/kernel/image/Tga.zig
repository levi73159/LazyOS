//! TGA file type, supports 24bpp (RGB) and 32bpp (RGBA) uncompressed images
const std = @import("std");

const Header = extern struct {
    id_length: u8, // bytes to skip after header
    color_map_type: u8, // 0 = no color map
    image_type: u8, // 2 = uncompressed true-color
    color_map_spec: [5]u8, // irrelevant, we reject color maps
    x_origin: u16 align(1),
    y_origin: u16 align(1),
    width: u16 align(1),
    height: u16 align(1),
    bits_per_pixel: u8, // 24 or 32
    image_descriptor: u8, // bit 5 = top-down flag
};

data: []u8,
width: u32,
height: u32,
bits_per_pixel: u16,
topdown: bool = false,
rowstride: u32,

const Self = @This();

pub fn init(file_data: []u8, allocator: std.mem.Allocator) !Self {
    var self = try initTmp(file_data);
    self.data = try allocator.dupe(u8, self.data);
    return self;
}

// NOTE: the buffer passed to it must stay alive as long as the image is alive
pub fn initTmp(file_data: []u8) !Self {
    std.log.debug("Initializing TGA", .{});
    if (file_data.len < @sizeOf(Header)) return error.TooSmall;

    const hdr = std.mem.bytesToValue(Header, file_data[0..@sizeOf(Header)]);
    std.log.debug("tga header: {any}", .{hdr});

    if (hdr.color_map_type != 0) return error.UnsupportedColorMap;
    if (hdr.image_type != 2) return error.UnsupportedCompression; // no RLE
    if (hdr.bits_per_pixel != 24 and
        hdr.bits_per_pixel != 32) return error.UnsupportedBpp;
    if (hdr.width == 0 or hdr.height == 0) return error.InvalidDimensions;

    // TGA has zero row padding — stride is exact
    const rowstride = @as(u32, hdr.width) * @as(u32, hdr.bits_per_pixel / 8);
    const expected = rowstride * @as(u32, hdr.height);
    const offset = @as(u32, @sizeOf(Header)) + @as(u32, hdr.id_length);

    if (file_data.len < offset + expected) return error.TooSmall;

    return Self{
        .data = file_data[offset..][0..expected],
        .width = hdr.width,
        .height = hdr.height,
        .bits_per_pixel = hdr.bits_per_pixel,
        .rowstride = rowstride,
        .topdown = (hdr.image_descriptor & 0x20) != 0,
    };
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
}
