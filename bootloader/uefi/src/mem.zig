const std = @import("std");
const BootInfo = @import("BootInfo.zig");
const uefi = std.os.uefi;
const builtin = @import("builtin");

pub const ARCH_PAGE_SIZE = 4096;

const log = std.log.scoped(.memory);

pub inline fn kb(size_in_bytes: comptime_int) comptime_int {
    return size_in_bytes * 1024;
}

pub inline fn mb(size_in_bytes: comptime_int) comptime_int {
    return kb(size_in_bytes) * 1024;
}

pub fn getMemoryMap(bootinfo: *BootInfo) !uefi.tables.MemoryMapSlice {
    _ = bootinfo; // autofix
    const boot_services = uefi.system_table.boot_services.?;
    const info = try boot_services.getMemoryMapInfo();
    const raw_buffer = try boot_services.allocatePool(.loader_data, info.len * info.descriptor_size);
    const buffer: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = @alignCast(raw_buffer);

    const map = try boot_services.getMemoryMap(buffer);

    log.debug("Descriptor size: expected={d}, actual={d}", .{ @sizeOf(uefi.tables.MemoryDescriptor), info.descriptor_size });
    log.debug("Memory map size: {d}", .{info.len});
    log.debug("Descriptor size: {d}", .{info.descriptor_size});
    log.debug("Total size: {d}", .{info.len * info.descriptor_size});

    var it = map.iterator();
    while (it.next()) |desc| {
        const end = desc.physical_start + (desc.number_of_pages * 4096);
        log.debug("- Type={s}; {x} -> {x} (size: {x} pages): attr={x}", .{ @tagName(desc.type), desc.physical_start, end, desc.number_of_pages, @as(u64, @bitCast(desc.attribute)) });
    }

    return map;
}

pub fn pagesToBytes(pages: []align(4096) uefi.Page) []u8 {
    const ptr: [*]u8 = @ptrCast(pages.ptr);
    const buf: []u8 = ptr[0 .. pages.len * 4096];
    return buf;
}

// Asserts that buf.len is a multiple of 4096 (so that it can be converted to a slice of pages)
pub fn bytesToPages(buf: []u8) []align(4096) uefi.Page {
    std.debug.assert(buf.len % 4096 == 0);
    const ptr: [*]align(4096) uefi.Page = @ptrCast(@alignCast(buf.ptr));
    return ptr[0..@divExact(buf.len, 4096)];
}

const AllocateError = uefi.tables.BootServices.AllocatePagesError;

fn allocatePagesTest(num_pages: u32) AllocateError![]align(ARCH_PAGE_SIZE) u8 {
    if (!builtin.is_test) @compileError("allocatePagesTest can only be used in tests");

    const pages_slice_raw = std.testing.allocator.alignedAlloc([ARCH_PAGE_SIZE]u8, .fromByteUnits(ARCH_PAGE_SIZE), num_pages) catch @panic("OOM");
    const pages_ptr: [*]align(ARCH_PAGE_SIZE) u8 = @ptrCast(pages_slice_raw);
    const pages = pages_ptr[0 .. num_pages * ARCH_PAGE_SIZE];
    @memset(pages, 0);
    return pages;
}

pub fn allocatePages(num_pages: u32) AllocateError![]align(ARCH_PAGE_SIZE) u8 {
    log.debug("Allocating {d} pages", .{num_pages});
    if (builtin.is_test) return allocatePagesTest(num_pages); // TEST

    const pages_ptr: [*]align(ARCH_PAGE_SIZE) u8 =
        @ptrCast(try uefi.system_table.boot_services.?.allocatePages(.any, .loader_data, num_pages));
    const pages = pages_ptr[0 .. num_pages * ARCH_PAGE_SIZE];
    @memset(pages, 0);
    return pages;
}

fn freePagesTest(memory: []align(ARCH_PAGE_SIZE) u8) void {
    if (!builtin.is_test) @compileError("freePagesTest can only be used in tests");
    std.testing.allocator.free(bytesToPages(memory));
}

pub fn freePages(memory: []align(ARCH_PAGE_SIZE) u8) void {
    if (builtin.is_test) return freePagesTest(memory);
    uefi.system_table.boot_services.?.freePages(bytesToPages(memory)) catch @panic("Unexpected: failed to free pages");
}
