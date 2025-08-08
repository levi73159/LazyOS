//! The Framebuffer Console

const std = @import("std");
const fonts = @import("./fonts.zig");
const Color = @import("../Color.zig");
pub const selectGraphicRendition = @import("SGR.zig").selectGraphicRendition;
pub const colorFromANSI = @import("SGR.zig").colorFromANSI;
pub const eraseInDisplay = @import("DECSED.zig").eraseInDisplay;

const log = std.log.scoped(.host);

const CursorPosition = struct {
    column: usize,
    row: usize,
};

pub const StateValue = struct {
    index: u8,
    values: [8]u8,
};

/// The State of the Special Character "parser"
pub const State = union(enum) {
    /// Currently no control sequence detected
    none,
    /// Escape char (could be a control sequence)
    escape_statement,
    /// Escape char AND "[" (CSI)
    control_sequence_start,
    /// Control Sequence Value
    control_sequence_value: StateValue,
    /// Control Sequence Value Delimiter
    control_sequence_delimiter,
    /// Control Sequence Final
    control_sequence_command,
};

/// The control sequence type
pub const ControlSequence = struct {
    /// The control sequence "command" (final byte)
    command: u8,
    /// The control sequence "command" args
    args: [8]?ControlSequenceArgument,
    /// The control sequence "command" arg index
    index: usize,
    /// Indicator whether the control sequence is ready to be executed or not
    ready_for_exec: bool,
};

/// The control sequence argument union
pub const ControlSequenceArgument = union(enum) {
    char: u8,
    number: u32,
};

/// The graphical features supported by the framebuffer console
/// No italic because VT510 does not do that (see https://vt100.net/docs/vt510-rm/chapter4.html#S4.6)
pub const GraphicalFeatures = struct {
    /// Bold
    bold: bool,
    /// Underline
    underline: bool,
    /// Reverse (bg and fg are exchanged)
    reversed: bool,
    /// Invisible (text will not be printed out)
    invisible: bool,
};

const Self = @This();
// according to wikipedia, control sequences can have a maximum number of 5 args
// we make maximum 8 args, just in case
var control_sequence_arg_buffer: [8]u32 = undefined;

/// The pointer to the framebuffer
framebuffer_pointer: [*]volatile u32,
/// Pixels per scan line
pixels_per_scanline: u32,
/// Pixel format (RedGreenBlueReserved or BlueGreenRedReserved)
pixel_format: u32,
/// Pixel width of screen
pixel_width: usize,
/// Pixel height of screen
pixel_height: usize,
/// ANSI Escape Code Parser State
state: State = .none,
/// ANSI Escape Command
control_sequence: ControlSequence,
/// Current output color (foreground)
color_int: u32 = 0xffffffff,
/// Current output color (background)
bgcolor_int: u32 = 0,
/// Current Font
font: fonts.FontDesc = fonts.vga_8x16,
/// Current Cursor Position
curpos: CursorPosition = CursorPosition{
    .column = 0,
    .row = 0,
},
/// Maximal width
max_width: u32 = 80,
/// Maximal height
max_height: u32 = 25,
/// Graphical Features
graphical_features: GraphicalFeatures = .{
    .bold = false,
    .underline = false,
    .reversed = false,
    .invisible = false,
},

/// Setup the Framebuffer Console
pub fn setup(self: *Self) void {
    self.state = .none;
    self.control_sequence = .{
        .command = undefined,
        .args = .{ null, null, null, null, null, null, null, null },
        .index = 0,
        .ready_for_exec = false,
    };
    self.font = fonts.vga_8x16;
    self.curpos.column = 0;
    self.curpos.row = 0;
    self.max_width = 80;
    self.max_height = 25;
    self.graphical_features = .{
        .bold = false,
        .underline = false,
        .reversed = false,
        .invisible = false,
    };
    self.clearScreen();
    self.setColor(colorFromANSI(37), colorFromANSI(40));
}

/// Clear the Screen (effectively set the color of everything to 0)
pub fn clearScreen(self: *Self) void {
    // just do a memset instead of iterating over each pixel for performance improvements
    const total_size: usize = self.pixels_per_scanline * self.pixel_height;
    @memset(self.framebuffer_pointer[0..total_size], 0);
    self.curpos.column = 0;
    self.curpos.row = 0;
}

/// Draw a single character (CP437)
pub fn drawChar(self: *Self, char_index: u8, x: usize, y: usize) void {
    const width = self.font.width;
    const height = self.font.height;
    if (width > 16) {
        log.emerg("Fonts wider than 16 pixels are illegal as of now! ", .{});
    }
    const char_start: usize = char_index * @as(usize, height);
    const base_index: usize = x * @as(usize, width) + (y * @as(usize, height)) *% self.pixels_per_scanline;
    var col: u4 = 0;
    var row: u8 = 0;
    var bgcolor: u32 = self.bgcolor_int;
    var color: u32 = self.color_int;
    // main rendering logic
    if (self.graphical_features.reversed == true) {
        bgcolor = self.color_int;
        color = self.bgcolor_int;
    }
    if (self.graphical_features.invisible == true) {
        return;
    }
    while (row < height) : ({
        row += 1;
        col = 0;
    }) {
        while (col < width) : (col += 1) {
            var index: usize = base_index + col;
            index += row *% self.pixels_per_scanline;
            const value = self.font.data[char_start + row] & @as(u16, 1) << (width - col);
            self.framebuffer_pointer[index] = if (value == 0) bgcolor else color;
        }
    }
    // graphical features
    if (self.graphical_features.bold == true) {
        // bold: OR 1pxl to left
        row = 0;
        col = 0;
        while (row < height) : ({
            row += 1;
            col = 0;
        }) {
            while (col < width) : (col += 1) {
                const col_left: u4 = if (col == 0) 0 else col - 1;
                const index: usize = base_index + col + row *% self.pixels_per_scanline;
                const value_left = self.font.data[char_start + row] & @as(u16, 1) << (width - col_left);
                if (value_left != 0) self.framebuffer_pointer[index] = color;
            }
        }
    }
    if (self.graphical_features.underline == true) {
        // underline: OR 1pxl with height/8 pxls offset from bottom
        row = height - @divFloor(height, 8);
        col = 0;
        while (col < width) : (col += 1) {
            const index: usize = base_index + col + row *% self.pixels_per_scanline;
            self.framebuffer_pointer[index] = color;
        }
    }
}

/// Set font
pub fn setFont(self: *Self, new_font: fonts.FontDesc) void {
    self.font = new_font;
}

/// Set colors
pub fn setColor(self: *Self, color: Color, bgcolor: Color) void {
    self.color_int = color.getInt(self.pixel_format);
    self.bgcolor_int = bgcolor.getInt(self.pixel_format);
}

/// Scroll
pub fn scroll(self: *Self) void {
    const amount_to_discard: usize = self.pixels_per_scanline * self.font.height;
    const max_addr: usize = self.pixels_per_scanline * self.pixel_height;
    @memcpy(self.framebuffer_pointer[0..max_addr], self.framebuffer_pointer[amount_to_discard..max_addr]);
}

/// Handle a control sequence argument value (basically just a number parser)
pub fn handleVal(self: *Self, val: StateValue) void {
    // find out last num index
    var number_end: u32 = 0;
    var number: u32 = 0;
    for (val.values) |value| {
        switch (value) {
            '0'...'9' => {
                number_end += 1;
            },
            else => {},
        }
    }
    // parse int
    for (0..number_end) |i| {
        const multiplicator = std.math.pow(u32, 10, @as(u32, @intCast(number_end - (i + 1))));
        if (val.values[i] != '0') {
            number += (val.values[i] - '0') * multiplicator;
        }
    }
    self.control_sequence.args[self.control_sequence.index] = ControlSequenceArgument{ .number = number };
    self.control_sequence.index += 1;
}

/// Check whether the character is special or not
///
/// Will get important when using control sequences
pub fn isSpecialChar(self: *Self, char: u8) bool {
    return switch (char) {
        '\n' => true,
        '\x1b' => blk: {
            // perhaps a control sequence
            self.state = .escape_statement;
            self.control_sequence.args = .{ null, null, null, null, null, null, null, null };
            self.control_sequence.index = 0;
            self.control_sequence.command = 0;
            self.control_sequence.ready_for_exec = false;
            break :blk true;
        },
        '[' => blk: {
            // control sequence start
            switch (self.state) {
                .escape_statement => {
                    self.state = .control_sequence_start;
                    break :blk true;
                },
                else => break :blk false,
            }
        },
        '0'...':', '<'...'?' => blk: {
            // control sequence "argument"
            switch (self.state) {
                .control_sequence_start, .control_sequence_delimiter => {
                    if ('<' <= char and char <= '?') {
                        self.control_sequence.args[self.control_sequence.index] = ControlSequenceArgument{ .char = char };
                        self.control_sequence.index += 1;
                    } else {
                        self.state = State{
                            .control_sequence_value = .{
                                .values = [_]u8{ char, 0, 0, 0, 0, 0, 0, 0 },
                                .index = 1,
                            },
                        };
                    }
                    break :blk true;
                },
                .control_sequence_value => |*val| {
                    val.*.values[val.*.index] = char;
                    val.*.index += 1;
                    break :blk true;
                },
                else => break :blk false,
            }
        },
        ';' => blk: {
            // control sequence "argument" delimiter
            switch (self.state) {
                .control_sequence_value => |val| {
                    self.handleVal(val);
                    self.state = .control_sequence_delimiter;
                    break :blk true;
                },
                .control_sequence_delimiter => {
                    // empty arguments are treated as 0
                    self.control_sequence.args[self.control_sequence.index] = ControlSequenceArgument{ .number = 0 };
                    self.control_sequence.index += 1;
                    break :blk true;
                },
                else => break :blk false,
            }
        },
        '@'...'Z', '\\'...'~' => blk: {
            // control sequence "command" (final byte)
            switch (self.state) {
                .control_sequence_start => {
                    self.control_sequence.command = char;
                    self.control_sequence.ready_for_exec = true;
                    self.state = .control_sequence_command;
                    break :blk true;
                },
                .control_sequence_value => |val| {
                    self.handleVal(val);
                    self.control_sequence.ready_for_exec = true;
                    self.control_sequence.command = char;
                    self.state = .control_sequence_command;
                    break :blk true;
                },
                else => break :blk false,
            }
        },
        else => blk: {
            if (self.state != .none) {
                self.state = .none;
            }
            break :blk false;
        },
    };
}

/// Handle a control sequence
/// See https://vt100.net/docs/vt510-rm/chapter4.html#S4.6 for all control sequences to be handled
pub fn handleControlSequence(self: *Self, control_sequence: ControlSequence) void {
    // check for the control sequence command to be executed
    switch (control_sequence.command) {
        // change color
        'm' => self.selectGraphicRendition(control_sequence),
        'J' => self.eraseInDisplay(control_sequence),
        else => log.warn("Unknown control sequence, skipping", .{}),
    }
}

/// Handle a special character
///
/// Will get important when using control sequences
pub fn handleSpecialChar(self: *Self, char: u8) void {
    switch (char) {
        '\n' => {
            self.curpos.row += 1;
            self.curpos.column = 0;
        },
        else => {
            if (self.control_sequence.ready_for_exec) {
                self.handleControlSequence(self.control_sequence);
            }
        },
    }
}

/// Put out text
pub fn puts(self: *Self, msg: []const u8) void {
    for (msg) |char| {
        if (!self.isSpecialChar(char)) {
            const cp437 = fonts.unicodeToCP437(char);
            self.drawChar(cp437, self.curpos.column, self.curpos.row);
            self.curpos.column += 1;
        } else {
            self.handleSpecialChar(char);
        }
        if (self.curpos.column == self.max_width) {
            self.curpos.column = 0;
            self.curpos.row += 1;
        }
        if (self.curpos.row == self.max_height) {
            self.curpos.row -= 1;
            self.scroll();
        }
    }
}
