//! Core image loading functionality

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2023-2024 Samuel Fiedler

const std = @import("std");
const efi_additional = @import("./efi_additional.zig");

const elf = std.elf;
const log = std.log.scoped(.loader);
const uefi = std.os.uefi;

/// Read a UEFI file
pub fn readFile(file: *const uefi.protocol.File, position: u64, size: *usize, buffer: *[*]align(8) u8) uefi.Status {
    var status: uefi.Status = .success;
    // reset file position
    status = file.setPosition(position);
    if (status != .success) {
        log.err("Setting file position failed", .{});
        return status;
    }
    // read (and directly return error status)
    return file.read(size, buffer.*);
}

/// Read a UEFI file and allocate free memory for it
pub fn readAndAllocate(file: *const uefi.protocol.File, position: u64, size: usize, buffer: *[*]align(8) u8) uefi.Status {
    const boot_services = uefi.system_table.boot_services.?;
    var status: uefi.Status = .success;
    // allocate memory
    status = boot_services.allocatePool(uefi.tables.MemoryType.loader_data, size, buffer);
    if (status != .success) {
        log.err("Allocating space for file failed", .{});
        return status;
    }
    // TODO: probably improve this?
    var size_bulk: usize = size;
    // read (and directly return error status)
    return readFile(file, position, &size_bulk, buffer);
}

/// Load an ELF program segment
pub fn loadSegment(
    file: *const uefi.protocol.File,
    segment_file_offset: u64,
    segment_file_size: usize,
    segment_memory_size: usize,
    segment_virtual_address: u64,
) uefi.Status {
    // set some variables
    var status: uefi.Status = .success;
    if (segment_virtual_address & 4095 != 0) {
        log.warn("segment_virtual_address is not well aligned, returning with success", .{});
        return status;
    }
    var segment_buffer: [*]align(4096) u8 = @ptrFromInt(segment_virtual_address);
    const segment_page_count = efi_additional.efiSizeToPages(segment_memory_size);
    var zero_fill_start: u64 = 0;
    var zero_fill_count: usize = 0;
    const boot_services = uefi.system_table.boot_services.?;
    // allocate pages at right physical address
    log.debug("Allocating {} pages at address '0x{x}'", .{ segment_page_count, segment_virtual_address });
    status = boot_services.allocatePages(
        .allocate_address,
        .loader_data,
        segment_page_count,
        &segment_buffer,
    );
    if (status != .success) {
        log.err("Allocating pages for ELF segment failed", .{});
        return status;
    }
    // read ELF segment data from file
    if (segment_file_size > 0) {
        log.debug("Reading segment data with file size '0x{x}'", .{segment_file_size});
        // needed bc of non-const pointer to size in readFile
        var bulk_segment_sz = segment_file_size;
        status = readFile(file, segment_file_offset, &bulk_segment_sz, @ptrCast(&segment_buffer));
        if (status != .success) {
            log.err("Reading segment data failed", .{});
            return status;
        }
    }
    // zero-fill free bytes, according to the ELF spec
    zero_fill_start = segment_virtual_address + segment_file_size;
    zero_fill_count = segment_memory_size - segment_file_size;
    if (zero_fill_count > 0) {
        log.debug("Zero-filling {} bytes at address '0x{x}'", .{ zero_fill_count, zero_fill_start });
        boot_services.setMem(@ptrFromInt(zero_fill_start), zero_fill_count, 0);
    }
    return status;
}

/// Get contents of an ELF section
pub fn getSectionContents(file: *const uefi.protocol.File, section_header: elf.Elf64_Shdr, buffer: *[]align(8) u8) uefi.Status {
    var buf: [*]align(8) u8 = undefined;
    const status = readAndAllocate(file, section_header.sh_offset, section_header.sh_size, &buf);
    buffer.* = buf[0..section_header.sh_size];
    return status;
}

/// Get the name of an ELF section
pub fn getSectionName(string_table: []const u8, section_header: elf.Elf64_Shdr) ?[]const u8 {
    const len = std.mem.indexOf(u8, string_table[section_header.sh_name..], "\x00") orelse return null;
    return string_table[section_header.sh_name..][0..len];
}

/// Load all ELF program segments
pub fn loadProgramSegments(
    file: *const uefi.protocol.File,
    header: *elf.Header,
    program_headers: [*]const elf.Elf64_Phdr,
    section_headers: [*]const elf.Elf64_Shdr,
    base_physical_address: u64,
    kernel_start_address: *u64,
    dwarf_info: *?std.debug.Dwarf,
) uefi.Status {
    // set variables
    var status: uefi.Status = .success;
    var n_segments_loaded: u64 = 0;
    var set_start_address: bool = true;
    var base_address_difference: u64 = 0;
    // ensure program segments can be loaded
    if (header.phnum == 0) {
        log.err("No program segments to load", .{});
        return .invalid_parameter;
    }
    log.debug("Loading {} segments", .{header.phnum});
    // iterate over all program segments to load sections for program
    for (program_headers[0..header.phnum], 0..) |phdr, index| {
        if (phdr.p_type == elf.PT_LOAD) {
            log.debug("Loading program segment {}", .{index});
            // set kernel start address (but only one time)
            if (set_start_address) {
                set_start_address = false;
                kernel_start_address.* = program_headers[index].p_vaddr;
                base_address_difference = program_headers[index].p_vaddr - base_physical_address;
                log.debug("Set kernel start address to 0x{x} and base address difference to 0x{x}", .{ kernel_start_address.*, base_address_difference });
            }
            // the actual loading logic is in a dedicated function
            status = loadSegment(
                file,
                phdr.p_offset,
                phdr.p_filesz,
                phdr.p_memsz,
                phdr.p_vaddr - base_address_difference,
            );
            if (status != .success) {
                log.err("Loading program segment {} failed", .{index});
                return status;
            }
            n_segments_loaded += 1;
        }
    }
    if (n_segments_loaded == 0) {
        log.err("No loadable program segments found in executable", .{});
        return .not_found;
    }
    log.debug("Loading  DWARF debug info sections", .{});
    var section_string_table: []align(8) u8 = &.{};
    // not just "debug_info" but general debug information (so abbrev etc. too)
    var found_debug_info: bool = false;
    var sections = std.debug.Dwarf.null_section_array;
    status = getSectionContents(file, section_headers[header.shstrndx], &section_string_table);
    log.debug("Section string table length is '{}'", .{section_string_table.len});
    // iterate over sections to find debug sections and load them to open dwarf info
    for (section_headers[0..header.shnum]) |shdr| {
        const section_name = getSectionName(section_string_table, shdr) orelse continue;
        log.debug("section name is {s}", .{section_name});
        if (std.mem.eql(u8, section_name, ".debug_info")) {
            var buf: []align(8) u8 = &.{};
            log.debug("found .debug_info!", .{});
            found_debug_info = true;
            status = getSectionContents(file, shdr, &buf);
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)] = .{
                .data = buf,
                .owned = false,
            };
        }
        if (std.mem.eql(u8, section_name, ".debug_abbrev")) {
            var buf: []align(8) u8 = &.{};
            log.debug("found .debug_abbrev!", .{});
            found_debug_info = true;
            status = getSectionContents(file, shdr, &buf);
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)] = .{
                .data = buf,
                .owned = false,
            };
        }
        if (std.mem.eql(u8, section_name, ".debug_line")) {
            var buf: []align(8) u8 = &.{};
            log.debug("found .debug_line!", .{});
            found_debug_info = true;
            status = getSectionContents(file, shdr, &buf);
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_line)] = .{
                .data = buf,
                .owned = false,
            };
        }
        if (std.mem.eql(u8, section_name, ".debug_str")) {
            var buf: []align(8) u8 = &.{};
            log.debug("found .debug_str!", .{});
            found_debug_info = true;
            status = getSectionContents(file, shdr, &buf);
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_str)] = .{
                .data = buf,
                .owned = false,
            };
        }
        if (std.mem.eql(u8, section_name, ".debug_ranges")) {
            var buf: []align(8) u8 = &.{};
            log.debug("found .debug_ranges!", .{});
            found_debug_info = true;
            status = getSectionContents(file, shdr, &buf);
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_ranges)] = .{
                .data = buf,
                .owned = false,
            };
        }
    }
    if (found_debug_info) {
        dwarf_info.* = std.debug.Dwarf{
            .sections = sections,
            .is_macho = false,
            .endian = .little,
        };
        dwarf_info.*.?.open(uefi.pool_allocator) catch |err| {
            log.err("Error occurred during opening debug info: {s}", .{@errorName(err)});
            dwarf_info.* = null;
            return .load_error;
        };
    } else {
        dwarf_info.* = null;
    }
    return status;
}

/// Load the kernel image
pub fn loadKernelImage(
    /// Pointer pointing to the root file system
    root_file_system: *const uefi.protocol.File,
    /// UEFI (16-bit) string with the file name of the kernel
    kernel_image_filename: [*:0]const u16,
    /// Physical base address to load the bootloader
    base_physical_address: u64,
    /// Pointer to the "kernel_entry_point" variable to be set
    kernel_entry_point: *u64,
    /// Pointer to the "kernel_start_address" variable for virtual memory mapping
    kernel_start_address: *u64,
    /// Pointer to the "dwarf_info" variable for kernel debug information processing inside the bootloader
    dwarf_info: *?std.debug.Dwarf,
) uefi.Status {
    // set variables
    const boot_services = uefi.system_table.boot_services.?;
    var status: uefi.Status = .success;
    var kernel_img_file: *const uefi.protocol.File = undefined;
    var header_buffer: [*]align(8) u8 = undefined;
    log.debug("Opening kernel image", .{});
    // open the kernel image file
    status = root_file_system.open(
        &kernel_img_file,
        kernel_image_filename,
        uefi.protocol.File.efi_file_mode_read,
        uefi.protocol.File.efi_file_read_only,
    );
    defer _ = kernel_img_file.close();
    if (status != .success) {
        log.err("Opening kernel file failed", .{});
        return status;
    }
    // check elf identity
    log.debug("Checking ELF identity", .{});
    // read elf header (but only identity bytes)
    status = readAndAllocate(kernel_img_file, 0, elf.EI_NIDENT, &header_buffer);
    if (status != .success) {
        log.err("Reading ELF identity failed", .{});
        return status;
    }
    // check elf magic
    if ((header_buffer[0] != 0x7f) or (header_buffer[1] != 0x45) or (header_buffer[2] != 0x4c) or (header_buffer[3] != 0x46)) {
        log.err("Invalid ELF magic", .{});
        return .invalid_parameter;
    }
    // only load 64bit binaries
    if (header_buffer[elf.EI_CLASS] != elf.ELFCLASS64) {
        log.err("Can only load 64-bit binaries", .{});
        return .unsupported;
    }
    // only load little-endian binaries
    if (header_buffer[elf.EI_DATA] != elf.ELFDATA2LSB) {
        log.err("Can only load little-endian binaries", .{});
        return .incompatible_version;
    }
    // free elf header buffer
    status = boot_services.freePool(header_buffer);
    if (status != .success) {
        log.err("Freeing ELF identity buffer failed", .{});
        return status;
    }
    log.debug("ELF identity is good; continuing loading", .{});
    // load ELF header
    log.debug("Loading ELF header", .{});
    status = readAndAllocate(kernel_img_file, 0, @sizeOf(elf.Elf64_Ehdr), &header_buffer);
    defer _ = boot_services.freePool(header_buffer);
    if (status != .success) {
        log.err("Reading ELF header failed", .{});
        return status;
    }
    // parse elf header
    var header = elf.Header.parse(header_buffer[0..64]) catch |err| {
        switch (err) {
            error.InvalidElfMagic => {
                log.err("Invalid ELF magic", .{});
                return .invalid_parameter;
            },
            error.InvalidElfVersion => {
                log.err("Invalid ELF version", .{});
                return .incompatible_version;
            },
            error.InvalidElfEndian => {
                log.err("Invalid ELF endianness", .{});
                return .incompatible_version;
            },
            error.InvalidElfClass => {
                log.err("Invalid ELF endianness", .{});
                return .incompatible_version;
            },
        }
    };
    // save kernel entry point
    log.debug("Loading ELF header succeeded; entry point is 0x{x}", .{header.entry});
    kernel_entry_point.* = header.entry;
    // load program headers
    log.debug("Loading program headers", .{});
    var program_headers_buffer: [*]align(8) u8 = undefined;
    status = readAndAllocate(kernel_img_file, header.phoff, header.phentsize * header.phnum, &program_headers_buffer);
    if (status != .success) {
        log.err("Reading ELF program headers failed", .{});
        return status;
    }
    defer _ = boot_services.freePool(program_headers_buffer);
    var section_headers_buffer: [*]align(8) u8 = undefined;
    status = readAndAllocate(kernel_img_file, header.shoff, header.shentsize * header.shnum, &section_headers_buffer);
    if (status != .success) {
        log.err("Reading ELF section headers failed", .{});
        return status;
    }
    defer _ = boot_services.freePool(section_headers_buffer);
    const program_headers: [*]const elf.Elf64_Phdr = @ptrCast(program_headers_buffer);
    const section_headers: [*]const elf.Elf64_Shdr = @ptrCast(section_headers_buffer);
    status = loadProgramSegments(
        kernel_img_file,
        &header,
        program_headers,
        section_headers,
        base_physical_address,
        kernel_start_address,
        dwarf_info,
    );
    return status;
}
