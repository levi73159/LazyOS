const builtin = @import("builtin");

pub const io = @import("arch/io.zig");

const root = switch (builtin.cpu.arch) {
    .x86 => @import("arch/x86/root.zig"),
    else => @compileError("Unsupported architecture: " ++ @tagName(builtin.cpu.arch)),
};

pub const gdt = root.gdt;
pub const idt = root.idt;
pub const isr = root.isr;
pub const registers = root.registers;
pub const pic = root.pic;
pub const irq = root.irq;
pub const Multiboot = root.Multiboot;
pub const MultibootInfo = Multiboot.MultibootInfo;
pub const CPU = root.CPU;
pub const paging = root.paging;
