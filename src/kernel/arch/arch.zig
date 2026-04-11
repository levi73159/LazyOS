const builtin = @import("builtin");

pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const isr = @import("isr.zig");
pub const irq = @import("irq.zig");
pub const pic = @import("pic.zig");
pub const pit = @import("pit.zig");
pub const paging = @import("paging.zig");
pub const syscall = @import("syscall.zig");
pub const msr = @import("msr.zig");
pub const io = @import("io.zig");
pub const registers = @import("registers.zig");
pub const CPU = @import("CPU.zig");
pub const bootinfo = @import("bootinfo.zig");
pub const descriptors = @import("descriptors.zig");
pub const limine = @import("limine.zig");
pub const VirtualSpace = @import("VirtualSpace.zig");
