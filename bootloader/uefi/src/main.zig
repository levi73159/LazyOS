const std = @import("std");
const uefi = std.os.uefi;
const serial = @import("serial.zig");
const video = @import("video.zig");
const mem = @import("mem.zig");
const fs = @import("fs.zig");
const loader = @import("loader.zig");
const BootInfo = @import("BootInfo.zig");
const constants = @import("constants.zig");
const AddressSpace = @import("AddressSpace.zig");

const UefiError = uefi.Error;
const File = uefi.protocol.File;

const W = std.unicode.utf8ToUtf16LeStringLiteral;

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

const config_path = "/boot/config.cfg";
var com1_serial: serial.SerialWriter = undefined;

const Config = struct {
    name: []const u8 = "Unknown OS",
    kernel: []const u8 = "/boot/kernel",
    preload_msg: ?[]const u8 = null,
    video: video.Resolution = .{ .width = 800, .height = 600 },
};

pub fn main() uefi.Error!void {
    const sys_table = uefi.system_table;
    const conout = sys_table.con_out.?;
    try conout.clearScreen();

    com1_serial = serial.SerialWriter.init(.com1) catch {
        _ = try conout.outputString(W("Failed to initialize serial port!!"));
        return abortNoPrint();
    };

    fs.init() catch |err| {
        std.log.err("{}", .{err});
        return abort();
    };

    std.log.info("Serial port initialized", .{});

    const boot_services = sys_table.boot_services.?;
    const conin = sys_table.con_in.?;

    const config_data = fs.loadFileBuffer(config_path) catch |err| {
        std.log.err("Failed to load config!!!", .{});
        std.log.err("{}", .{err});
        return abort();
    };
    defer config_data.free();

    const config = parseConfig(config_data.contents()) catch |err| {
        std.log.err("Failed to parse config!!!", .{});
        std.log.err("{}", .{err});
        return abort();
    };

    if (config.preload_msg) |msg| {
        try printMsg(msg);
    }

    const boot_info: *align(constants.ARCH_PAGE_SIZE) BootInfo = alloc_info: {
        const ptr = boot_services.allocatePages(.any, .loader_data, 1) catch |err| {
            std.log.err("Failed to allocate boot info: {}", .{err});
            return abort();
        };

        break :alloc_info @ptrCast(ptr);
    };
    boot_info.* = .{}; // init the default values

    const addr_space = AddressSpace.init() catch |err| {
        std.log.err("Failed to create address space: {}", .{err});
        return abort();
    };

    var err_count: u8 = 0;
    const max_errs = 5;
    for (0..10) |i| {
        const paddr = 0xC012345000 + i * constants.ARCH_PAGE_SIZE;
        const vaddr = 0xC054321000 + i * constants.ARCH_PAGE_SIZE;
        addr_space.mmap(.from(vaddr), paddr, .{ .present = true, .read_write = .read_write }) catch |err| {
            std.log.warn("Failed to map vaddr: 0x{x} to paddr: 0x{x}: {}", .{ vaddr, paddr, err });
            err_count += 1;
            if (err_count > max_errs) {
                std.log.err("Too many errors, aborting...", .{});
                return abort();
            }
            continue;
        };
    }
    addr_space.print();

    // const memmap = mem.getMemoryMap(boot_info) catch |err| {
    //     std.log.err("Failed to get memory map: {}", .{err});
    //     return abort();
    // };

    std.log.debug("Getting perfered resolution", .{});
    const video_info: video.Info = video.getVideoInfo() catch |err| blk: {
        std.log.warn("Failed to get resolution: {}; defaulting to config", .{err});
        break :blk video.Info{
            .resolution = config.video,
            .device_handle = null,
        };
    };
    std.log.info("Perfered resolution: {d}x{d}", .{ video_info.resolution.width, video_info.resolution.height });

    video.setVideoMode(video_info, boot_info) catch |err| {
        std.log.err("Failed to set video mode: {}", .{err});
        return abort();
    };

    video.fillRect(0, 0, 150, 200, .{ .red = 255, .green = 0, .blue = 0, .reserved = 0 }) catch |err| {
        std.log.err("Failed to fill rect: {}", .{err});
        return abort();
    };

    const kernel_data = fs.loadFileBuffer(config.kernel) catch |err| {
        std.log.err("Failed to load kernel into memory!!!", .{});
        std.log.err("{}", .{err});
        return abort();
    };
    defer kernel_data.free();

    const kernel = loader.loadExe(kernel_data.contents()) catch |err| {
        std.log.err("Failed to load kernel into memory!!!", .{});
        std.log.err("{}", .{err});
        @panic("Failed to load kernel into memory");
    };
    _ = kernel;
    std.log.info("Kernel loaded", .{});

    std.log.debug("Bootinfo:\n{any}", .{boot_info.*});

    const events = [_]uefi.Event{conin.wait_for_key};
    while (true) {
        const event_signaled = try boot_services.waitForEvent(&events);

        if (event_signaled[1] == 0) {
            const key = try conin.readKeyStroke();
            if (key.unicode_char == 'q') {
                return;
            }
            const slice: [*:0]const u16 = &[_:0]u16{key.unicode_char};
            _ = try conout.outputString(slice);
        }
    }

    return UefiError.Timeout;
}

fn parseConfig(data: []const u8) !Config {
    std.log.info("Parsing config:\n{s}", .{data});
    var lines = std.mem.tokenizeAny(u8, data, "\r\n");
    var has_name: bool = false;
    var config = Config{};

    while (lines.next()) |line| {
        const index_eq = std.mem.indexOfScalar(u8, line, '=') orelse continue; // simply ignore it
        const name = line[0..index_eq];
        const value = line[index_eq + 1 .. line.len];

        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                if (std.mem.eql(u8, field.name, "name")) {
                    has_name = true;
                    config.name = value;
                } else if (std.mem.eql(u8, field.name, "video")) {
                    const idx = std.mem.indexOfScalar(u8, value, 'x') orelse {
                        std.log.err("Invalid resolution: {s}", .{value});
                        return error.InvalidResolution;
                    };

                    const width = value[0..idx];
                    const height = value[idx + 1 .. value.len];

                    const width_int = std.fmt.parseUnsigned(u16, width, 10) catch {
                        std.log.err("Invalid width: {s}", .{width});
                        return error.InvalidResolution;
                    };

                    const height_int = std.fmt.parseUnsigned(u16, height, 10) catch {
                        std.log.err("Invalid height: {s}", .{height});
                        return error.InvalidResolution;
                    };

                    config.video = .{ .width = width_int, .height = height_int };
                } else {
                    if (field.type == []const u8 or field.type == ?[]const u8) {
                        @field(config, field.name) = value;
                    } else {
                        std.log.err("Unsupported type: {}", .{field.type});
                        return error.UnsupportedType;
                    }
                }
            }
        }
    }

    if (!has_name) {
        std.log.warn("No name found in config", .{});
    }

    return config;
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const color = switch (level) {
        .debug => "\x1b[32m",
        .info => "\x1b[36m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };
    const prefix = switch (level) {
        .err => "[ERR] ",
        .warn => "[WARN] ",
        .info => "[INFO] ",
        .debug => "[DEBUG] ",
    };

    const writer = com1_serial.writer();
    writer.writeAll(color ++ prefix) catch unreachable;
    switch (scope) {
        .default => {},
        else => writer.writeAll("(" ++ @tagName(scope) ++ "): ") catch unreachable,
    }
    writer.print(format, args) catch unreachable;
    writer.writeAll("\x1b[0m\n") catch unreachable;
}

pub fn printMsg(msg: []const u8) !void {
    const conout = uefi.system_table.con_out.?;
    const boot_services = uefi.system_table.boot_services.?;

    // WARN: do not remove the times 2. If it works don't touch it!
    // TODO: Figure out why *2 works and allows it to free but removing it doesn't
    const buf = try boot_services.allocatePool(.loader_data, msg.len * 2 + 1);
    defer boot_services.freePool(buf.ptr) catch {
        std.log.warn("Failed to free pool", .{});
    };

    const utf16_ptr: [*]u16 = @ptrCast(buf.ptr);
    const utf16_buf: []u16 = utf16_ptr[0 .. msg.len + 1]; // +1 for null terminator
    std.log.debug("Roading preload message", .{});
    const len = std.unicode.utf8ToUtf16Le(utf16_buf, msg) catch {
        std.log.warn("Failed to convert preload message to utf16", .{});
        return; // ignore
    };
    std.log.debug("Preload message length: {d}", .{len});

    utf16_buf[len] = 0;
    const utf16_msg: [:0]const u16 = utf16_buf[0..len :0]; // convert it to a null terminated slice

    _ = try conout.outputString(utf16_msg.ptr);
    _ = try conout.outputString(W("\n"));
}

inline fn abortNoPrint() UefiError {
    try uefi.system_table.boot_services.?.stall(3 * std.time.us_per_s);
    return UefiError.Aborted;
}

fn abort() UefiError {
    std.log.err("Aborting...", .{});
    return abortNoPrint();
}
