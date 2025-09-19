const builtin = @import("builtin");

pub const idt = switch (builtin.cpu.arch) {
    .x86 => @import("x86/idt.zig"),
    .x86_64 => @import("x86_64/idt.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const gdt = switch (builtin.cpu.arch) {
    .x86 => @import("x86/gdt.zig"),
    .x86_64 => @import("x86_64/gdt.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const Descriptor = packed struct {
    limit: u16,
    base: usize,
};

/// Access bits for the GDT
pub const GDTAccess = packed struct(u8) {
    /// should only be set by the cpu when segment is accessed
    accessed: bool = false,

    /// # Readable bit/Writable bit.
    /// - For code segments: Readable bit. If clear (0), read access for this segment is not allowed. If set (1) read access is allowed. Write access is never allowed for code segments.
    /// - For data segments: Writeable bit. If clear (0), write access for this segment is not allowed. If set (1) write access is allowed. Read access is always allowed for data segments.
    read_write: u1 = 0,

    /// # Direction bit/Conforming bit.
    /// ## For data selectors: Direction bit.
    /// - If clear (0) the segment grows up. If set (1) the segment grows down, ie. the Offset has to be greater than the Limit.
    /// ## For code selectors: Conforming bit.
    /// - If clear (0) code in this segment can only be executed from the ring set in DPL.
    /// - If set (1) code in this segment can be executed from an equal or lower privilege level.
    direction_conforming: u1 = 0,

    /// whether or not this segment is executable
    executable: bool = false,

    /// if 0, this segment defines an system segment, 1 = code/data segment
    descriptor_type: u1 = 0, // 0 = system, 1 = code/data

    /// # Descriptor privilege level field.
    /// Contains the `CPU Privilege level` of the segment.
    /// - 0 = highest privilege (kernel)
    /// - 3 = lowest privilege (user applications).
    privilage_level: u2 = 0,

    present: bool = false,
};

pub const GDTFlags = packed struct(u4) {
    _reserved: u1 = 0, // must be set zero
    /// If true, the descriptor defines a 64-bit code segment.
    ///     When set, size_flag should always be false.
    /// For any other type of segment (other code types or any data segment), it should be false.
    bit64: bool = false,

    /// If false, the descriptor defines a 16-bit protected segment
    /// If true, the descriptor defines a 32-bit protected segment
    bit32: bool = false,

    /// if true defines a granularity of 1 byte if false or 4kib blocks if true
    granularity: u1 = 0,
};
