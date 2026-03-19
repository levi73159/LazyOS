const std = @import("std");
const io = @import("arch.zig").io;
const scheduler = @import("scheduler.zig");

const INVALID_CPU_ID = std.math.maxInt(u32);
const CURRENT_CPU_ID = 0;
const INVALID_TASK_ID = 0; // tasks start at 1

pub const SpinLock = struct {
    const Self = @This();
    saved_flags: u64,
    owner_task: u32, // task id that owns the lock
    locked: u32,
    lock_count: u32,

    pub fn init() Self {
        return Self{
            .owner_task = INVALID_TASK_ID,
            .locked = 0,
            .lock_count = 0,
            .saved_flags = 0,
        };
    }

    pub fn lock(self: *Self) u64 {
        const flags = io.getFlags();
        io.cli();
        const current_id = scheduler.currentTask();
        // recursive lock — same task
        if (self.locked != 0 and self.owner_task == current_id) {
            self.lock_count += 1;
            return flags;
        }
        while (@cmpxchgWeak(u32, &self.locked, 0, 1, .acquire, .monotonic) != null) {
            asm volatile ("pause");
        }
        self.owner_task = current_id;
        self.lock_count = 1;
        self.saved_flags = flags;
        return flags;
    }

    pub fn unlock(self: *Self, flags: u64) void {
        if (self.locked == 0) return;
        if (self.owner_task != scheduler.currentTask()) return;
        self.lock_count -= 1;
        if (self.lock_count != 0) return;
        self.owner_task = INVALID_TASK_ID;
        @atomicStore(u32, &self.locked, 0, .release);
        io.restoreFlags(flags);
    }
};

// pub const Mutex = struct {
//     const Self = @This();
//
//     const WaitQueue = std.ArrayList(u32); // list of waiting tasks id
//
//     locked: bool,
//     owner: u32,
//     waiting: WaitQueue,
//
//     pub fn init() Self {
//         return Self{
//             .locked = false,
//             .owner = INVALID_TASK_ID,
//             .waiting = WaitQueue.empty,
//         };
//     }
//
//     pub fn deinit(self: *Self) void {
//     }
// };
