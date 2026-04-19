const std = @import("std");

pub fn VTable(comptime Item: type, comptime Ctx: type) type {
    return struct {
        next: *const fn (ctx: *Ctx) anyerror!?*const Item,
        reset: *const fn (ctx: *Ctx) void,
    };
}

pub fn Iterator(comptime Item: type, comptime Ctx: type, comptime vtabe: VTable(Item, Ctx)) type {
    return struct {
        const Self = @This();

        ctx: Ctx,

        pub fn next(self: *Self) !?*const Item {
            return vtabe.next(&self.ctx);
        }

        pub fn reset(self: *Self) void {
            vtabe.reset(&self.ctx);
        }
    };
}
