const std = @import("std");
const arch = @import("../arch.zig");
const heap = @import("../memory/heap.zig");
const bootinfo = arch.bootinfo;
const limine = arch.limine;
const paging = arch.paging;

const log = std.log.scoped(.acpi);

export var rsdp_address_request: limine.RSDPRequest linksection(".limine_requests") = .{};

const c = @cImport({
    @cInclude("acpi.h");
});

export fn AcpiOsInitialized() c.ACPI_STATUS {
    return c.AE_OK;
}

export fn AcpiOsTerminate() c.ACPI_STATUS {
    return c.AE_OK;
}

export fn AcpiOsGetRootPointer() c.ACPI_PHYSICAL_ADDRESS {
    if (rsdp_address_request.response) |response| {
        return @intCast(bootinfo.toPhysicalHHDM(response.address));
    } else {
        log.err("Failed to get RSDP address, response was null", .{});
        return 0;
    }
}

// ACPI_STATUS AcpiOsPredefinedOverride(const ACPI_PREDEFINED_NAMES *PredefinedObject, ACPI_STRING *NewValue)
export fn AcpiOsPredefinedOverride(predfined_object: [*c]c.ACPI_PREDEFINED_NAMES, new_value: [*c]c.ACPI_STRING) c.ACPI_STATUS {
    _ = predfined_object;
    new_value.* = null;
    return c.AE_OK;
}

// ACPI_STATUS AcpiOsTableOverride(ACPI_TABLE_HEADER *ExistingTable, ACPI_TABLE_HEADER **NewTable)
export fn AcpiOsTableOverride(existing_table: [*c]c.ACPI_TABLE_HEADER, new_table: [*c][*c]c.ACPI_TABLE_HEADER) c.ACPI_STATUS {
    _ = existing_table;
    new_table.* = null;
    return c.AE_OK;
}

// void *AcpiOsMapMemory(ACPI_PHYSICAL_ADDRESS PhysicalAddress, ACPI_SIZE Length)
export fn AcpiOsMapMemory(physical_address: c.ACPI_PHYSICAL_ADDRESS, length: c.ACPI_SIZE) ?*anyopaque {
    _ = length;
    return @ptrFromInt(bootinfo.toVirtualHHDM(physical_address));
}

// void AcpiOsUnmapMemory(void *where, ACPI_SIZE length)
export fn AcpiOsUnmapMemory(where: ?*anyopaque, length: c.ACPI_SIZE) void {
    _ = where;
    _ = length;
}

// ACPI_STATUS AcpiOsGetPhysicalAddress(void *LogicalAddress, ACPI_PHYSICAL_ADDRESS *PhysicalAddress)
export fn AcpiOsGetPhysicalAddress(logical_address: ?*anyopaque, physical_address: [*c]c.ACPI_PHYSICAL_ADDRESS) c.ACPI_STATUS {
    physical_address.* = bootinfo.toPhysicalHHDM(@intFromPtr(logical_address));
    return c.AE_OK;
}

// void *AcpiOsAllocate(ACPI_SIZE Size);
export fn AcpiOsAllocate(size: c.ACPI_SIZE) ?*anyopaque {
    return heap.malloc(@intCast(size));
}

export fn AcpiOsFree(memory: ?*anyopaque) void {
    heap.free(memory);
}

// BOOLEAN AcpiOsReadable(void *Memory, ACPI_SIZE Length)
export fn AcpiOsReadable(memory: ?*anyopaque, length: c.ACPI_SIZE) bool {
    if (memory == null) return false;

    const page_count = length / paging.PAGE_SIZE;
    const virt = @intFromPtr(memory.?);
    const start_page = std.mem.alignBackward(usize, virt, paging.PAGE_SIZE);

    for (0..page_count) |i| {
        const page = start_page + i * paging.PAGE_SIZE;
        if (!paging.getPageEntry(page).present) return false;
    }

    return true;
}

// BOOLEAN AcpiOsWritable(void *Memory, ACPI_SIZE Length)
export fn AcpiOsWritable(memory: ?*anyopaque, length: c.ACPI_SIZE) bool {
    if (memory == null) return false;

    const page_count = length / paging.PAGE_SIZE;
    const virt = @intFromPtr(memory.?);
    const start_page = std.mem.alignBackward(usize, virt, paging.PAGE_SIZE);

    for (0..page_count) |i| {
        const page = start_page + i * paging.PAGE_SIZE;
        const entry = paging.getPageEntry(page);
        if (!(entry.present and entry.writeable)) return false;
    }

    return true;
}
