const std = @import("std");
const Position = @This();

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

pub fn isInRect(self: Position, other: Position) bool {
    return self.x >= other.x and self.x < other.x + other.width and self.y >= other.y and self.y < other.y + other.height;
}
