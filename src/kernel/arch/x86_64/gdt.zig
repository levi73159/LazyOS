//! The Global Descriptor Table

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024 Samuel Fiedler

const std = @import("std");
const log = std.log.scoped(.arch_gdt);

const registers = @import("./registers.zig");

extern const __stack_top: anyopaque;

/// The Task State Segment
pub const TSS = extern struct {
    /// Reserved
    res1: u32 align(1) = 0,
    /// RSPs
    rsp: [3]u64 align(1) = .{0} ** 3,
    /// Reserved
    res2: u64 align(1) = 0,
    /// ISTs
    ist: [7]u64 align(1) = .{0} ** 7,
    /// Reserved
    res3: u64 align(1) = 0,
    /// Reserved
    res4: u16 align(1) = 0,
    /// Size of this struct
    io_base: u16 align(1) = @sizeOf(@This()),
};

var global_tss = TSS{};
const ist_vec: u8 = 1;

/// Set Interrupt Stack Table
pub fn setIST(value: u64) void {
    global_tss.ist[getISTVec() - 1] = value;
}

/// Get Interrupt Stack Table
pub fn getISTVec() u8 {
    return ist_vec & 0b111;
}

/// Access byte of a GDT entry
pub const Access = packed struct(u8) {
    /// Accessed bit
    /// The CPU will set this bit when the segment is accessed unless set to 1 in advance.
    a: bool = false,
    /// Readable bit/ Writable bit
    /// For code segments: Readable bit. If clear, read access for this segment is not allowed. If set, read access is allowed. Write access is never allowed for code segments.
    /// For data segments: Writeable bit. If clear, write access for this segment is not allowed. If set, write access is allowed. Read access is always allowed for data segments.
    rw: bool = false,
    /// Direction bit / Conforming bit
    /// For data selectors: Direction bit. If clear, the segment grows up. If set, the segment grows down, i.e. the Offset has to be greater than the Limit.
    /// For code selectors: Conforming bit.
    ///   - If clear, code in this segment can only be executed from the ring set in DPL.
    ///   - If set, code in this segment can be executed from an equal or lower privilege level.
    dc: bool = false,
    /// Executable bit
    /// If clear, the descriptor defines a data segment. If set, it defines a code segment which can be executed from.
    e: bool = false,
    /// Descriptor type bit.
    /// If clear, the descriptor defines a system segment (e.g. a Task State Segment). If set, it defines a code or data (=user) segment.
    s: enum(u1) {
        sys = 0,
        data_code = 1,
    } = .sys,
    /// Descriptor privilege level field.
    /// Contains the CPU Privilege Level of the segment. 0 = highest privilege, 3 = lowest privilege.
    dpl: enum(u2) {
        kernel = 0,
        user = 3,
        _,
    } = .kernel,
    /// Present bit
    /// Allows an entry to refer to a valid segment. Must be set for any valid segment
    p: bool = false,

    /// Kernel Code Access
    pub const kernel_code = Access{
        .e = true,
        .s = .data_code,
        .p = true,
        .rw = true,
    };
    /// Kernel Data Access
    pub const kernel_data = Access{
        .s = .data_code,
        .p = true,
        .rw = true,
    };
    /// User Code Access
    pub const user_code = Access{
        .e = true,
        .s = .data_code,
        .p = true,
        .rw = true,
        .dpl = .user,
    };
    /// User Data Access
    pub const user_data = Access{
        .s = .data_code,
        .p = true,
        .rw = true,
        .dpl = .user,
    };
};

/// Flags half-byte of a GDT Entry
pub const Flags = packed struct(u4) {
    /// Reserved
    res1: u1 = 0,
    /// Long mode Flag
    /// If set, the descriptor defines a 64bit code segment. When set, DB should always be clear. For any other type of segment (other code types or any data segment), it should be clear.
    l: bool = true,
    /// Size Flag
    /// If clear, the descriptor defines a 16bit protected mode segment. If set, it defines a 32bit protected mode segment.
    db: bool = false,
    /// Granularity Flag
    /// Indicates the size the Limit value is scaled by. If clear, the Limit is in 1 byte blocks. If set, the Limit is in 4KB blocks.
    g: bool = false,
};

/// GDT Entry
/// In 64bit mode, the Base and Limit values are ignored, each descriptor covers the entire linear address space regardless of what they are set to.
pub const Entry = packed struct(u64) {
    /// First part of the Limit (a 20-bit value, tells the maximum addressable unit, either in 1 byte units or in 4KB pages. If set to 0xfffff, the segment will span the full 4GB address space in 32bit mode)
    limit_low: u16 = 0xffff,
    /// First part of the Base (a 32-bit value containing the linear address where the segment begins)
    base_low: u24 = 0,
    /// Access bit
    access: Access = .{},
    /// Second part of the Limit
    limit_high: u4 = 0xf,
    /// Flag half bit
    flags: Flags = .{},
    /// Second part of the Base
    base_high: u8 = 0,

    /// Null Segment Entry
    pub const null_segment: Entry = @bitCast(@as(u64, 0));
    /// Kernel Code Entry
    pub const kernel_code = Entry{
        .access = Access.kernel_code,
        .flags = .{
            .g = true,
            .l = true,
        },
    };
    /// Kernel Data Entry
    pub const kernel_data = Entry{
        .access = Access.kernel_data,
        .flags = .{
            .g = true,
            .l = true,
        },
    };
    /// User Code Entry
    pub const user_code = Entry{
        .access = Access.user_code,
        .flags = .{
            .g = true,
            .l = true,
        },
    };
    /// User Data Entry
    pub const user_data = Entry{
        .access = Access.user_data,
        .flags = .{
            .g = true,
            .l = true,
        },
    };
};

/// Access byte of a System Entry in the GDT
pub const SystemAccess = packed struct(u8) {
    /// Type of system segment
    type: enum(u4) {
        ldt = 2,
        tss_64bit_available = 9,
        tss_64bit_busy = 11,
    } = .tss_64bit_available,
    /// Descriptor type bit.
    /// If clear, the descriptor defines a system segment (e.g. a Task State Segment). If set, it defines a code or data (=user) segment.
    s: enum(u1) {
        sys = 0,
        data_code = 1,
    } = .sys,
    /// Descriptor privilege level field.
    /// Contains the CPU Privilege Level of the segment. 0 = highest privilege, 3 = lowest privilege.
    dpl: enum(u2) {
        kernel = 0,
        user = 3,
        _,
    } = .kernel,
    /// Present bit
    /// Allows an entry to refer to a valid segment. Must be set for any valid segment
    p: bool = false,

    /// TSS Access
    pub const tss = SystemAccess{
        .type = .tss_64bit_available,
        .p = true,
    };
};

/// System GDT Entry
pub const SystemEntry = packed struct(u128) {
    /// First part of the Limit (a 20-bit value, tells the maximum addressable unit, either in 1 byte units or in 4KB pages. If set to 0xffff, the segment will span the full 4GB address space in 32bit mode)
    limit_low: u16 = 0xffff,
    /// First part of the Base (a 64-bit value containing the linear address where the segment begins)
    base_low: u24 = 0,
    /// Access bit
    access: SystemAccess = .{},
    /// Second part of the Limit
    limit_high: u4 = 0xf,
    /// Flag half bit
    flags: Flags = .{},
    /// Second part of the Base
    base_high: u40 = 0,
    /// Reserved
    res1: u32 = 0,

    /// Get low part of the system entry
    pub fn low(self: SystemEntry) Entry {
        const ptr: *const Entry = @ptrCast(&self);
        return ptr.*;
    }

    /// Get high part of the system entry
    pub fn high(self: SystemEntry) Entry {
        const ptr: [*]const Entry = @ptrCast(&self);
        return ptr[1];
    }

    /// TSS Entry
    /// Has to be a function because tss_addr is not comptime
    pub fn getTSS() SystemEntry {
        const tss_addr = @intFromPtr(&global_tss);
        return SystemEntry{
            .limit_low = @sizeOf(TSS) - 1,
            .limit_high = 0,
            .base_low = @truncate(tss_addr & 0xffffff),
            .base_high = @truncate(tss_addr >> 24),
            .access = SystemAccess.tss,
            .flags = .{
                .l = false,
                .g = false,
            },
        };
    }
};

/// GDT Descriptor
pub const Descriptor = packed struct(u80) {
    /// Size
    /// GDT Byte Length - 1
    size: u16,
    /// Offset
    offset: u64,
};

/// GDT Selectors
pub const Selector = enum(u16) {
    /// Null Segment Selector
    null_segment = 0x00,
    /// Kernel Code Selector
    kernel_code = 0x08,
    /// Kernel Data Selector
    kernel_data = 0x10,
    /// User Code Selector
    user_code = 0x20,
    /// User Data Selector
    user_data = 0x28,
    /// TSS Selector
    tss = 0x30,
    /// Non-exhaustive
    _,
};

/// The GDT
pub var global_gdt: [8]Entry align(4096) = undefined;
pub var descriptor: Descriptor = undefined;

/// Initialize the GDT
pub fn init() void {
    log.info("GDT initialization...", .{});
    // disable interrupts
    asm volatile ("cli");
    // set kernel stack
    global_tss.rsp[0] = @intFromPtr(&__stack_top);
    // set the global descriptor table
    global_gdt = .{
        Entry.null_segment,
        Entry.kernel_code,
        Entry.kernel_data,
        Entry.null_segment,
        Entry.user_code,
        Entry.user_data,
        SystemEntry.getTSS().low(),
        SystemEntry.getTSS().high(),
    };
    // set the gdt descriptor
    descriptor = .{
        .size = @sizeOf(Entry) * 8 - 1,
        .offset = @intFromPtr(&global_gdt),
    };
    // load the gdt descriptor
    asm volatile ("lgdt (%[addr])"
        :
        : [addr] "{rax}" (&descriptor),
    );
    // register the tss entry, the kernel data entry and the kernel code entry
    asm volatile ("ltr %[val]"
        :
        : [val] "{ax}" (@as(u16, @intFromEnum(Selector.tss))),
    );
    registers.setDataSegments(@intFromEnum(Selector.kernel_data));
    registers.setCS(@intFromEnum(Selector.kernel_code));
    log.info("GDT initialization successful!", .{});
}

test "compile" {
    try std.testing.expect(@sizeOf(TSS) == 104);
}
