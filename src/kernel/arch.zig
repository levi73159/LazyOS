const builtin = @import("builtin");

pub const io = @import("arch/io.zig");
pub const Multiboot = @import("arch/multiboot.zig");
pub const MultibootInfo = Multiboot.MultibootInfo;

pub const pic = @import("arch/pic.zig");
pub const isr = @import("arch/isr.zig");
pub const descriptors = @import("arch/descriptors.zig");
pub const irq = @import("arch/irq.zig");
pub const CPU = @import("arch/CPU.zig");
pub const registers = @import("arch/registers.zig");
