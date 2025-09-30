const std = @import("std");
const builtin = @import("builtin");
const desc = @import("descriptors.zig");
const idt = desc.idt;
const gdt = desc.gdt;
const log = @import("std").log.scoped(.isr);
const console = @import("../console.zig");
const host = @import("std").log.scoped(.host);
const io = @import("io.zig");

const InterruptFn = *const fn () callconv(.naked) noreturn;
pub const Handler = *const fn (frame: GlobalFrame) void;

const InterruptFrame = @import("registers.zig").ArchFrame;
const GlobalFrame = @import("registers.zig").InterruptFrame;

pub const Exception = enum(u8) {
    division_by_zero = 0,
    debug = 1,
    non_maskable_interrupt = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range_exceeded = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_segment_fault = 12,
    general_protection_fault = 13,
    page_fault = 14,
    reserved = 15,
    x87_floating_point = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_floating_point = 19,
    virtualization = 20,
    control_protection = 21,
    // Reserved 22-27
    hypervisor_injection = 28,
    vmm_comm = 29,
    security_exception = 30,
    reserved2 = 31,

    pub inline fn is(number: u8) bool {
        if (number < 32) {
            return true;
        } else {
            return false;
        }
    }

    pub inline fn hasErrorCode(self: Exception) bool {
        return switch (self) {
            .double_fault,
            .invalid_tss,
            .segment_not_present,
            .stack_segment_fault,
            .general_protection_fault,
            .page_fault,
            .alignment_check,
            .control_protection,
            .vmm_comm,
            .security_exception,
            .reserved2,
            => true,
            else => false,
        };
    }

    pub inline fn hasErrorNumber(num: u8) bool {
        if (!is(num)) return false;
        return hasErrorCode(@enumFromInt(num));
    }
};

var handlers: [256]?Handler = [_]?Handler{null} ** 256;

pub fn init() void {
    log.debug("Initializing ISRs", .{});
    log.debug("Enabling all interrupts", .{});
    inline for (0..256) |i| {
        if (getVector(i)) |handler| {
            idt.setGate(i, @intFromPtr(handler), .kernel_code, .{});
            idt.enableGate(i);
        } else {
            log.debug("Excluding interrupt {d}", .{i});
            idt.disableGate(i);
        }
    }

    idt.disableGate(0x80);
}

export fn interruptHandler(frame: *InterruptFrame) callconv(.c) void {
    if (handlers[frame.interrupt_number]) |handler| {
        handler(GlobalFrame.fromArchFrame(frame));
    } else if (frame.interrupt_number >= 32) {
        host.warn("Unhandled interrupt {d}", .{frame.interrupt_number});
    } else {
        handleError(frame);
    }
}

fn handleError(frame: *InterruptFrame) noreturn {
    log.debug("Unhandled interrupt", .{});
    const exception: Exception = @enumFromInt(frame.interrupt_number);
    console.printB("\x1b[97;41m", .{});
    console.printB("!!! UNHANDLED EXCEPTION !!!\n", .{});
    console.printB("Unhandled exception {d} {s}\n", .{ frame.interrupt_number, @tagName(exception) });

    console.printB("{f}\n", .{frame});

    console.printB("!!! KERNEL PANIC !!!\n", .{});
    console.printB("\x1b[0m", .{});

    io.hlt();
}

pub fn register(interrupt: u8, handler: Handler) void {
    handlers[interrupt] = handler;
}

pub fn unregister(interrupt: u8) void {
    handlers[interrupt] = null;
}

pub fn getVector(comptime number: u8) ?InterruptFn {
    return switch (number) {
        15, 22...27, 31 => null,
        else => struct {
            fn handler() callconv(.naked) noreturn {
                asm volatile ("cli");
                if (Exception.hasErrorNumber(number)) {
                    asm volatile (
                        \\push %[num]
                        \\jmp interruptCommon
                        :
                        : [num] "r" (@as(usize, number)),
                    );
                } else {
                    asm volatile (
                        \\push $0
                        \\push %[num]
                        \\jmp interruptCommon
                        :
                        : [num] "r" (@as(usize, number)),
                    );
                }
            }
        }.handler,
    };
}

export fn interruptCommon() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86 => asm volatile (
            \\ pusha
            \\ mov $0, %%eax
            \\ mov %%ds, %%ax
            \\ push %%eax
            \\
            \\ mov $0x10, %%ax
            \\ mov %%ax, %%ds
            \\ mov %%ax, %%es
            \\ mov %%ax, %%fs
            \\ mov %%ax, %%gs
            \\
            \\ push %%esp
            \\ call interruptHandler
            \\ add $4, %%esp
            \\ 
            \\ pop %%eax
            \\ mov %%ax, %%ds
            \\ mov %%ax, %%es
            \\ mov %%ax, %%fs
            \\ mov %%ax, %%gs
            \\
            \\ popa
            \\ add $8, %%esp
            \\ 
            \\ iret
        ),
        .x86_64 => asm volatile (
        // push general-purpose registers
            \\ push %%rax
            \\ push %%rbx
            \\ push %%rcx
            \\ push %%rdx
            \\ push %%r8
            \\ push %%r9
            \\ push %%r10
            \\ push %%r11
            \\ push %%r12
            \\ push %%r13
            \\ push %%r14
            \\ push %%r15
            \\ push %%rdi
            \\ push %%rsi
            \\ push %%rbp
            \\ 
            \\ mov $0, %%rax
            \\ mov %%ds, %%ax
            \\ push %%rax
            \\ 
            \\ mov $0x10, %%ax
            \\ mov %%ax, %%ds
            \\ mov %%ax, %%es
            \\ mov %%ax, %%fs
            \\ mov %%ax, %%gs
            \\ 
            \\ push %%rsp
            \\ call interruptHandler
            \\ add $8, %%rsp
            \\ 
            \\ pop %%rax
            \\ mov %%ax, %%ds
            \\ mov %%ax, %%es
            \\ mov %%ax, %%fs
            \\ mov %%ax, %%gs
            \\ 
            \\ pop %%rbp
            \\ pop %%rsi
            \\ pop %%rdi
            \\ pop %%r15
            \\ pop %%r14
            \\ pop %%r13
            \\ pop %%r12
            \\ pop %%r11
            \\ pop %%r10
            \\ pop %%r9
            \\ pop %%r8
            \\ pop %%rdx
            \\ pop %%rcx
            \\ pop %%rbx
            \\ pop %%rax
            \\ add $10, %%rsp
            \\ 
            \\ iretq
        ),
        else => unreachable,
    }
}
