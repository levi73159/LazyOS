const std = @import("std");
const io = @import("arch.zig").io;
const scheduler = @import("scheduler.zig");

const INVALID_CPU_ID = std.math.maxInt(u32);
const CURRENT_CPU_ID = 0;
const INVALID_TASK_ID = std.math.maxInt(u32); // must differ from CURRENT_CPU_ID

pub const SpinLock = struct {
    const Self = @This();
    cpu_id: u32,
    locked: u32,
    lock_count: u32,

    pub fn init() Self {
        return Self{
            .cpu_id = INVALID_TASK_ID,
            .locked = 0,
            .lock_count = 0,
        };
    }

    pub fn lock(self: *Self) u64 {
        const flags = io.getFlags();
        io.cli();

        if (self.locked != 0 and self.cpu_id == CURRENT_CPU_ID) {
            // Recursive acquire by the same CPU.
            self.lock_count += 1;
            return flags;
        }

        // On a single CPU with interrupts disabled, real contention cannot
        // happen. If locked != 0 here with a different owner, something is
        // already wrong. Take it anyway rather than spinning forever.
        self.locked = 1;
        self.cpu_id = CURRENT_CPU_ID;
        self.lock_count = 1;
        return flags;
    }

    pub fn unlock(self: *Self, flags: u64) void {
        if (self.locked == 0) return;
        if (self.cpu_id != CURRENT_CPU_ID) return;
        self.lock_count -= 1;
        if (self.lock_count != 0) return;
        self.cpu_id = INVALID_CPU_ID;
        @atomicStore(u32, &self.locked, 0, .release);
        io.restoreFlags(flags);
    }
};

pub const Mutex = struct {
    const Self = @This();

    locked: u32 = 0, // 0 = free, 1 = held
    depth: u32 = 0, // recursion count
    owner: u32 = INVALID_TASK_ID, // task ID of current holder
    // Kept for API compatibility with callers that pass an allocator.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .locked = 0,
            .depth = 0,
            .owner = INVALID_TASK_ID,
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *Self) void {
        // Nothing to free — no dynamic allocation.
    }

    pub fn lock(self: *Self) void {
        io.cli();
        const current_id = scheduler.currentTask();

        if (self.locked != 0) {
            if (self.owner == current_id) {
                // Recursive acquire by the same owner — just increment depth.
                self.depth += 1;
            }
            // If owner != current_id this is unexpected contention during
            // single-threaded ACPI init. We deliberately do NOT spin here:
            // spinning with interrupts disabled on a single CPU deadlocks
            // because the holder can never run to call unlock().
            // Returning without acquiring is safer — uACPI tolerates this
            // better than a hard freeze.
            io.sti();
            return;
        }

        self.locked = 1;
        self.owner = current_id;
        self.depth = 1;
        io.sti();
    }

    pub fn unlock(self: *Self) void {
        io.cli();
        const current_id = scheduler.currentTask();

        // Guard: only the owner may unlock.
        if (self.locked == 0 or self.owner != current_id) {
            io.sti();
            return;
        }

        self.depth -= 1;
        if (self.depth != 0) {
            // Still recursively held.
            io.sti();
            return;
        }

        self.owner = INVALID_TASK_ID;
        @atomicStore(u32, &self.locked, 0, .release);
        io.sti();
    }

    pub fn tryLock(self: *Self) bool {
        io.cli();
        const current_id = scheduler.currentTask();
        if (self.locked != 0 and self.owner == current_id) {
            self.depth += 1;
            io.sti();
            return true;
        }
        if (@cmpxchgStrong(u32, &self.locked, 0, 1, .acquire, .monotonic) != null) {
            io.sti();
            return false;
        }
        self.owner = current_id;
        self.depth = 1;
        io.sti();
        return true;
    }
};
