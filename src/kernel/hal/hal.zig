const std = @import("std");
const arch = @import("../arch/arch.zig");
const gdt = arch.gdt;
const idt = arch.idt;
const isr = arch.isr;

const console = @import("../console.zig");

const log = std.log.scoped(.hal);

pub fn init() void {
    invoke(gdt.init, "GDT");
    invoke(isr.init, "ISRs");
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
            console.panic("Failed to initialize " ++ name);
    } else {
        func();
    }
    log.info("HAL " ++ name ++ " initialized", .{});
}
