const std = @import("std");

pub const SpinLock = struct {
    const Self = @This();

    pub fn create() Self {
        return .{};
    }
};
