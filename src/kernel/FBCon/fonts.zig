//! Kernel Compiled-In Fonts

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024 Samuel Fiedler

pub const vga_8x16 = @import("./fonts/vga_8x16.zig").font_vga_8x16;
pub const unicodeToCP437 = @import("./fonts/charmap.zig").unicodeToCP437;

/// The Font Descriptor
pub const FontDesc = struct {
    name: []const u8,
    width: u4,
    height: u8,
    charcount: usize,
    data: []const u8,
};
