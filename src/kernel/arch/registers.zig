const std = @import("std");

// 64 bit register frame
pub const InterruptFrame = extern struct {
    ds: u64 = 0,
    rbp: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    rax: u64 = 0,

    interrupt_number: u64 = 0,
    error_code: u64 = 0,

    // pushed by the processor
    rip: u64 = 0, // +8 bytes
    cs: u64 = 0, // +8 bytes
    rflags: u64 = 0, // +8 bytes
    rsp: u64 = 0, // +8 bytes
    ss: u64 = 0, // +8 bytes
    // = 40 bytes total

    // general purpose registers

    pub fn format(
        self: InterruptFrame,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("   rax={x}   rbx={x}   rcx={x}   rdx={x}   rsi={x}   rdi={x}\n", .{
            self.rax,
            self.rbx,
            self.rcx,
            self.rdx,
            self.rsi,
            self.rdi,
        });

        try writer.print("   r8={x}   r9={x}   r10={x}   r11={x}\n   r12={x}   r13={x}   r14={x}   r15={x}\n", .{
            self.r8,
            self.r9,
            self.r10,
            self.r11,
            self.r12,
            self.r13,
            self.r14,
            self.r15,
        });

        try writer.print("   rbp={x}   rsp={x}   rip={x}   rflags={x}\n", .{
            self.rbp,
            self.rsp,
            self.rip,
            self.rflags,
        });

        try writer.print("   cs={x}   ds={x}   ss={x}\n", .{
            self.cs,
            self.ds,
            self.ss,
        });

        try writer.print("   error={x}   interrupt={x}", .{ self.error_code, self.interrupt_number });
        try writer.print("   rsp % 16 = {x}", .{self.rsp & 0xf});
    }
};
