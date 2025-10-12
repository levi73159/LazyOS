const std = @import("std");
const uefi = std.os.uefi;
const W = std.unicode.utf8ToUtf16LeStringLiteral;
const serial = @import("serial.zig");

const GraphicsOutput = uefi.protocol.GraphicsOutput;

pub const Resolution = struct { width: u32, height: u32 };

pub const Info = struct {
    resolution: Resolution,
    device_handle: ?uefi.Handle,
};

var graphics_output: ?*GraphicsOutput = null;

pub fn getVideoInfo() uefi.Error!Info {
    const log = std.log.scoped(.edid);

    const boot_services = uefi.system_table.boot_services.?;
    const handles = try boot_services.locateHandleBuffer(.{ .by_protocol = &GraphicsOutput.guid }) orelse return error.NotFound;

    for (handles, 0..) |device_handle, i| {
        const mprotocol = boot_services.handleProtocol(uefi.protocol.edid.Discovered, device_handle) catch |err| switch (err) {
            error.Unsupported => {
                log.warn("Unsupported protocol with handle: {d}", .{i});
                continue;
            },
            else => {
                log.err("Failed to get protocol with handle: {d} error: {}", .{ i, err });
                return err;
            },
        };
        if (mprotocol == null) {
            log.warn("EDID not supported!", .{});
            continue;
        }
        const protocol = mprotocol.?;
        if (protocol.edid) |edid| {
            const x_res: u16 = @as(u16, edid[0x36 + 2]) | @as(u16, (edid[0x36 + 4] & 0xF0) << 4);
            const y_res: u16 = @as(u16, edid[0x36 + 5]) | @as(u16, (edid[0x36 + 7] & 0xF0) << 4);

            return Info{
                .resolution = .{ .width = x_res, .height = y_res },
                .device_handle = device_handle,
            };
        }
    }

    return uefi.Error.NotFound;
}

pub fn setVideoMode(info: Info) uefi.Error!void {
    const log = std.log.scoped(.video_mode);

    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;

    const gop: *GraphicsOutput = if (info.device_handle) |handle| colect: {
        const protocol = boot_services.handleProtocol(GraphicsOutput, handle) catch |err| {
            log.err("Failed to get protocol: {}", .{err});
            return err;
        };
        if (protocol) |p| break :colect p;
        log.err("Protocol not found!", .{});
        return error.NotFound;
    } else locate: {
        const protocol = boot_services.locateProtocol(GraphicsOutput, null) catch |err| {
            log.err("Failed to locate protocol: {}", .{err});
            return err;
        };
        if (protocol) |p| break :locate p;
        log.err("Protocol not found!", .{});
        return error.NotFound;
    };

    const Match = struct {
        dif: u32,
        info: *GraphicsOutput.Mode.Info,
        id: u32,
    };

    var mode_id: u32 = 0;
    var best: ?Match = null;
    while (mode_id < gop.mode.max_mode) : (mode_id += 1) {
        const mode = gop.queryMode(mode_id) catch |err| {
            log.warn("Failed to query mode id={d}: {}", .{ mode_id, err });
            continue;
        };

        // caluclate difference to find the best match
        const dif_width: u32 = @abs(@as(i32, @intCast(info.resolution.width)) - @as(i32, @intCast(mode.horizontal_resolution)));
        const dif_height: u32 = @abs(@as(i32, @intCast(info.resolution.height)) - @as(i32, @intCast(mode.vertical_resolution)));

        const total = dif_width + dif_height;

        log.debug("Diff: {d} ({d}x{d})", .{ total, mode.horizontal_resolution, mode.vertical_resolution });
        switch (mode.pixel_format) {
            .red_green_blue_reserved_8_bit_per_color,
            .blue_green_red_reserved_8_bit_per_color,
            => {},
            else => {
                log.warn("Unsupported pixel format: {}", .{mode.pixel_format});
                continue;
            },
        }

        if (best) |b| {
            if (total < b.dif) {
                best = Match{
                    .dif = total,
                    .info = mode,
                    .id = mode_id,
                };
            }
        } else {
            best = Match{
                .dif = total,
                .info = mode,
                .id = mode_id,
            };
        }
    }

    if (best.?.dif > 0) {
        log.warn("Cannot find exact mode, using the best match", .{});
    }
    log.info(
        \\Gop mode found:
        \\  Framebuffer: 0x{x}
        \\  Resolution: {d}x{d}
        \\  scanline: {d}
        \\  pixel format: {s}
    , .{
        gop.mode.frame_buffer_base,
        best.?.info.horizontal_resolution,
        best.?.info.vertical_resolution,
        best.?.info.pixels_per_scan_line,
        @tagName(best.?.info.pixel_format),
    });

    try gop.setMode(best.?.id);

    graphics_output = gop;
}

pub fn fillRect(x: u32, y: u32, width: u32, height: u32, color: GraphicsOutput.BltPixel) !void {
    if (graphics_output == null) {
        std.log.warn("Video mode not set (no graphics output)! please call setVideoMode", .{});
        return;
    }
    const gop = graphics_output.?;

    // since color needs to be mutable we copy it here so we don't have to use the unsafe @constCast
    var color_copy = color;
    try gop.blt(@ptrCast(&color_copy), .blt_video_fill, 0, 0, x, y, width, height, 0);
}
