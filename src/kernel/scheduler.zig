const std = @import("std");
const arch = @import("arch.zig");
const heap = @import("memory/heap.zig");
const io = arch.io;
const pit = @import("pit.zig");

const PAGE_SIZE = heap.PAGE_SIZE;

const STACK_SIZE = 16 * 1024; // or 4 pages

const log = std.log.scoped(._scheduler);

var paused: bool = false;

pub const TaskState = union(enum) {
    ready, // ready to run
    running, // currently running
    dead, // task is dead
    waiting: WaitingState, // waiting for task with id
};

pub const WaitType = enum(u8) {
    wake, // waits for task to be called
    exit, // waits for task to exit
};

pub const WaitingState = struct {
    task_id: u32,
    wait_type: WaitType,
};

pub const Task = struct {
    registers: arch.registers.InterruptFrame,
    stack: []u8,
    next: ?*Task,

    id: u32,
    state: TaskState,

    // saved register state (provied by interrupt handler)
};

// will be stored on the heap
var current: ?*Task = null;
var task_list: ?*Task = null; // linked list
var first: bool = false;

pub fn init() void {
    const allocator = heap.allocator();

    const task = allocator.create(Task) catch {
        log.err("Failed to allocate task", .{});
        return;
    };

    task.* = .{
        .next = null,
        .id = 1,
        .state = .running,
        .registers = undefined, // set in the first schedule
        .stack = &.{}, // not own by us
    };

    task_list = task;
    current = task;
}

pub fn schedule(frame: *arch.registers.InterruptFrame) void {
    if (task_list == null) return; // no tasks

    paused = false;
    if (pit.ticks() % 5 == 0) {
        removeDeadTasks();
    }

    if (current) |task| {
        checkWaitingTasks(task);
        if (task.state == .dead) {
            log.warn("Task {d} is dead", .{task.id});
        } else {
            // log.debug("Copying frame to registers", .{});
            task.state = .ready;
            task.registers = frame.*;
        }
    }

    var next = if (current) |task| (task.next orelse task_list) else task_list;
    while (next.?.state != .ready) {
        next = next.?.next orelse task_list;

        if (next == current) {
            current.?.state = .running;
            return; // continue execution
        }
    }

    current = next;
    current.?.state = .running;
    frame.* = current.?.registers; // copy saved register state
}

fn checkWaitingTasks(task: *Task) void {
    var current_node = task_list;
    while (current_node) |node| : (current_node = node.next) {
        if (node.state == .waiting) {
            if (node.state.waiting.task_id != task.id) continue;
            switch (node.state.waiting.wait_type) {
                .wake => {
                    if (task.state == .ready or task.state == .running) {
                        node.state = .ready;
                    }
                },
                .exit => {
                    if (task.state == .dead) {
                        node.state = .ready;
                    }
                },
            }
        }
    }
}

fn removeDeadTasks() void {
    var current_node = task_list;
    while (current_node) |task| : (current_node = task.next) {
        if (current == task) continue; // do not remove current task even if it is dead
        if (task.state == .dead) {
            removeTask(task);
        }
    }
}

fn taskReturn() noreturn {
    asm volatile ("andq $-16, %%rsp");
    io.cli();
    log.warn("Task Exit", .{});
    current.?.state = .dead;
    log.warn("Task {d} exited", .{current.?.id});
    io.sti();
    while (true) {
        asm volatile ("hlt");
    }
}

// add two ways of creating a task (adding task which adds a task and with a specify entry_point, usefull if you want a task that is a function and doesn't wanna spawn task at current position)
// 1. allocate 16KB stack from heap/page allocator and add a return address that will point to taskExit
// 2. set up initial InterruptFrame:
//    - RIP = function entry point
//    - CS  = 0x08
//    - RFLAGS = 0x202
//    - RSP = stack_base + stack_size  ← top of stack (grows down)
//    - SS  = 0x10
//    - all other registers = 0
// 3. place the InterruptFrame at the TOP of the stack
//    (so context pointer points into the task's own stack)
// 4. add task to linked list
// 5. set state = .ready
pub fn addTask(entry_point: anytype, args: anytype) u32 {
    const entry_info = @typeInfo(@TypeOf(entry_point));
    if (entry_info != .pointer) {
        @compileError("entry_point must be a function");
    }
    const entry_fn = if (entry_info == .@"fn") entry_info.@"fn" else @typeInfo(entry_info.pointer.child).@"fn";
    const args_info = @typeInfo(@TypeOf(args));
    if (args_info != .@"struct" or args_info.@"struct".is_tuple == false) {
        @compileError("args must be a tuple");
    }
    if (args_info.@"struct".fields.len != entry_fn.params.len) {
        @compileError("Not enough arguments for entry_point, specify more arguments");
    }

    const allocator = heap.allocator();
    const stack = allocator.alignedAlloc(u8, .@"16", STACK_SIZE) catch {
        log.err("Failed to allocate stack", .{});
        return 0;
    };

    log.debug("stack: {x} - {x}", .{ @intFromPtr(stack.ptr), @intFromPtr(stack.ptr) + STACK_SIZE });

    const stack_top = @intFromPtr(stack.ptr) + STACK_SIZE;

    // leave 128 bytes of space before taskExit
    // so the function prologue doesn't overwrite it
    const rsp = stack_top - 48 - 8;

    const ret_addr: *usize = @ptrFromInt(rsp);
    ret_addr.* = @intFromPtr(&taskReturn);

    const task = allocator.create(Task) catch {
        log.err("Failed to allocate task", .{});
        return 0;
    };

    const helper = struct {
        pub fn getArg(_args: anytype, comptime index: comptime_int) usize {
            const info = @typeInfo(@TypeOf(_args));
            if (info != .@"struct" or info.@"struct".is_tuple == false) {
                @compileError("_args must be a tuple");
            }
            if (index >= info.@"struct".fields.len) {
                return 0;
            }
            const field_type = info.@"struct".fields[index].type;
            const field_info = @typeInfo(field_type);
            switch (field_info) {
                .int => return _args[index],
                .pointer => return @intFromPtr(_args[index]),
                else => @compileError("Unsupported argument type: " ++ @typeName(field_type)),
            }
            return _args[index];
        }
    };

    log.debug("Adding task with entry_point: {x}", .{@intFromPtr(entry_point)});
    const frame = arch.registers.InterruptFrame{
        .cs = 0x08,
        .rflags = 0x202,
        .rsp = rsp,
        .rbp = 0,
        .ss = 0x10,
        .ds = 0x10,
        .rip = @intFromPtr(entry_point),

        // args
        .rdi = helper.getArg(args, 0),
        .rsi = helper.getArg(args, 1),
        .rdx = helper.getArg(args, 2),
        .rcx = helper.getArg(args, 3),
        .r8 = helper.getArg(args, 4),
        .r9 = helper.getArg(args, 5),

        .error_code = 0,
        .interrupt_number = 0,
        .r10 = 0,
        .r11 = 0,
        .r12 = 0,
        .r13 = 0,
        .r14 = 0,
        .r15 = 0,
        .rax = 0,
        .rbx = 0,
    };

    task.* = .{
        .state = .ready,
        .id = @bitCast(@as(i32, -1)), // id not set here, will be set in appendTask(task: *Task)
        .stack = stack,
        .registers = frame,
        .next = null,
    };

    appendTask(task);
    return task.id;
}

/// NOTE: also sets id
fn appendTask(task: *Task) void {
    if (task_list) |list| {
        var current_node = list;
        while (current_node.next) |next| {
            current_node = next;
        }

        current_node.next = task;
        task.next = null;

        task.id = current_node.id + 1;
    } else {
        task_list = task;
        task.id = 0;
        task.next = null;
    }
}

fn getPrev(task: *Task) ?*Task {
    if (task == task_list) return null;
    var current_node = task_list;
    while (current_node) |node| {
        if (node.next == task) {
            return node;
        }
        current_node = node.next;
    }
    return null;
}

fn getTask(id: u32) ?*Task {
    var current_node = task_list;
    while (current_node) |node| {
        if (node.id == id) {
            return node;
        }
        current_node = node.next;
    }
    return null;
}

fn removeTask(task: *Task) void {
    const prev = getPrev(task) orelse {
        log.warn("Tried to remove first task", .{});
        return;
    };

    prev.next = task.next;
    const allocator = heap.allocator();
    // const
    // deallocate stack, task, etc..
    if (task.stack.len != 0) {
        allocator.free(task.stack);
    }

    allocator.destroy(task);
}

pub fn killTask(id: u32) void {
    if (getTask(id)) |task| {
        task.state = .dead;
    }
}

pub fn currentTask() u32 {
    return if (current) |task| task.id else 0;
}

pub fn taskExit() noreturn {
    io.cli();
    current.?.state = .dead;
    io.sti();
    io.hlt();
}

pub fn waitForTaskToExit(id: u32) void {
    // check if task is alreay dead or gone
    if (getTask(id)) |task| {
        if (task.state == .dead) return;
    } else {
        return;
    }

    if (current) |task| {
        task.state = .{ .waiting = .{
            .task_id = id,
            .wait_type = .exit,
        } };
    }
    while (true) {
        asm volatile ("hlt");
        if (current) |task| {
            if (task.state == .ready or task.state == .running) break;
        }
    }
}

pub fn waitForTaskToWake(id: u32) void {
    if (current) |task| {
        task.state = .{ .waiting = .{
            .wait_type = .wake,
            .task_id = id,
        } };
    }
    while (true) {
        asm volatile ("hlt");
        if (getTask(id)) |task| {
            if (task.state == .ready or task.state == .running) break;
        }
    }
}

// wait for task to wake
pub fn wakeTask(id: u32) void {
    if (getTask(id)) |task| {
        switch (task.state) {
            .waiting => task.state = .ready,
            .dead => {}, // can't wake dead task
            else => {}, // already ready or running
        }
    }
}
