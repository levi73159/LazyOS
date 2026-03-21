const std = @import("std");
const FS = @import("fs/FileSystem.zig");
const Bitmap = @import("image/Bitmap.zig");

const log = std.log.scoped(.ui);

const TextureMap = std.StringHashMap(*const Texture);
pub const Texture = struct {
    width: u32,
    height: u32,
    bpp: u32, // bytes per pixel

    pub const Pixel = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    pub fn pixels(self: *const Texture) []const u8 {
        // texture is allocated behind data
        const bytes: [*]const u8 = @ptrCast(self);
        return bytes[@sizeOf(Texture) .. self.width * self.height * self.bpp];
    }

    // Bottom up (doesn't ever use top down)
    pub fn getPixel(self: *const Texture, x: u32, y: u32) Pixel {
        const src_row = self.height - 1 - y;
        const row_size = self.width * self.bpp;
        const offset = src_row * row_size + x * self.bpp;
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
        return self.width * self.height * self.bpp;
    }
};

var textures: TextureMap = undefined;

/// Loads textures from a folder (bmp only rn) and stores them in memroy (heap) for later use
pub fn init(fs: *FS, folder: []const u8, allocator: std.mem.Allocator) !void {
    textures = TextureMap.init(allocator);

    var it = try fs.it(folder);
    while (try it.next()) |entry| {
        log.debug("entry: {s}", .{entry.name});
        if (entry.info.type != .file) continue; // ignores directories
        if (!std.mem.endsWith(u8, entry.name, ".BMP")) continue;

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

        const name = try allocator.dupe(u8, entry.name);
        const texture: *Texture = @ptrCast(@alignCast(memory.ptr));
        texture.width = bitmap.width;
        texture.height = bitmap.height;
        texture.bpp = @divExact(bitmap.bits_per_pixel, 8);

        @memcpy(memory[@sizeOf(Texture)..][0..size], bitmap.data);
        try textures.put(name, texture);

        log.info("Loaded texture: {s}", .{name});
    }
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
