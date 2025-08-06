const FBCon = @import("FBCon.zig");
const Color = @import("../Color.zig");
const log = @import("std").log.scoped(.term_fbcon_sgr);

/// Create a Color from the ANSI color code
/// Follows the VGA standard
pub fn colorFromANSI(color_code: u32) Color {
    return switch (color_code) {
        30, 40 => .{ .red = 0x00, .green = 0x00, .blue = 0x00, .reserved = 0x00 },
        31, 41 => .{ .red = 0xaa, .green = 0x00, .blue = 0x00, .reserved = 0x00 },
        32, 42 => .{ .red = 0x00, .green = 0xaa, .blue = 0x00, .reserved = 0x00 },
        33, 43 => .{ .red = 0xaa, .green = 0x55, .blue = 0x00, .reserved = 0x00 },
        34, 44 => .{ .red = 0x00, .green = 0x00, .blue = 0xaa, .reserved = 0x00 },
        35, 45 => .{ .red = 0xaa, .green = 0x00, .blue = 0xaa, .reserved = 0x00 },
        36, 46 => .{ .red = 0x00, .green = 0xaa, .blue = 0xaa, .reserved = 0x00 },
        37, 47 => .{ .red = 0xaa, .green = 0xaa, .blue = 0xaa, .reserved = 0x00 },
        90, 100 => .{ .red = 0x55, .green = 0x55, .blue = 0x55, .reserved = 0x00 },
        91, 101 => .{ .red = 0xff, .green = 0x55, .blue = 0x55, .reserved = 0x00 },
        92, 102 => .{ .red = 0x55, .green = 0xff, .blue = 0x55, .reserved = 0x00 },
        93, 103 => .{ .red = 0xff, .green = 0xff, .blue = 0x55, .reserved = 0x00 },
        94, 104 => .{ .red = 0x55, .green = 0x55, .blue = 0xff, .reserved = 0x00 },
        95, 105 => .{ .red = 0xff, .green = 0x55, .blue = 0xff, .reserved = 0x00 },
        96, 106 => .{ .red = 0x55, .green = 0xff, .blue = 0xff, .reserved = 0x00 },
        97, 107 => .{ .red = 0xff, .green = 0xff, .blue = 0xff, .reserved = 0x00 },
        else => .{ .red = 0x00, .green = 0x00, .blue = 0x00, .reserved = 0x00 },
    };
}

/// Select Graphic Rendition
pub fn selectGraphicRendition(self: *FBCon, control_sequence: FBCon.ControlSequence) void {
    var len: usize = 0;
    for (control_sequence.args) |arg| {
        if (arg) |_| {
            len += 1;
        } else {
            break;
        }
    }
    for (control_sequence.args[0..len]) |arg| {
        switch (arg orelse unreachable) {
            .number => |num| {
                switch (num) {
                    0 => {
                        self.setColor(colorFromANSI(37), colorFromANSI(40));
                        self.graphical_features.bold = false;
                        self.graphical_features.underline = false;
                        self.graphical_features.reversed = false;
                        self.graphical_features.invisible = false;
                    },
                    1 => {
                        self.graphical_features.bold = true;
                    },
                    4 => {
                        self.graphical_features.underline = true;
                    },
                    5 => {
                        // no blinking support
                    },
                    7 => {
                        self.graphical_features.reversed = true;
                    },
                    8 => {
                        self.graphical_features.invisible = true;
                    },
                    22 => {
                        self.graphical_features.bold = false;
                    },
                    24 => {
                        self.graphical_features.underline = false;
                    },
                    25 => {
                        // no blinking support
                    },
                    27 => {
                        self.graphical_features.reversed = false;
                    },
                    28 => {
                        self.graphical_features.invisible = false;
                    },
                    30...37, 90...97 => {
                        self.color_int = colorFromANSI(num).getInt(self.pixel_format);
                    },
                    40...47, 100...107 => {
                        self.bgcolor_int = colorFromANSI(num).getInt(self.pixel_format);
                    },
                    else => {
                        // TODO: support 256color
                        // TODO: support truecolor
                        log.warn("Unknown control sequence argument, skipping", .{});
                        break;
                    },
                }
            },
            else => log.warn("Unknown control sequence argument type, skipping", .{}),
        }
    }
}
