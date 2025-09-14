const std = @import("std");

pub const InterruptFrame = packed struct {
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    useless: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,

    interrupt_number: u32,
    error_code: u32,

    // pushed by the processor
    eip: u32,
    cs: u32,
    eflags: u32,
    esp: u32,
    ss: u32,

    pub fn format(
        self: InterruptFrame,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("   eax={x}   ebx={x}   ecx={x}   edx={x}   esi={x}   edi={x}\n", .{
            self.eax,
            self.ebx,
            self.ecx,
            self.edx,
            self.esi,
            self.edi,
        });

        try writer.print("   ebp={x}   esp={x}   eip={x}   eflags={x}\n", .{
            self.ebp,
            self.esp,
            self.eip,
            self.eflags,
        });

        try writer.print("   cs={x}   ds={x}\n", .{
            self.cs,
            self.ds,
        });

        try writer.print("   error={x}   interrupt={x}", .{ self.error_code, self.interrupt_number });
    }
};
