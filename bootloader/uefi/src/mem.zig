const std = @import("std");
const BootInfo = @import("BootInfo.zig");
const uefi = std.os.uefi;

pub fn getMemoryMap(bootinfo: *BootInfo) !uefi.tables.MemoryMapSlice {
    _ = bootinfo; // autofix
    const log = std.log.scoped(.mmap);
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
