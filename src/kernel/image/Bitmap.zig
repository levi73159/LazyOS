//! Bitmap file type, support 24 and 32 bit Bitmap images
const std = @import("std");

const FileHeader = packed struct {
    signature: u16, // always 0x4D42 ("BM")
    file_size: u32, // total file size in bytes
    reserved1: u16, // always 0
    reserved2: u16, // always 0
    data_offset: u32, // offset to pixel data from start of file
};

const DibHeader = packed struct {
    header_size: u32, // always 40 for this variant
    width: i32, // pixels, negative means right-to-left
    height: i32, // pixels, negative means top-down
    color_planes: u16, // always 1
    bits_per_pixel: u16, // 1, 4, 8, 16, 24, or 32
    compression: u32, // 0 = none (BI_RGB)
    image_size: u32, // raw pixel data size (can be 0 if uncompressed)
    x_pixels_per_m: i32, // horizontal resolution
    y_pixels_per_m: i32, // vertical resolution
    colors_used: u32, // colors in color table (0 = all)
    colors_important: u32, // important colors (0 = all)
};

const RGBA = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
};

const RGB = packed struct(u24) {
    b: u8,
    g: u8,
    r: u8,
};

data: []u8,
width: u32,
height: u32,
bits_per_pixel: u16,
topdown: bool = false,

const Self = @This();
// shorthead for duplication of data
pub fn init(file_data: []u8, allocator: std.mem.Allocator) !Self {
    var self = try initTmp(file_data);
    self.data = try allocator.dupe(u8, self.data);
    return self;
}

// NOTE: the buffer passed to it must stay alive as long as the bitmap is alive
pub fn initTmp(file_data: []u8) !Self {
    const file_header = std.mem.bytesToValue(FileHeader, file_data[0..14]);
    if (file_header.signature != 0x4D42) return error.NotBitmap;

    if (file_data.len < 14 + 40) return error.TooSmall;
    const dib = std.mem.bytesToValue(DibHeader, file_data[14..54]);

    const size = file_header.file_size;
    const pixels = file_data[file_header.data_offset..][0..size];

    const expected_size = dib.width * dib.height * (dib.bits_per_pixel / 8);
    std.debug.assert(size == expected_size);

    if (dib.bits_per_pixel != 24 and dib.bits_per_pixel != 32) return error.UnsupportedBpp;
    if (dib.compression != 0) return error.UnsupportedCompression;

    if (dib.height < 0) return error.TopDownNotSupported;

    return Self{
        .data = pixels,
        .width = @intCast(dib.width),
        .height = @intCast(dib.height),
        .bits_per_pixel = dib.bits_per_pixel,
    };
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
}
