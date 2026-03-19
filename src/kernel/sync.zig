const std = @import("std");
const io = @import("arch.zig").io;
const scheduler = @import("scheduler.zig");

const INVALID_CPU_ID = std.math.maxInt(u32);
const CURRENT_CPU_ID = 0;
const INVALID_TASK_ID = 0; // tasks start at 1

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
        // recursive lock — same task
        if (self.locked != 0 and self.cpu_id == CURRENT_CPU_ID) {
            self.lock_count += 1;
            return flags;
        }
        while (@cmpxchgWeak(u32, &self.locked, 0, 1, .acquire, .monotonic) != null) {
            asm volatile ("pause");
        }
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

    const WaitQueue = std.ArrayList(u32); // list of waiting tasks id

    locked: bool,
    owner: u32,
    waiting: WaitQueue,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .locked = false,
            .owner = INVALID_TASK_ID,
            .waiting = WaitQueue.empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.waiting.deinit(self.allocator);
    }

    pub fn lock(self: *Self) void {
        io.cli();
        defer io.sti();

        const current_id = scheduler.currentTask();
        if (self.locked and self.owner == current_id) return;

        if (!self.locked) {
            self.locked = true;
            self.owner = current_id;
            return;
        }

        self.waiting.append(self.allocator, current_id) catch {
            std.log.err("Failed to add task to mutex wait queue: Out of memory", .{});
            return;
        };

        io.sti();
        scheduler.waitForTaskToWake(self.owner);
    }

    pub fn unlock(self: *Self) void {
        const current_id = scheduler.currentTask();
        if (!self.locked or self.owner != current_id) return;

        io.cli();
        if (self.waiting.items.len > 0) {
            // wake up next waiting task
            const next_id = self.waiting.orderedRemove(0);
            self.owner = next_id;
            // task will re-acquire when it wakes
            scheduler.wakeTask(next_id);
        } else {
            self.locked = false;
            self.owner = std.math.maxInt(u32);
        }
        io.sti();
    }

    pub fn tryLock(self: *Self) bool {
        if (self.locked) return false;
        io.cli();
        defer io.sti();
        if (self.locked) return false;
        self.locked = true;
        self.owner = scheduler.currentTask();
        return true;
    }
};
