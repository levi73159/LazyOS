const builtin = @import("builtin");

pub const io = @import("arch/io.zig");
pub usingnamespace switch (builtin.cpu.arch) {
    .x86 => struct {
        pub const gdt = @import("arch/x86/gdt.zig");
        pub const idt = @import("arch/x86/idt.zig");
        pub const isr = @import("arch/x86/isr.zig");
        pub const registers = @import("arch/x86/registers.zig");
        pub const pic = @import("arch/x86/pic.zig");
        pub const irq = @import("arch/x86/irq.zig");
    },
    else => @compileError("Unsupported architecture: " ++ @tagName(builtin.cpu.arch)),
};
