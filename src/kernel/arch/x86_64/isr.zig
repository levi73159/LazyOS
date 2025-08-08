const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const log = @import("std").log.scoped(.isr);
const registers = @import("registers.zig");

pub const InterruptFn = *const fn () callconv(.naked) noreturn;

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

    pub inline fn is(number: u8) bool {
        if (number <= 21) {
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
            => true,
            else => false,
        };
    }

    pub inline fn hasErrorNumber(num: u8) bool {
        if (!is(num)) return false;
        return hasErrorCode(@enumFromInt(num));
    }
};

pub fn init() void {
    log.debug("Initializing ISRs", .{});

    const int0 = getVector(0);
    idt.setGate(0, @intFromPtr(int0), gdt.Selector.kernel_code, .{ .gate_type = .interrupt_64bit });
    idt.enableGate(0);

    asm volatile ("sti");
    log.debug("ISRs initialized", .{});
}

pub fn getVector(comptime number: u8) ?InterruptFn {
    return switch (number) {
        15, 22...31 => null,
        else => struct {
            fn handler() callconv(.naked) noreturn {
                if (Exception.hasErrorNumber(number)) {
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
            }
        }.handler,
    };
}

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

export fn interruptHandler(frame: *InterruptFrame) void {
    log.debug("Interrupt {d}", .{frame.vector_number});
}
