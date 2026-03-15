const std = @import("std");
const arch = @import("arch.zig");

pub const TaskState = enum { ready, running, blocked, dead };

pub const Task = struct {
    id: u32,
    state: TaskState,
};
