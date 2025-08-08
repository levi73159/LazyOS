const builtin = @import("builtin");

pub const is_x86_64 = builtin.cpu.arch == .x86_64;

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => struct {
        pub const io = @import("x86_64/io.zig");
        pub const gdt = @import("x86_64/gdt.zig");
        pub const idt = @import("x86_64/idt.zig");
        pub const isr = @import("x86_64/isr.zig");
    },
    else => @compileError("Unsupported architecture: " ++ @tagName(builtin.cpu.arch)),
};
