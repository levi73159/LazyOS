const builtin = @import("builtin");
pub const page_allocator = @import("page_allocator.zig").allocator;
pub const LinkedList = @import("LinkedList.zig");

var heap: LinkedList = undefined;
var has_initialized = false;

pub fn init() void {
    heap = LinkedList.init();
    has_initialized = true;
}

pub fn allocator() @import("std").mem.Allocator {
    if (builtin.mode == .Debug and !has_initialized) @panic("heap not initialized");
    return heap.allocator();
}

pub fn get() *LinkedList {
    if (builtin.mode == .Debug and !has_initialized) @panic("heap not initialized");
    return &heap;
}

// C Abi wrappers
pub export fn malloc(size: usize) ?*anyopaque {
    return heap.allocate(size, .@"16") catch null;
}

pub export fn free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    heap.free(@ptrCast(ptr));
}
