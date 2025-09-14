pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const isr = @import("isr.zig");
pub const registers = @import("registers.zig");
pub const pic = @import("pic.zig");
pub const irq = @import("irq.zig");
pub const Multiboot = @import("multiboot.zig");
pub const MultibootInfo = Multiboot.MultibootInfo;
pub const CPU = @import("CPU.zig");

pub const paging = @import("paging.zig");
