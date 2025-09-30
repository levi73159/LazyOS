const std = @import("std");
const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const serial = @import("serial.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

var com1_serial: serial.SerialWriter = undefined;

pub fn halt() void {}

pub fn main() uefi.Error!void {
    const sys_table = uefi.system_table;
    const conout = sys_table.con_out.?;
    try conout.clearScreen();
    write("Hello, World!\r\n");

    com1_serial = serial.SerialWriter.init(.com1) catch {
        write("Failed to initialize serial port!!");
        while (true) {}
    };

    std.log.info("Serial port initialized", .{});
    std.log.debug("Hello, World!", .{});
    std.log.err("An error occurred", .{});
    std.log.warn("A warning occurred", .{});

    const boot_services = sys_table.boot_services.?;
    const conin = sys_table.con_in.?;

    const map = try getMemoryMap();
    _ = map; // autofix

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

    return error.Timeout;
}

fn getMemoryMap() !uefi.tables.MemoryMapSlice {
    const log = std.log.scoped(.mmap);
    const boot_services = uefi.system_table.boot_services.?;
    const info = try boot_services.getMemoryMapInfo();
    const raw_buffer = try boot_services.allocatePool(.loader_data, info.len * info.descriptor_size);
    const buffer: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = @alignCast(raw_buffer);

    const map = try boot_services.getMemoryMap(buffer);

    log.debug("Memory map size: {d}", .{info.len});
    log.debug("Descriptor size: {d}", .{info.descriptor_size});
    log.debug("Total size: {d}", .{info.len * info.descriptor_size});

    return map;
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

fn write(comptime str: []const u8) void {
    _ = uefi.system_table.con_out.?.outputString(utf16(str)) catch unreachable;
}
