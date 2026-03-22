const std = @import("std");
const ui = @import("ui.zig");
const Screen = @import("Screen.zig");
const Position = @import("../Position.zig");

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn isInRect(self: Rect, pos: Position) bool {
        return pos.x >= self.x and pos.x < self.x + self.width and pos.y >= self.y and pos.y < self.y + self.height;
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
visible: bool = true,

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

pub fn asRect(self: Self, screen: *Screen) Rect {
    const abs = self.absolutePosition(screen);
    return Rect{
        .x = abs.x,
        .y = abs.y,
        .width = self.tex.width,
        .height = self.tex.height,
    };
}

pub const MouseState = struct {
    left_clicked: bool = false,
    right_clicked: bool = false,
    middle_clicked: bool = false,
    mouse_down: bool = false,
    mouse_hover: bool = false,
    rel_x: i32 = 0,
    rel_y: i32 = 0,
};

/// Gets mouse state of the element
/// get whether the mouse is hovering over the element,
/// get whether the mouse is clicking on the element
/// get the relative position of the mouse
pub fn getMouseState(self: Self, screen: *Screen) MouseState {
    const mouse = @import("../mouse.zig");

    const pos = mouse.getPosition();

    const rect = self.asRect(screen);

    const is_hover = rect.isInRect(pos);

    return MouseState{
        .mouse_hover = is_hover,
        .left_clicked = mouse.isButtonJustPressed(.left) and is_hover,
        .right_clicked = mouse.isButtonJustPressed(.right) and is_hover,
        .middle_clicked = mouse.isButtonJustPressed(.middle) and is_hover,
        .mouse_down = mouse.isButtonPressed(.left) or mouse.isButtonPressed(.right) or mouse.isButtonPressed(.middle),
        .rel_x = @intCast(@as(i64, @intCast(pos.x)) - rect.x),
        .rel_y = @intCast(@as(i64, @intCast(pos.y)) - rect.y),
    };
}
