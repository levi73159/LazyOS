const gdt = @import("../arch/x86/gdt.zig");
const console = @import("../console.zig");

pub fn init() void {
    invoke(gdt.init, "GDT");
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
    console.writeColor(.light_green, name ++ " initialized\n");
}
