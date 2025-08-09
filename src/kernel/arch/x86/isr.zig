const std = @import("std");
const idt = @import("idt.zig");
const gdt = @import("gdt.zig");
const log = @import("std").log.scoped(.isr);
const console = @import("../../console.zig");
const host = @import("std").log.scoped(.host);
const io = @import("../io.zig");

const InterruptFn = *const fn () callconv(.naked) noreturn;
pub const Handler = *const fn (frame: *InterruptFrame) void;

const InterruptFrame = packed struct {
    ds: u32,
    eax: u32,
    ecx: u32,
    edx: u32,
    ebx: u32,
    kernelesp: u32,
    ebp: u32,
    esi: u32,
    edi: u32,
    interrupt_number: u32,
    error_code: u32,
    eip: u32,
    cs: u32,
    eflags: u32,
    useresp: u32,
    ss: u32,
};

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
        if (number <= 31) {
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
}

export fn interruptHandler(frame: *InterruptFrame) callconv(.c) void {
    log.debug("Interrupt {d}", .{frame.interrupt_number});
    if (handlers[frame.interrupt_number]) |handler| {
        handler(frame);
    } else if (frame.interrupt_number >= 32) {
        host.warn("Unhandled interrupt {d}", .{frame.interrupt_number});
        return;
    }

    handleError(frame);
}

fn handleError(frame: *InterruptFrame) noreturn {
    const exception: Exception = @enumFromInt(frame.interrupt_number);
    console.printB("\x1b[97;41m", .{});
    console.printB("!!! UNHANDLED EXCEPTION !!!\n", .{});
    console.printB("Unhandled exception {d} {s}\n", .{ frame.interrupt_number, @tagName(exception) });

    console.printB("   eax={x}   ebx={x}   ecx={x}   edx={x}   esi={x}   edi={x}\n", .{
        frame.eax,
        frame.ebx,
        frame.ecx,
        frame.edx,
        frame.esi,
        frame.edi,
    });

    console.printB("   esp={x}   ebp={x}   eip={x}   eflags={x}\n   cs={x}   ds={x}   ss={x}\n", .{
        frame.kernelesp,
        frame.ebp,
        frame.eip,
        frame.eflags,
        frame.cs,
        frame.ds,
        frame.ss,
    });

    console.printB("   error={x}   interrupt={x}\n", .{ frame.error_code, frame.interrupt_number });

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
                if (Exception.hasErrorNumber(number)) {
                    asm volatile (
                        \\push %[num]
                        \\jmp interruptCommon
                        :
                        : [num] "r" (@as(u32, number)),
                    );
                } else {
                    asm volatile (
                        \\push $0
                        \\push %[num]
                        \\jmp interruptCommon
                        :
                        : [num] "r" (@as(u32, number)),
                    );
                }
            }
        }.handler,
    };
}

export fn interruptCommon() callconv(.naked) noreturn {
    asm volatile (
    // push general-purpose registers
        \\ push %%edi
        \\ push %%esi
        \\ push %%ebp
        \\ push %%esp
        \\ push %%ebx
        \\ push %%edx
        \\ push %%ecx
        \\ push %%eax
        \\ 
        // push data segment
        \\ mov $0x0, %%eax
        \\ mov %%ds, %%ax
        \\ push %%eax
        \\ 
        // set segment to run in kernel data
        \\ mov $0x10, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ 
        // push stack pointer and pass it to c
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
        \\ pop %%eax
        \\ pop %%ecx
        \\ pop %%edx
        \\ pop %%ebx
        \\ pop %%esp
        \\ pop %%ebp
        \\ pop %%esi
        \\ pop %%edi
        \\ add $8, %%esp
        \\ 
        \\ iret
    );
}
