//! The Kernel Boot Info structures

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024 Samuel Fiedler

const std = @import("std");
const uefi = std.os.uefi;

/// Video Mode Info
pub const KernelBootVideoModeInfo = extern struct {
    framebuffer_pointer: [*]volatile u32,
    framebuffer_size: usize,
    horizontal_resolution: u32,
    vertical_resolution: u32,
    pixels_per_scanline: u32,
    pixel_format: u32,
};

/// Kernel Boot Info
pub const KernelBootInfo = extern struct {
    memory_map: [*]uefi.tables.MemoryDescriptor,
    memory_map_size: usize,
    memory_map_descriptor_size: usize,
    video_mode_info: KernelBootVideoModeInfo,
    rsdp_10: ?*anyopaque,
    rsdp_20: ?*anyopaque,
    kernel_phys_start: usize,
    kernel_phys_end: usize,
    kernel_virt_start: usize,
    kernel_virt_end: usize,
    dwarf_info: *?std.debug.Dwarf,
    runtime_services: *uefi.tables.RuntimeServices,
};
