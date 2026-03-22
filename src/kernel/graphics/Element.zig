const std = @import("std");
const ui = @import("ui.zig");
const Screen = @import("Screen.zig");

pub const Position = struct {
    x: u32,
    y: u32,

    pub fn add(self: Position, other: Position) Position {
        return Position{
            .x = self.x + other.x,
            .y = self.y + other.y,
        };
    }

    pub fn sub(self: Position, other: Position) Position {
        return Position{
            .x = self.x - other.x,
            .y = self.y - other.y,
        };
    }
};

pub const Anchor = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};

pub const AnchorOffset = struct {
    x: i32,
    y: i32,
    anchor: Anchor,
};

pub const ElementPosition = union(enum) {
    absolute: Position,
    relative: AnchorOffset,
    anchor: Anchor,
};

pos: ElementPosition,
tex: *const ui.Texture,

const Self = @This();

pub fn init(pos: ElementPosition, tex: *const ui.Texture) Self {
    return Self{
        .pos = pos,
        .tex = tex,
    };
}

pub fn initNamed(pos: ElementPosition, name: []const u8) Self {
    return Self{
        .pos = pos,
        .tex = ui.get(name) orelse std.debug.panic("Texture {s} not found", .{name}),
    };
}

pub fn absolutePosition(self: Self, screen: *Screen) Position {
    return switch (self.pos) {
        .absolute => self.pos.absolute,
        .relative => |offset| blk: {
            const pos = self.getAnchorPosition(screen, offset.anchor);
            const x_added: i64 = @as(i64, pos.x) + offset.x;
            const y_added: i64 = @as(i64, pos.y) + offset.y;

            const x_clamped: u32 = @intCast(std.math.clamp(x_added, 0, screen.width));
            const y_clamped: u32 = @intCast(std.math.clamp(y_added, 0, screen.height));

            break :blk Position{
                .x = x_clamped,
                .y = y_clamped,
            };
        },
        .anchor => |anchor| self.getAnchorPosition(screen, anchor),
    };
}

pub fn getAnchorPosition(self: Self, screen: *Screen, anchor: Anchor) Position {
    return switch (anchor) {
        .top_left => .{
            .x = 0,
            .y = 0,
        },
        .top_right => .{
            .x = screen.width - self.tex.width,
            .y = 0,
        },
        .bottom_left => .{
            .x = 0,
            .y = screen.height - self.tex.height,
        },
        .bottom_right => .{
            .x = screen.width - self.tex.width,
            .y = screen.height - self.tex.height,
        },
        .center => .{
            .x = screen.width / 2 - self.tex.width / 2,
            .y = screen.height / 2 - self.tex.height / 2,
        },
    };
}
