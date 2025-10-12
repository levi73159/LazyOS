const std = @import("std");
const mem = @import("mem.zig");
const uefi = std.os.uefi;

const File = uefi.protocol.File;
const log = std.log.scoped(.file_system);

const FileError = error{
    InvalidParameter,
    Unsupported,

    BufferTooSmall,
} || uefi.UnexpectedError || uefi.protocol.SimpleFileSystem.OpenVolumeError || uefi.protocol.File.OpenError;

inline fn handleDeferError(msg: []const u8) noreturn {
    log.err("{s}, unexpected error!!!", .{msg});
    @panic(msg);
}

var file_system: ?*uefi.protocol.SimpleFileSystem = null;

const FileBuffer = struct {
    mem: []u8,
    len: usize,

    pub fn getPages(self: FileBuffer) []align(4096) uefi.Page {
        return mem.bytesToPages(self.mem);
    }

    pub fn free(self: FileBuffer) void {
        const boot_services = uefi.system_table.boot_services.?;
        boot_services.freePages(self.getPages()) catch |err| {
            log.err("Failed to free pages: {}", .{err});
            @panic("Failed to free pages");
        };
    }

    pub fn contents(self: FileBuffer) []u8 {
        return self.mem[0..self.len];
    }
};

pub fn init() !void {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;

    file_system = boot_services.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch |err| {
        log.err("Failed to locate protocol: {}", .{err});
        return err;
    };

    if (file_system == null) {
        log.err("Simple File System Protocol not found!", .{});
        return error.NotFound;
    }
}

fn getFileSystem() *uefi.protocol.SimpleFileSystem {
    return file_system orelse @panic("File system not initialized");
}

// NOTE: the caller owns the memory
pub fn loadFileBuffer(p: []const u8) FileError!FileBuffer {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;

    const simple_file_system = boot_services.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch |err| {
        log.err("Failed to locate protocol: {}", .{err});
        return err;
    };

    if (simple_file_system == null) {
        log.err("Simple File System Protocol not found!", .{});
        return error.NotFound;
    }

    const fs = getFileSystem();

    var path_buf: [500]u16 = undefined;
    const path_len = std.unicode.utf8ToUtf16Le(&path_buf, p) catch {
        log.warn("Failed to convert path to utf16", .{});
        return error.InvalidParameter;
    };

    path_buf[path_len] = 0;
    const path: [:0]u16 = path_buf[0..path_len :0];

    std.mem.replaceScalar(u16, path, '/', '\\');

    const root = try fs.openVolume();
    defer root.close() catch handleDeferError("Failed to close root");

    const file = try root.open(path.ptr, .read, .{ .read_only = true });
    defer file.close() catch handleDeferError("Failed to close file");

    const file_info_buf = try boot_services.allocatePool(.loader_data, try file.getInfoSize(.file));
    defer boot_services.freePool(file_info_buf.ptr) catch handleDeferError("Failed to free pool");
    const config_info: *File.Info.File = try file.getInfo(.file, file_info_buf);

    print: {
        var utf8_buf_out: [500]u8 = undefined;
        const size = std.unicode.utf16LeToUtf8(&utf8_buf_out, path) catch {
            log.warn("Failed to convert path to utf8", .{});
            log.debug("Opening file of size: {d}", .{config_info.file_size});
            break :print;
        };
        log.debug("Opening file: {s} size: {d}", .{ utf8_buf_out[0..size], config_info.file_size });
    }

    // NOTE: do not free pool because it is owned by the caller of this function
    const file_buf_size = std.mem.alignForward(usize, config_info.file_size, 4096);
    const pages_to_alloc = @divExact(file_buf_size, 4096);
    const pages = boot_services.allocatePages(.any, .loader_data, pages_to_alloc) catch |err| switch (err) {
        error.OutOfResources => {
            std.log.err("Allocation failed: reason out of memory", .{});
            @panic("OOM");
        },
        else => return err,
    };

    const buf = mem.pagesToBytes(pages);

    var offset: usize = 0;
    while (true) {
        const n = try file.read(buf[offset..]);
        if (n == 0) break;
        offset += n;
    }
    return FileBuffer{ .mem = buf, .len = offset };
}
