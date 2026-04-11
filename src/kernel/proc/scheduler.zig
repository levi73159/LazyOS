const std = @import("std");
const root = @import("root");
const msr = root.arch.msr;
const arch = root.arch;
const heap = root.heap;
const io = arch.io;
const gdt = arch.descriptors.gdt;
const pit = root.pit;
const Process = @import("Process.zig");
const boot = root.boot;

const PAGE_SIZE = heap.PAGE_SIZE;

const STACK_SIZE = 16 * 1024; // or 4 pages

const log = std.log.scoped(._scheduler);

var paused: bool = false;

pub const TaskState = union(enum) {
    ready, // ready to run
    running, // currently running
    dead: u64, // task is dead (with return value)
    waiting: WaitingState, // waiting for task with id
    wait_input, // TODO: make it where it will specify which TTY this is waiting for
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
    stack: []u8, // required to be free
    process: ?*Process = null,

    next: ?*Task,

    id: u32,
    state: TaskState,
    fs_base: u64 = 0,

    // saved register state (provied by interrupt handler)
};

// will be stored on the heap
var current: ?*Task = null;
var task_list: ?*Task = null; // linked list
var first: bool = false;
var task_has_died: bool = false;

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

    idle_frame = arch.registers.InterruptFrame{
        .rip = @intFromPtr(&idleLoop),
        .rsp = @intFromPtr(&boot.kernel_stack) + boot.KERNEL_STACK_SIZE - 8,
        .cs = @intFromEnum(gdt.Segment.kernel_code),
        .ss = @intFromEnum(gdt.Segment.kernel_data),
        .ds = @intFromEnum(gdt.Segment.kernel_data),
        .rflags = 0x202, // IF=1 so interrupts still fire
    };
}

pub fn schedule(frame: *arch.registers.InterruptFrame) void {
    if (task_list == null) return; // no tasks

    paused = false;
    // try to free resources after every 10 ticks ()
    if (task_has_died and pit.ticks() % 10 == 0) {
        removeDeadTasks();
    }

    if (current) |task| {
        checkWaitingTasks(task);
        if (task.state == .dead) {
            task_has_died = true;
            log.warn("Task {d} is dead", .{task.id});
        } else if (task.state == .wait_input or task.state == .waiting) {
            // blocked task — only save registers, don't touch state
            task.registers = frame.*;
            task.fs_base = msr.read(0xC0000100);
        } else {
            task.state = .ready;
            task.registers = frame.*;
            task.fs_base = msr.read(0xC0000100);
        }
    }

    var next = if (current) |task| (task.next orelse task_list) else task_list;
    while (next.?.state != .ready) {
        next = next.?.next orelse task_list;

        if (next == current or (next == task_list and current == null)) {
            if (current == null or current.?.state != .ready) {
                frame.* = idle_frame.?;
                current = null; // no current tasks
                arch.paging.getKernelVmem().switchTo();
                return;
            }
            current.?.state = .running;
            return; // continue execution
        }
    }

    current = next;
    current.?.state = .running;
    frame.* = current.?.registers; // copy saved register state

    msr.write(0xC0000100, current.?.fs_base);
    if (current.?.process) |process| {
        const kstack_top = @intFromPtr(current.?.stack.ptr) + current.?.stack.len;
        gdt.tss.rsp0 = kstack_top;
        arch.syscall.kernel_rsp = kstack_top;

        process.vmem.switchTo();
    } else {
        arch.paging.getKernelVmem().switchTo();
    }
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
                        log.debug("Waking task {d} because task {d} exited", .{ node.id, task.id });
                        node.state = .ready;
                    }
                },
            }
        }
    }
}

fn removeDeadTasks() void {
    var current_node = task_list;
    if (current_node.?.state != .dead) {
        task_has_died = false;
    }
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
    current.?.state = .{ .dead = 0 };
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
pub fn addTaskFunc(entry_point: anytype, args: anytype) u32 {
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
    return createTask(@intFromPtr(entry_point), rsp, stack, false, args);
}

/// Creates a task with a specific entry point and meta data, and appends it to the task list as ready
/// Args:
/// - *rip*: the start address of the task (what will be executed when the task is scheduled)
/// - *rsp*: the stack pointer of the task (what the stack pointer will be when the task is scheduled)
/// - *code*: the code data of the stack (to be freed when the task is removed)
/// - *stack*: the stack data of the stack (to be freed when the task is removed, stack is always mapped in HHDM while rsp can be mapped in any)
/// - *user*: whether the task is executed in user mode or kernel mode
/// - *args*: the arguments to be passed to the task (starting in rip ending in r9)
pub fn createTask(rip: u64, rsp: u64, stack: []u8, user: bool, args: anytype) u32 {
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

    log.debug("Adding task with entry_point: {x}", .{rip});

    // assumes stack is already aligned
    const cs: usize = if (user) @intFromEnum(gdt.Segment.user_code) else @intFromEnum(gdt.Segment.kernel_code);
    const ds: usize = if (user) @intFromEnum(gdt.Segment.user_data) else @intFromEnum(gdt.Segment.kernel_data);
    const frame = arch.registers.InterruptFrame{
        .cs = cs,
        .rflags = 0x202,
        .rsp = rsp,
        .rbp = 0,
        .ss = ds,
        .ds = ds,
        .rip = rip,

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

    const allocator = heap.allocator();

    const task = allocator.create(Task) catch {
        log.err("Failed to allocate task", .{});
        return @bitCast(@as(i32, -1));
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

pub fn spawnProcess(process: *Process) !u32 {
    const allocator = heap.allocator();

    const kstack = try allocator.alignedAlloc(u8, .@"16", STACK_SIZE);
    const kstack_top = @intFromPtr(kstack.ptr) + STACK_SIZE;

    const frame = arch.registers.InterruptFrame{
        .rip = process.entry,
        .rsp = process.stack_top,
        .rbp = 0,
        .cs = @intFromEnum(gdt.Segment.user_code),
        .ds = @intFromEnum(gdt.Segment.user_data),
        .ss = @intFromEnum(gdt.Segment.user_data),
        .rflags = 0x202,
    };

    const task = try allocator.create(Task);
    task.* = .{
        .state = .ready,
        .id = @bitCast(@as(i32, -1)), // id not set here, will be set in appendTask(task: *Task)
        .stack = kstack,
        .registers = frame,
        .next = null,
        .process = process,
    };

    root.dev.tty0.fdInit(&process.fd_table);

    appendTask(task);

    log.debug("Spawned process task {d} entry={x} ustack={x} kstack={x}", .{ task.id, process.entry, process.stack_top, kstack_top });

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

    if (task.process) |process| {
        process.deinit(allocator);
        allocator.destroy(process);
    }

    allocator.destroy(task);
}

pub fn killTask(id: u32) void {
    if (getTask(id)) |task| {
        task.state = .{ .dead = 137 }; // SIGKILL
    }
}

pub fn currentTask() u32 {
    return if (current) |task| task.id else 0;
}

pub fn taskExit(code: u64) noreturn {
    io.cli();
    current.?.state = .{ .dead = code };
    io.sti();
    io.hlt();
}

pub fn waitForTaskToExit(id: u32) u64 {
    // check if task is alreay dead or gone
    while (true) {
        if (getTask(id)) |task| {
            switch (task.state) {
                .dead => |exitval| return exitval,
                else => {},
            }
        } else {
            return 0;
        }

        if (current) |task| {
            task.state = .{ .waiting = .{
                .task_id = id,
                .wait_type = .exit,
            } };
        }

        io.sti();
        asm volatile ("hlt");
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
        io.sti();
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

/// Assumes task is running
pub fn getCurrentTask() *Task {
    return current.?;
}

pub fn getCurrentProcess() ?*Process {
    return if (current) |task| task.process else null;
}

pub fn getProcess(id: u32) ?*Process {
    if (getTask(id)) |task| {
        return task.process;
    }
    return null;
}

pub fn wakeInputWaiters() void {
    var current_node = task_list;
    while (current_node) |node| : (current_node = node.next) {
        if (node.state == .wait_input) {
            node.state = .ready;
        }
    }
}

pub fn waitInput() void {
    if (current) |task| {
        task.state = .wait_input;
    }
    asm volatile ("sti; hlt");
}

// set up once at init
var idle_frame: ?arch.registers.InterruptFrame = null;
fn idleLoop() callconv(.c) noreturn {
    while (true) {
        asm volatile ("sti; hlt");
    }
}
