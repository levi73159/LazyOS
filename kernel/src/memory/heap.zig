const std = @import("std");
const builtin = @import("builtin");
pub const LinkedList = @import("LinkedList.zig");
const pmem = @import("pmem.zig");

pub const PAGE_SIZE = 0x1000;

var heap: LinkedList = undefined; // used for kernel
var acpi_heap: LinkedList = undefined; // strictly use for ACPI purposes (small)

var has_initialized = false;

pub fn init() void {
    heap = LinkedList.init(pmem.kernel());
    acpi_heap = LinkedList.init(pmem.acpi());
    has_initialized = true;
}

// NOTE: to be called when vmem done updating
pub fn addRegions() void {
    heap.updateRegions(heap.allocator(), "Kernel");
    acpi_heap.updateRegions(heap.allocator(), "Acpi");
}

pub fn allocator() @import("std").mem.Allocator {
    if (builtin.mode == .Debug and !has_initialized) @panic("heap not initialized");
    return heap.allocator();
}

pub fn allocatorIfReady() ?@import("std").mem.Allocator {
    if (!has_initialized) return null;
    return heap.allocator();
}

pub fn get() *LinkedList {
    if (builtin.mode == .Debug and !has_initialized) @panic("heap not initialized");
    return &heap;
}

pub fn get_acpi() *LinkedList {
    if (builtin.mode == .Debug and !has_initialized) @panic("heap not initialized");
    return &acpi_heap;
}

pub fn acpi_allocator() @import("std").mem.Allocator {
    if (builtin.mode == .Debug and !has_initialized) @panic("heap not initialized");
    return acpi_heap.allocator();
}

// C Abi wrappers
pub export fn malloc(self: *LinkedList, size: usize) ?*anyopaque {
    const memory = self.allocate(size, .@"16") catch null;
    return memory;
}

pub export fn free(self: *LinkedList, ptr: ?*anyopaque) void {
    if (ptr == null) return;
    self.free(@ptrCast(ptr));
}
