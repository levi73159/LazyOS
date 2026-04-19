const std = @import("std");
const FS = @import("root").fs.FileSystem;
const Bitmap = @import("image/Bitmap.zig");
const TGA = @import("image/Tga.zig");

const log = std.log.scoped(.ui);

const TextureMap = std.StringHashMap(*const Texture);
pub const Texture = struct {
    width: u32,
    height: u32,
    rowstride: u32,
    bpp: u32, // bytes per pixel
    topdown: bool,

    pub const Pixel = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    pub fn pixels(self: *const Texture) []const u8 {
        // texture is allocated behind data
        const bytes: [*]const u8 = @ptrCast(self);
        return bytes[@sizeOf(Texture)..][0 .. self.height * self.rowstride];
    }

    // Bottom up (doesn't ever use top down)
    pub fn getPixel(self: *const Texture, x: u32, y: u32) Pixel {
        const src_row = if (self.topdown) y else self.height - 1 - y; // ← was always flipping
        const offset = src_row * self.rowstride + x * self.bpp;
        const data = self.pixels();

        return switch (self.bpp) {
            3 => Pixel{
                .b = data[offset + 0],
                .g = data[offset + 1],
                .r = data[offset + 2],
                .a = 0xFF,
            },
            4 => Pixel{
                .b = data[offset + 0],
                .g = data[offset + 1],
                .r = data[offset + 2],
                .a = data[offset + 3],
            },
            else => Pixel{ .r = 0, .g = 0, .b = 0, .a = 0xFF },
        };
    }

    pub fn len(self: *const Texture) u32 {
        return self.height * self.rowstride;
    }
};

var textures: TextureMap = undefined;

/// Loads textures from a folder (bmp only rn) and stores them in memroy (heap) for later use
pub fn init(allocator: std.mem.Allocator) !void {
    textures = TextureMap.init(allocator);

    try loadTGAData(allocator, "CURSOR.TGA", @embedFile("textures/cursor.tga"));
    try loadTGAData(allocator, "POWER.TGA", @embedFile("textures/power.tga"));
}

pub fn deinit() void {
    const allocator = textures.allocator;
    var items = textures.iterator();
    while (items.next()) |item| {
        allocator.free(item.key_ptr.*);
        const memory: [*]const u8 = @ptrCast(item.value_ptr.*);
        const true_size = @sizeOf(Texture) + item.value_ptr.*.len();
        allocator.free(memory[0..true_size]);
    }
    textures.deinit();
}

pub fn get(name: []const u8) ?*const Texture {
    return textures.get(name);
}

fn loadBMP(allocator: std.mem.Allocator, fs: *FS, entry: FS.DirIterator.Entry, folder: []const u8) !void {
    log.debug("loading texture: {s}", .{entry.name});

    const path = try std.mem.join(allocator, "/", &[_][]const u8{ folder, entry.name });
    defer allocator.free(path);

    log.debug("path: {s}", .{path});
    const file = try fs.open(path);
    defer file.close();

    log.debug("file opened", .{});
    const data = try file.readAlloc(allocator);
    defer allocator.free(data);

    log.debug("data read", .{});
    const bitmap = try Bitmap.initTmp(data);
    const size = bitmap.data.len;

    const true_size = @sizeOf(Texture) + size;

    const memory = try allocator.alignedAlloc(u8, .of(Texture), true_size); // make sure it aligned to Texture
    errdefer allocator.free(memory);

    const dot_index = std.mem.indexOf(u8, entry.name, ".") orelse entry.name.len;
    const name = try allocator.dupe(u8, entry.name[0..dot_index]);

    const texture: *Texture = @ptrCast(@alignCast(memory.ptr));
    texture.* = Texture{
        .width = bitmap.width,
        .height = bitmap.height,
        .rowstride = bitmap.rowstride,
        .bpp = (bitmap.bits_per_pixel) / 8,
        .topdown = bitmap.topdown,
    };

    @memcpy(memory[@sizeOf(Texture)..][0..size], bitmap.data);
    try textures.put(name, texture);

    log.info("Loaded texture: {s}", .{name});
}

fn loadTGA(allocator: std.mem.Allocator, fs: *FS, entry: FS.DirIterator.Entry, folder: []const u8) !void {
    log.debug("loading texture: {s}", .{entry.name});

    const path = try std.mem.join(allocator, "/", &[_][]const u8{ folder, entry.name });
    defer allocator.free(path);

    log.debug("path: {s}", .{path});
    const file = try fs.open(path);
    defer file.close();

    log.debug("file opened", .{});
    const data = try file.readAlloc(allocator);
    defer allocator.free(data);

    log.debug("data read", .{});
    try loadTGAData(allocator, entry.name, data);
}

fn loadTGAData(allocator: std.mem.Allocator, file_name: []const u8, data: []const u8) !void {
    const tga = try TGA.initTmp(data);
    const size = tga.data.len;

    const true_size = @sizeOf(Texture) + size;

    const memory = try allocator.alignedAlloc(u8, .of(Texture), true_size); // make sure it aligned to Texture
    errdefer allocator.free(memory);

    const dot_index = std.mem.indexOf(u8, file_name, ".") orelse file_name.len;
    const name = try allocator.dupe(u8, file_name[0..dot_index]);

    const texture: *Texture = @ptrCast(@alignCast(memory.ptr));
    texture.* = Texture{
        .width = tga.width,
        .height = tga.height,
        .rowstride = tga.rowstride,
        .bpp = (tga.bits_per_pixel) / 8,
        .topdown = tga.topdown,
    };

    @memcpy(memory[@sizeOf(Texture)..][0..size], tga.data);
    try textures.put(name, texture);

    log.info("Loaded texture: {s}", .{name});
}
