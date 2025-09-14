const std = @import("std");

const KERNEL_HEAP_SIZE = 4 * 1024 * 1024; // 4 MiB
const PERMANENT_HEAP_SIZE = 1 * 1024 * 1024; // 4 MiB

var kernel_heap: [KERNEL_HEAP_SIZE]u8 linksection(".kernel_heap") = .{0} ** KERNEL_HEAP_SIZE;
var permanent_heap: [PERMANENT_HEAP_SIZE]u8 linksection(".kernel_heap") = .{0} ** PERMANENT_HEAP_SIZE;

var permanent_allocator = std.heap.FixedBufferAllocator.init(&permanent_heap);
var kernel_allocator = std.heap.FixedBufferAllocator.init(&kernel_heap);

pub fn permanentAllocator() std.mem.Allocator {
    return permanent_allocator.allocator();
}

pub fn allocator() std.mem.Allocator {
    return kernel_allocator.allocator();
}
