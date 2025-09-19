const std = @import("std");
const builtin = @import("builtin");

const int = switch (builtin.cpu.arch) {
    .x86 => u32,
    .x86_64 => u64,
    else => unreachable,
};

pub const InterruptFrame32 = @import("x86/registers.zig").InterruptFrame32;
pub const InterruptFrame64 = @import("x86_64/registers.zig").InterruptFrame64;
pub const ArchFrame = if (builtin.cpu.arch == .x86) InterruptFrame32 else InterruptFrame64;

pub const InterruptFrame = struct {
    data_segment: int,
    dest_index: int,
    source_index: int,
    stack_base: int,
    useless: int,
    base: int,
    data: int,
    counter: int,
    accumulator: int,

    general_purpose: [8]int, // only be use if the arch have more registers

    interrupt_number: int,
    error_code: int,

    // pushed by the processor
    instruction_pointer: int,
    code_segment: int,
    flags: int,
    stack_pointer: int,
    stack_segment: int,

    pub fn to32(self: InterruptFrame) InterruptFrame32 {
        return .{
            .ds = self.data_segment,
            .edi = self.dest_index,
            .esi = self.source_index,
            .ebp = self.stack_base,
            .useless = self.useless,
            .ebx = self.base,
            .edx = self.data,
            .ecx = self.counter,
            .eax = self.accumulator,
            .interrupt_number = self.interrupt_number,
            .error_code = self.error_code,
            .eip = self.instruction_pointer,
            .cs = self.code_segment,
            .eflags = self.flags,
            .esp = self.stack_pointer,
            .ss = self.stack_segment,
        };
    }

    pub fn to64(self: InterruptFrame) InterruptFrame64 {
        return .{
            .ds = self.data_segment,
            .rdi = self.dest_index,
            .rsi = self.source_index,
            .rbp = self.stack_base,
            .usless = self.useless,
            .r8 = self.general_purpose[0],
            .r9 = self.general_purpose[1],
            .r10 = self.general_purpose[2],
            .r11 = self.general_purpose[3],
            .r12 = self.general_purpose[4],
            .r13 = self.general_purpose[5],
            .r14 = self.general_purpose[6],
            .r15 = self.general_purpose[7],
            .rbx = self.base,
            .rdx = self.data,
            .rcx = self.counter,
            .rax = self.accumulator,
            .interrupt_number = self.interrupt_number,
            .error_code = self.error_code,
            .rip = self.instruction_pointer,
            .cs = self.code_segment,
            .rflags = self.flags,
            .rsp = self.stack_pointer,
            .ss = self.stack_segment,
        };
    }

    pub fn toArchFrame(self: InterruptFrame) ArchFrame {
        return switch (builtin.cpu.arch) {
            .x86 => self.to32(),
            .x86_64 => self.to64(),
            else => @compileError("Unsupported architecture"),
        };
    }

    pub fn fromArchFrame(frame: *const ArchFrame) InterruptFrame {
        return switch (ArchFrame) {
            InterruptFrame32 => {
                const f: *const InterruptFrame32 = frame;
                return InterruptFrame{
                    .data_segment = f.ds,
                    .dest_index = f.edi,
                    .source_index = f.esi,
                    .stack_base = f.ebp,
                    .useless = f.useless,
                    .base = f.ebx,
                    .data = f.edx,
                    .counter = f.ecx,
                    .accumulator = f.eax,
                    .interrupt_number = f.interrupt_number,
                    .error_code = f.error_code,
                    .instruction_pointer = f.eip,
                    .code_segment = f.cs,
                    .flags = f.eflags,
                    .stack_pointer = f.esp,
                    .stack_segment = f.ss,
                    .general_purpose = .{0} ** 8,
                };
            },
            InterruptFrame64 => {
                const f: *const InterruptFrame64 = frame;
                return InterruptFrame{
                    .data_segment = f.ds,
                    .dest_index = f.rdi,
                    .source_index = f.rsi,
                    .stack_base = f.rbp,
                    .useless = 0,
                    .base = f.rbx,
                    .data = f.rdx,
                    .counter = f.rcx,
                    .accumulator = f.rax,
                    .interrupt_number = f.interrupt_number,
                    .error_code = f.error_code,
                    .instruction_pointer = f.rip,
                    .code_segment = f.cs,
                    .flags = f.rflags,
                    .stack_pointer = f.rsp,
                    .stack_segment = f.ss,
                    .general_purpose = .{ f.r8, f.r9, f.r10, f.r11, f.r12, f.r13, f.r14, f.r15 },
                };
            },
            else => unreachable,
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}", .{self.toArchFrame()});
    }
};
