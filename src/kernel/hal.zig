const std = @import("std");
const arch = @import("arch.zig");
const gdt = arch.gdt;
const idt = arch.idt;
const isr = arch.isr;
const irq = arch.irq;

const console = @import("console.zig");

const log = std.log.scoped(.hal);

pub fn init() void {
    log.debug("Initializing HAL", .{});
    invoke(gdt.init, "GDT");
    invoke(idt.init, "IDT");
    invoke(isr.init, "ISR");
    invoke(irq.init, "IRQ");
}

// function invoker wrapper
// turns to this
// invoke(gdt.init, "GDT");
// into
// if func can return error
//      gdt.init() catch panic("Failed to initialize GDT");
//      console.writeColor(.light_green, "GDT initialized\n");
// else
//      gdt.init();
//      console.writeColor(.light_green, "GDT initialized\n");
inline fn invoke(comptime func: anytype, comptime name: []const u8) void {
    // check if func return error
    if (@typeInfo(@TypeOf(func)) != .@"fn") {
        @compileError("func must be a function");
    }

    const FN = @typeInfo(@TypeOf(func)).@"fn";
    const Ret = FN.return_type.?;

    if (@typeInfo(Ret) == .error_union) {
        func() catch
            @panic("Failed to initialize " ++ name);
    } else {
        func();
    }
    log.info("HAL " ++ name ++ " initialized", .{});
}
