const builtin = @import("builtin");

pub const is_x86_64 = builtin.cpu.arch == .x86_64;

pub const io = @import("arch/io.zig");
pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => struct {
        pub const gdt = @import("arch/x86_64/gdt.zig");
        pub const idt = @import("arch/x86_64/idt.zig");
        pub const isr = @import("arch/x86_64/isr.zig");
    },
    .x86 => struct {
        // pub const gdt = @import("arch/x86/gdt.zig");
        // pub const idt = @import("arch/x86/idt.zig");
        // pub const isr = @import("arch/x86/isr.zig");
    },
    else => @compileError("Unsupported architecture: " ++ @tagName(builtin.cpu.arch)),
};
