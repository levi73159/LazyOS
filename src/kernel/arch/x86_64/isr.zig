//! Interrupt Descriptor Table

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024 Samuel Fiedler

const gdt = @import("./gdt.zig");
const registers = @import("./registers.zig");
const root = @import("root");
const std = @import("std");
const log = std.log.scoped(.arch_idt);

/// Entry in the Interrupt Descriptor Table
pub const Entry = packed struct(u128) {
    /// First part of a pointer to handler code
    offset_low: u16 = 0,
    /// Segment Selector (for example gdt.Selector.kernel_code)
    selector: u16 = @intFromEnum(gdt.Selector.kernel_code),
    /// A 3-bit value which is an offset into the Interrupt Stack Table, which is stored in the Task State Segment
    ist: u3 = 0,
    /// Reserved
    res1: u5 = 0,
    /// Gate Type
    gate_type: enum(u4) {
        interrupt_64bit = 14,
        trap_64bit = 15,
        _,
    } = .interrupt_64bit,
    /// Reserved
    res2: u1 = 0,
    /// CPU Privilege Levels allowed to access this interrupt
    dpl: enum(u2) {
        kernel = 0,
        user = 3,
        _,
    } = .kernel,
    /// Present bit
    /// Must be set for the descriptor to be valid
    p: bool = true,
    /// Second part of a pointer to handler code
    offset_high: u48 = 0,
    /// Reserved
    res3: u32 = 0,

    /// Get the offset
    pub fn getOffset(self: Entry) u64 {
        return (@as(u64, self.offset_high) << 16) | self.offset_low;
    }

    /// Set the offset
    pub fn setOffset(self: *Entry, offset: u64) void {
        self.offset_low = @truncate(offset);
        self.offset_high = @truncate(offset >> 16);
    }
};

/// IDT Descriptor
pub const Descriptor = packed struct(u80) {
    /// Size
    /// IDT Byte Length - 1
    size: u16,
    /// Offset
    offset: u64,
};

/// Interrupt Function Type
pub const InterruptFunction = *const fn () noreturn;

/// Global IDT
pub var global_idt: [256]Entry = .{Entry{}} ** 256;
pub var descriptor: Descriptor = .{ .size = @sizeOf(@TypeOf(global_idt)) - 1, .offset = undefined };
pub var got_interrupt: bool = false;

/// Initialize the IDT
pub fn init() void {
    log.info("IDT initialization...", .{});
    // make descriptor point to global idt
    descriptor.offset = @intFromPtr(&global_idt);
    // construct the gdt generically
    inline for (0..255) |i| {
        if (getVector(i)) |vector| {
            // std.log.info("IDT: {d} -> {x}", .{ i, @intFromPtr(vector) });
            switch (Exception.is(i)) {
                true => {
                    // trap
                    global_idt[i] = .{ .gate_type = .trap_64bit };
                    global_idt[i].setOffset(@intFromPtr(vector));
                },
                else => {
                    // normal
                    global_idt[i] = .{ .gate_type = .interrupt_64bit };
                    global_idt[i].setOffset(@intFromPtr(vector));
                },
            }
        } else {
            std.log.info("IDT: {d} -> null", .{i});
            global_idt[i].p = false;
        }
    }
    // load the idt
    asm volatile ("lidt (%[addr])"
        :
        : [addr] "{rax}" (&descriptor),
    );
    // enable interrupts
    asm volatile ("sti");
    log.info("IDT initialization successful! ", .{});
}

/// Generic Interrupt Caller
pub fn getVector(comptime number: u8) ?InterruptFunction {
    return switch (number) {
        inline 15, 22...31 => null,
        else => blk: {
            // normal or trap
            break :blk struct {
                fn vector() noreturn {
                    std.log.debug("Interrupt: {d}", .{number});
                    const is_exception = Exception.is(number);
                    if (is_exception and @as(Exception, @enumFromInt(number)).hasErrorCode()) {
                        asm volatile (
                            \\push %[num]
                            \\jmp interruptCommon
                            :
                            : [num] "{rax}" (@as(u64, number)),
                        );
                    } else {
                        asm volatile (
                            \\push $0
                            \\push %[num]
                            \\jmp interruptCommon
                            :
                            : [num] "{rax}" (@as(u64, number)),
                        );
                    }
                    unreachable;
                }
            }.vector;
        },
    };
}

/// Interrupt Frame
/// Standard values provided here are used for task startup
pub const InterruptFrame = extern struct {
    /// Extra Segment Selector
    es: gdt.Selector = gdt.Selector.null_segment,
    /// Data Segment Selector
    ds: gdt.Selector = gdt.Selector.null_segment,
    /// General purpose register R15
    r15: u64 = 0,
    /// General purpose register R14
    r14: u64 = 0,
    /// General purpose register R13
    r13: u64 = 0,
    /// General purpose register R12
    r12: u64 = 0,
    /// General purpose register R11
    r11: u64 = 0,
    /// General purpose register R10
    r10: u64 = 0,
    /// General purpose register R9
    r9: u64 = 0,
    /// General purpose register R8
    r8: u64 = 0,
    /// Destination index for string operations
    rdi: u64 = 0,
    /// Source index for string operations
    rsi: u64 = 0,
    /// Base Pointer (meant for stack frames)
    rbp: u64 = 0,
    /// Data (commonly extends the A register)
    rdx: u64 = 0,
    /// Counter
    rcx: u64 = 0,
    /// Base
    rbx: u64 = 0,
    /// Accumulator
    rax: u64 = 0,
    /// Interrupt Number
    vector_number: u64 = 0,
    /// Error code
    error_code: u64 = 0,
    /// Instruction Pointer
    rip: u64 = 0,
    /// Code Segment
    cs: gdt.Selector = gdt.Selector.null_segment,
    /// RFLAGS
    rflags: registers.RFLAGS = @bitCast(@as(u64, 0)),
    /// Stack Pointer
    sp: u64,
    /// Stack Segment
    ss: gdt.Selector = gdt.Selector.null_segment,
    // TODO: actually make startup values that make sense
};

/// Common interrupt calling code
/// Should be called after pushing the error code and the interrupt number
export fn interruptCommon() callconv(.naked) void {
    asm volatile (
    // push general-purpose registers
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rbp
        \\push %%rsi
        \\push %%rdi
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        // push segment registers
        \\mov %%ds, %%rax
        \\push %%rax
        \\mov %%es, %%rax
        \\push %%rax
        \\mov %%rsp, %%rdi
        // set segment to run in
        // does not push so we don't need to pop
        \\mov %[kernel_data], %%ax
        \\mov %%ax, %%es
        \\mov %%ax, %%ds
        \\call interruptHandler
        // pop segment registers
        \\pop %%rax
        \\mov %%rax, %%es
        \\pop %%rax
        \\mov %%rax, %%ds
        // pop general-purpose registers
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rbp
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        // pop error code
        \\add $16, %%rsp
        // return
        \\iretq
        :
        : [kernel_data] "i" (gdt.Selector.kernel_data),
    );
}

/// Exceptions
pub const Exception = enum(u8) {
    /// Divide Error
    DE = 0,
    /// Debug Exception
    DB = 1,
    /// Breakpoint
    BP = 3,
    /// Overflow
    OF = 4,
    /// BOUND Range Exceeded
    BR = 5,
    /// Invalid Opcode (Undefined Opcode)
    UD = 6,
    /// Device Not Available (No Math Coprocessor)
    NM = 7,
    /// Double Fault
    DF = 8,
    /// Coprocessor Segment Overrun
    RES = 9,
    /// Invalid TSS
    TS = 10,
    /// Segment Not Present
    NP = 11,
    /// Stack-Segment Fault
    SS = 12,
    /// General Protection
    GP = 13,
    /// Page Fault
    PF = 14,
    /// x87 FPU Floating-Point Error (Math Fault)
    MF = 16,
    /// Alignment Check
    AC = 17,
    /// Machine Check
    MC = 18,
    /// SIMD Floating-Point Exception
    XM = 19,
    /// Virtualization Exception
    VE = 20,
    /// Control Protection Exception
    CP = 21,

    /// Is the given interrupt number an exception?
    pub inline fn is(interrupt: u8) bool {
        return switch (interrupt) {
            0, 1, 3...14, 15...21 => true,
            else => false,
        };
    }

    /// Has the exception an error code?
    pub inline fn hasErrorCode(self: Exception) bool {
        return switch (self) {
            .DF, .TS, .NP, .SS, .GP, .PF, .AC, .CP => true,
            else => false,
        };
    }
};

/// Interrupt Handler
export fn interruptHandler(frame: *InterruptFrame) void {
    log.info("Received interrupt {}", .{frame.vector_number});
    // specific interrupt handling
    switch (frame.vector_number) {
        0, 1, 3...14, 16...21 => {
            log.err("except = {s}", .{@tagName(@as(Exception, @enumFromInt(frame.vector_number)))});
            log.err("num = 0x{x:0>2}   err = 0x{x:0>16}", .{ frame.vector_number, frame.error_code });
            log.err("rax = 0x{x:0>16}   rbx = 0x{x:0>16}   rcx = 0x{x:0>16}   rdx = 0x{x:0>16}", .{
                frame.rax,
                frame.rbx,
                frame.rcx,
                frame.rdx,
            });
            log.err("rip = 0x{x:0>16}   rsp = 0x{x:0>16}   rbp = 0x{x:0>16}", .{ frame.rip, frame.sp, frame.rbp });
            log.err("cr0 = 0x{x:0>16}   cr2 = 0x{x:0>16}   cr3 = 0x{x:0>16}   cr4 = 0x{x:0>16}", .{
                @as(usize, @bitCast(registers.CR0.get())),
                @as(usize, @bitCast(registers.CR2.get())),
                @as(usize, @bitCast(registers.CR3.get())),
                @as(usize, @bitCast(registers.CR4.get())),
            });
            @panic("reached unhandled error");
        },
        else => {
            log.debug("Frame contents: {}", .{frame});
        },
    }
}
