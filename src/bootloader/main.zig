//! UEFI ELF Bootloader

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2023-2024 Samuel Fiedler

const boot_info = @import("boot_info.zig");
const std = @import("std");

const text_out = @import("./text_out.zig");
const loader = @import("./loader.zig");

const log = std.log.scoped(.main);
const uefi = std.os.uefi;

/// Standard Library Options
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = logFn,
};

// Logging Function
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = comptime switch (level) {
        .debug => "\x1b[32m",
        .info => "\x1b[36m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ color ++ comptime level.asText() ++ "\x1b[0m] " ++ scope_prefix;
    text_out.printf(prefix ++ format ++ "\r\n", args);
}

/// Main bootloader function
/// This function is not in the main function to do some separation and to process the resulting status.
/// I know I could do that also in other ways, but I decided to use one thing for everything here.
fn bootloader() uefi.Status {
    // declare the variables
    const system_table = uefi.system_table;
    const boot_services = system_table.boot_services.?;
    const runtime_services = system_table.runtime_services;
    const kernel_executable_path: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("\\boot\\kernel.elf");
    var status: uefi.Status = .success;
    var root_file_system: *const uefi.protocol.File = undefined;
    var memory_map: [*]uefi.tables.MemoryDescriptor = undefined;
    var memory_map_key: usize = 0;
    var memory_map_size: usize = 0;
    var descriptor_size: usize = undefined;
    var descriptor_version: u32 = undefined;
    var kernel_entry_point: u64 = undefined;
    var kernel_start_address: u64 = undefined;
    var kernel_entry: *const fn () callconv(.C) noreturn = undefined;
    var kernel_boot_info: boot_info.KernelBootInfo = undefined;
    var dwarf_info: ?std.debug.Dwarf = null;
    var file_system: *uefi.protocol.SimpleFileSystem = undefined;
    var video_mode_info: *uefi.protocol.GraphicsOutput.Mode.Info = undefined;
    var video_mode_info_size: usize = undefined;
    var graphics_output: *uefi.protocol.GraphicsOutput = undefined;
    // locate protocols
    log.debug("Locating graphics output protocol", .{});
    status = boot_services.locateProtocol(&uefi.protocol.GraphicsOutput.guid, null, @ptrCast(&graphics_output));
    if (status != .success) {
        log.err("Locating graphics output protocol failed", .{});
        return status;
    }
    log.debug("Querying graphics mode info", .{});
    // check supported resolutions
    var i: u32 = 0;
    log.info("Current graphics mode = {}", .{graphics_output.mode.mode});
    while (i < graphics_output.mode.max_mode) : (i += 1) {
        _ = graphics_output.queryMode(i, &video_mode_info_size, &video_mode_info);
        if (graphics_output.mode.mode == i) {
            log.info("  Resolution and pixel format: {}x{} {s}", .{ video_mode_info.horizontal_resolution, video_mode_info.vertical_resolution, @tagName(video_mode_info.pixel_format) });
        }
    }
    _ = graphics_output.queryMode(graphics_output.mode.mode, &video_mode_info_size, &video_mode_info);
    log.debug("Locating simple file system protocol", .{});
    status = boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&file_system));
    if (status != .success) {
        log.err("Locating simple file system protocol failed", .{});
        return status;
    }
    log.debug("Opening root volume", .{});
    // prepare file system
    status = file_system.openVolume(&root_file_system);
    if (status != .success) {
        log.err("Opening root volume failed", .{});
        return status;
    }
    // get memory map the first time
    // necessary to find free memory for the kernel
    log.debug("Getting memory map to find free addresses", .{});
    while (boot_services.getMemoryMap(&memory_map_size, memory_map, &memory_map_key, &descriptor_size, &descriptor_version) == .buffer_too_small) {
        status = boot_services.allocatePool(.boot_services_data, memory_map_size, @ptrCast(@alignCast(&memory_map)));
        if (status != .success) {
            log.err("Getting memory map failed", .{});
            return status;
        }
    }
    // find free address
    log.debug("Finding free kernel base address", .{});
    var mem_index: usize = 0;
    var mem_count: usize = undefined;
    var mem_point: *uefi.tables.MemoryDescriptor = undefined;
    var base_address: u64 = 0x100000;
    var num_pages: usize = 0;
    mem_count = memory_map_size / descriptor_size;
    log.debug("mem_count is {}", .{mem_count});
    while (mem_index < mem_count) : (mem_index += 1) {
        log.debug("mem_index is {}", .{mem_index});
        mem_point = @ptrFromInt(@intFromPtr(memory_map) + (mem_index * descriptor_size));
        if (mem_point.type == .conventional_memory and mem_point.physical_start >= base_address) {
            base_address = mem_point.physical_start;
            num_pages = mem_point.number_of_pages;
            log.debug("Found {} free pages at 0x{x}", .{ num_pages, base_address });
            break;
        }
    }
    // load kernel image
    log.info("Loading kernel image", .{});
    status = loader.loadKernelImage(
        root_file_system,
        kernel_executable_path,
        base_address,
        &kernel_entry_point,
        &kernel_start_address,
        &dwarf_info,
    );
    if (status != .success) {
        log.err("Loading kernel image failed", .{});
        return status;
    }
    log.debug("Kernel Entry Point is: '0x{x:0>16}'", .{kernel_entry_point});
    log.debug("Kernel Start Address is: '0x{x:0>16}'", .{kernel_start_address});
    // find RSDP
    for (0..system_table.number_of_table_entries) |index| {
        const entry = system_table.configuration_table[index];
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid)) {
            kernel_boot_info.rsdp_10 = entry.vendor_table;
        }
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            kernel_boot_info.rsdp_20 = entry.vendor_table;
        }
    }
    // set kernel boot info
    kernel_boot_info.video_mode_info.framebuffer_pointer = @as([*]volatile u32, @ptrFromInt(graphics_output.mode.frame_buffer_base));
    kernel_boot_info.video_mode_info.horizontal_resolution = video_mode_info.horizontal_resolution;
    kernel_boot_info.video_mode_info.vertical_resolution = video_mode_info.vertical_resolution;
    kernel_boot_info.video_mode_info.pixels_per_scanline = video_mode_info.pixels_per_scan_line;
    kernel_boot_info.video_mode_info.pixel_format = @intFromEnum(video_mode_info.pixel_format);
    kernel_boot_info.dwarf_info = &dwarf_info;
    log.debug("Disabling watchdog timer", .{});
    status = boot_services.setWatchdogTimer(0, 0, 0, null);
    if (status != .success) {
        log.err("Disabling watchdog timer failed", .{});
        return status;
    }
    // get memory map to exit boot services
    status = .no_response;
    while (status != .success) {
        log.info("Getting memory map and trying to exit boot services", .{});
        while (boot_services.getMemoryMap(&memory_map_size, memory_map, &memory_map_key, &descriptor_size, &descriptor_version) == .buffer_too_small) {
            status = boot_services.allocatePool(.boot_services_data, memory_map_size, @ptrCast(@alignCast(&memory_map)));
            if (status != .success) {
                log.err("Getting memory map failed", .{});
                return status;
            }
        }
        status = boot_services.exitBootServices(uefi.handle, memory_map_key);
    }
    // set value at base address of kernel (kernel_boot_info) to a ptr to kernel_boot_info
    const boot_info_ptr: *usize = @ptrFromInt(base_address);
    boot_info_ptr.* = @intFromPtr(&kernel_boot_info);
    // prepare memory map for virtual memory
    mem_index = 0;
    mem_count = memory_map_size / descriptor_size;
    while (mem_index < mem_count) : (mem_index += 1) {
        mem_point = @ptrFromInt(@intFromPtr(memory_map) + (mem_index * descriptor_size));
        if (mem_point.type == .loader_data) {
            mem_point.virtual_start = kernel_start_address;
            // and make kernel phys start available to kernel
            kernel_boot_info.kernel_phys_start = mem_point.physical_start;
        } else {
            mem_point.virtual_start = mem_point.physical_start;
        }
    }
    status = runtime_services.setVirtualAddressMap(memory_map_size, descriptor_size, descriptor_version, memory_map);
    if (status != .success) {
        return .load_error;
    }
    // make memory map available to kernel params
    kernel_boot_info.memory_map = memory_map;
    kernel_boot_info.memory_map_size = memory_map_size;
    kernel_boot_info.memory_map_descriptor_size = descriptor_size;
    kernel_boot_info.runtime_services = runtime_services;
    // jump into kernel
    kernel_entry = @ptrFromInt(kernel_entry_point);
    kernel_entry();
    return .load_error;
}

/// Wrapper to call bootloader function
/// If nothing went wrong, it should not get after `status = bootloader()` because kernel should be started...
pub fn main() void {
    var status: uefi.Status = .success;
    status = bootloader();
    log.info("Status: {s}", .{@tagName(status)});
    while (true) {}
}
