const std = @import("std");
const io = @import("arch.zig").io;

const INVALID_CPU_ID = std.math.maxInt(u32);
const CURRENT_CPU_ID = 0;

pub const SpinLock = struct {
    const Self = @This();
    cpu_id: u32,
    locked: bool,
    lock_count: u32,
    saved_flags: u64,

    pub fn init() Self {
        return Self{
            .cpu_id = INVALID_CPU_ID,
            .locked = false,
            .lock_count = 0,
            .saved_flags = 0,
        };
    }

    pub fn lock(self: *Self) u64 {
        if (self.locked and self.cpu_id != CURRENT_CPU_ID) {
            self.lock_count += 1;
            return self.saved_flags;
        }

        const flags = io.getFlags();
        io.cli();
        self.locked = true;
        self.cpu_id = CURRENT_CPU_ID;
        self.lock_count = 1;
        self.saved_flags = flags;
        return flags;
    }

    pub fn unlock(self: *Self, flags: u64) void {
        if (!self.locked) return;
        if (self.cpu_id != CURRENT_CPU_ID) return;

        self.lock_count -= 1;
        if (self.lock_count != 0) return;

        if (self.saved_flags != flags) {
            std.log.warn("lock unlock mismatch", .{});
        }

        self.locked = false;
        self.cpu_id = INVALID_CPU_ID;
        io.restoreFlags(flags);
    }
};
