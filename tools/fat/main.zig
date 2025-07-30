const std = @import("std");
const process = std.process;
const BootSector = @import("BootSector.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <disk image> <file name>\n", .{args[0]});
        process.exit(1);
    }

    const disk_image = args[1];
    const file_name = args[2];

    const disk = std.fs.cwd().openFile(disk_image, .{}) catch |err| handleError("Failed to open disk image", err);
    defer disk.close();

    const boot_sector = BootSector.fromReader(disk.reader()) catch |err| handleError("Failed to read boot sector", err);
    const fat = boot_sector.readFat(allocator, disk) catch |err| handleError("Failed to read FAT", err);
    const root = boot_sector.readRootDirectory(allocator, disk) catch |err| handleError("Failed to read root directory", err);
    const entry = boot_sector.findEntry(file_name, root) orelse handleError("File not found", error.FileNotFound);

    var output_buf = try allocator.alloc(u8, entry.size * boot_sector.bytes_per_sector);
    boot_sector.readFile(root, entry, fat, disk, output_buf) catch |err| handleError("Failed to read file", err);

    for (output_buf[0..entry.size]) |byte| {
        if (std.ascii.isPrint(byte)) {
            std.debug.print("{c}", .{byte});
        } else {
            switch (byte) {
                '\n' => std.debug.print("\n", .{}),
                '\r' => {}, // skip
                '\t' => std.debug.print("\t", .{}),
                else => std.debug.print("\\x{X:0>2}", .{byte}),
            }
        }
    }
    std.debug.print("\n", .{});
}

fn handleError(msg: []const u8, err: anyerror) noreturn {
    std.debug.print("Error: {s}: {s}\n", .{ msg, @errorName(err) });
    process.exit(1);
}
