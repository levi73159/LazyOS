//! limine.zig — Native Zig bindings for the Limine Boot Protocol
//!
//! Verified against the official limine-protocol spec (base revision 4),
//! which is what Limine v10 uses.  No limine.h / @cImport needed.
//!
//! Usage:
//!   const limine = @import("limine.zig");
//!
//!   export var base_revision  = limine.base_revision;
//!   export var requests_start = limine.requests_start;
//!   export var requests_end   = limine.requests_end;
//!
//!   export var fb_req: limine.FramebufferRequest linksection(".limine_requests") = .{};
//!   export var mm_req: limine.MemmapRequest      linksection(".limine_requests") = .{};

// ─────────────────────────────────────────────────────────────────────────────
// Internal magic numbers (from official protocol spec)
// ─────────────────────────────────────────────────────────────────────────────

/// First two words shared by every request ID.
const COMMON_MAGIC = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// ─────────────────────────────────────────────────────────────────────────────
// Protocol markers — place exactly once anywhere in your kernel
// ─────────────────────────────────────────────────────────────────────────────

/// Place in section ".limine_requests_start"
/// Tells Limine v10 where your requests begin.
pub const requests_start: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
    0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

/// Place in section ".limine_requests_end"
/// Tells Limine v10 where your requests end.
pub const requests_end: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};

/// Place in section ".limine_requests"
/// Revision 4 is the latest, and is required for Limine v10 features such as
/// LIMINE_MEMMAP_ACPI_TABLES.  If Limine does not support revision 4 it will
/// respond with the highest revision it does support (written into [2]).
pub const base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc,
    4, // ← base revision number
};

// ─────────────────────────────────────────────────────────────────────────────
// Memory map
// ─────────────────────────────────────────────────────────────────────────────

pub const MemmapEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    acpi_tables = 8, // base revision 4+
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemmapEntryType,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemmapEntry, // array of pointers to entries
};

pub const MemmapRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC[0],    COMMON_MAGIC[1],
        0x67cf3d9d378a806f, 0xe304acdfc50c3c62,
    },
    revision: u64 = 0,
    response: ?*MemmapResponse = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Framebuffer
// ─────────────────────────────────────────────────────────────────────────────

pub const VideoMode = extern struct {
    pitch: u64,
    width: u64,
    height: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const Framebuffer = extern struct {
    address: [*]u8, // pointer to framebuffer memory
    width: u64,
    height: u64,
    pitch: u64, // bytes per row
    bpp: u16, // bits per pixel
    memory_model: u8, // 1 = RGB
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    _unused: [7]u8,
    edid_size: u64,
    edid: ?[*]u8,
    // response revision >= 1
    mode_count: u64,
    modes: [*]*VideoMode,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]*Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC[0],    COMMON_MAGIC[1],
        0x9d5827dcd881dd75, 0xa3148604f6fab11b,
    },
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// HHDM (Higher Half Direct Map offset)
// Useful for converting physical addresses to virtual after Limine's paging
// ─────────────────────────────────────────────────────────────────────────────

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64, // add this to any physical address to get its HHDM vaddr
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC[0],    COMMON_MAGIC[1],
        0x48dcf1cb8ad2b852, 0x63984e959a98244b,
    },
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Kernel Address
// Physical and virtual base of the kernel image as loaded by Limine
// ─────────────────────────────────────────────────────────────────────────────

pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const KernelAddressRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC[0],    COMMON_MAGIC[1],
        0x71ba76863cc55f63, 0xb2644a48c516a487,
    },
    revision: u64 = 0,
    response: ?*KernelAddressResponse = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Stack Size
// Ask Limine to allocate a larger boot stack
// ─────────────────────────────────────────────────────────────────────────────

pub const StackSizeResponse = extern struct {
    revision: u64,
};

pub const StackSizeRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC[0],    COMMON_MAGIC[1],
        0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d,
    },
    revision: u64 = 0,
    response: ?*StackSizeResponse = null,
    stack_size: u64, // requested size in bytes; also used for SMP APs
};

// ─────────────────────────────────────────────────────────────────────────────
// Bootloader Info
// ─────────────────────────────────────────────────────────────────────────────

pub const BootloaderInfoResponse = extern struct {
    revision: u64,
    name: [*:0]const u8,
    version: [*:0]const u8,
};

pub const BootloaderInfoRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC[0],    COMMON_MAGIC[1],
        0xf55038d8e2a1202f, 0x279426fcf5f59740,
    },
    revision: u64 = 0,
    response: ?*BootloaderInfoResponse = null,
};

// #define LIMINE_RSDP_REQUEST_ID { LIMINE_COMMON_MAGIC, 0xc5e77b6b397e7b43, 0x27637845accdcf3c }
pub const RSDPRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC[0], COMMON_MAGIC[1], 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    revision: u64 = 0,
    response: ?*RSDPResponse = null,
};

pub const RSDPResponse = extern struct {
    revision: u64,
    address: u64,
};

// ─────────────────────────────────────────────────────────────────────────────
// Firmware Type
// ─────────────────────────────────────────────────────────────────────────────

pub const FirmwareType = enum(u64) {
    x86_bios = 0,
    uefi32 = 1,
    uefi64 = 2,
};

pub const FirmwareTypeResponse = extern struct {
    revision: u64,
    firmware_type: FirmwareType,
};

pub const FirmwareTypeRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC[0],    COMMON_MAGIC[1],
        0x8c2f75d90bef28a8, 0x7045a4688eac00c3,
    },
    revision: u64 = 0,
    response: ?*FirmwareTypeResponse = null,
};
