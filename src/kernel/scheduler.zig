const std = @import("std");
const arch = @import("arch.zig");
const heap = @import("memory/heap.zig");

const page_allocator = heap.page_allocator; // use to allocate stack
const PAGE_SIZE = heap.PAGE_SIZE;

const STACK_SIZE = 1024 * 1024;

const log = std.log.scoped(._scheduler);

pub const TaskState = enum { ready, running, blocked, dead };

pub const Task = struct {
    id: u32,
    state: TaskState,
    stack: []u8,

    // saved register state (provied by interrupt handler)
    registers: arch.registers.InterruptFrame,
    next: ?*Task,
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
        .id = 0,
        .state = .running,
        .registers = undefined, // set in the first schedule
        .stack = &.{}, // not own by us
    };

    task_list = task;
    current = task;
}

pub fn schedule(frame: *arch.registers.InterruptFrame) void {
    if (task_list == null) return; // no tasks

    // log.debug("Scheduling", .{});
    // log.debug("\n{f}", .{frame.*});
    if (current) |task| {
        if (task.state == .dead) {
            // log.warn("Task {d} is dead", .{task.id});
            // removeTask(task);
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
    // log.debug("switching to rsp={x}", .{current.?.registers.rsp});
    // log.debug("current task: {d}", .{current.?.id});

    frame.* = current.?.registers; // copy saved register state
    // log.debug("rsp mod 16 = {}", .{current.?.registers.rsp % 16});
}

fn taskExit() noreturn {
    current.?.state = .dead;
    log.warn("Task {d} exited", .{current.?.id});
    while (true) {
        asm volatile ("hlt");
    }
}

// add a way of creating a task
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
pub fn addTask(entry_point: *const fn () noreturn) void {
    const allocator = heap.allocator();
    const stack = allocator.alignedAlloc(u8, .@"16", STACK_SIZE) catch {
        log.err("Failed to allocate stack", .{});
        return;
    };

    log.debug("stack: {x} - {x}", .{ @intFromPtr(stack.ptr), @intFromPtr(stack.ptr) + STACK_SIZE });

    const stack_top = @intFromPtr(stack.ptr) + STACK_SIZE;

    // leave 128 bytes of space before taskExit
    // so the function prologue doesn't overwrite it
    const error_slot = stack_top - 32; // 16 bytes padding
    const rsp = stack_top - 128 - 8;

    const ret_addr: *usize = @ptrFromInt(rsp);
    ret_addr.* = @intFromPtr(&taskExit);

    const task = allocator.create(Task) catch {
        log.err("Failed to allocate task", .{});
        return;
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
        .rdi = error_slot,

        .error_code = 0,
        .interrupt_number = 0,
        .r10 = 0,
        .r11 = 0,
        .r12 = 0,
        .r13 = 0,
        .r14 = 0,
        .r15 = 0,
        .r8 = 0,
        .r9 = 0,
        .rax = 0,
        .rbx = 0,
        .rcx = 0,
        .rdx = 0,
        .rsi = 0,
    };

    task.* = .{
        .state = .ready,
        .id = @bitCast(@as(i32, -1)), // id not set here, will be set in appendTask(task: *Task)
        .stack = stack,
        .registers = frame,
        .next = null,
    };

    appendTask(task);
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

