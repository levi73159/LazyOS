const builtin = @import("builtin");

pub const Entry = packed struct {
    limit_low: u16,
    base_low: u24,
    access: Access,
    limit_high: u4,
    flags: Flags,
    base_high: u8,

    pub fn init(limit: u20, base: u32, access: Access, flags: Flags) Entry {
        return Entry{
            .limit_low = @truncate(limit & 0xFFFF),
            .base_low = @truncate(base & 0xFFFFFF),
            .access = access,
            .limit_high = @truncate((limit >> 16) & 0xF),
            .flags = flags,
            .base_high = @truncate((base >> 24) & 0xFF),
        };
    }

    pub fn nullDescriptor() Entry {
        return Entry{
            .limit_low = 0,
            .base_low = 0,
            .access = .{},
            .limit_high = 0,
            .flags = .{},
            .base_high = 0,
        };
    }
};

pub const Descriptor = packed struct {
    limit: u16, // @sizeOf(gdt) - 1
    base: u32,
};

/// Access bits for the GDT
pub const Access = packed struct(u8) {
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

pub const Flags = packed struct(u4) {
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

var gdt = [_]Entry{
    Entry.nullDescriptor(),

    // kernel 32 bit code segment
    Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = true,
        .descriptor_type = 1,
        .privilage_level = 0,
        .present = true,
    }, .{ .bit32 = true, .granularity = 1 }),

    // kernel 32 bit data segment
    Entry.init(0xFFFFF, 0, .{
        .accessed = false,
        .read_write = 1,
        .direction_conforming = 0,
        .executable = false,
        .descriptor_type = 1,
        .privilage_level = 0,
        .present = true,
    }, .{ .bit32 = true, .granularity = 1 }),
};

var descriptor = Descriptor{
    .limit = @sizeOf(Entry) * gdt.len - 1,
    .base = undefined,
};

pub fn init() !void {
    descriptor.base = @intCast(@intFromPtr(&gdt[0]));
    try loadGDT(&descriptor);
}

fn loadGDT(desc: *const Descriptor) !void {
    if (@import("builtin").is_test) return;

    asm volatile (
        \\lgdt (%[desc])
        :
        : [desc] "r" (desc),
        : "memory"
    );

    // we need to
    asm volatile (
        \\ljmp $0x08, $1
        \\1:
    );

    // reload data segment
    asm volatile (
        \\mov $0x10, %%eax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
    );

    if (builtin.mode == .Debug) {
        // quick sanity check on ds and es
        var ds: u16 = undefined;
        var es: u16 = undefined;
        asm volatile ("mov %%ds, %[ds]\nmov %%es, %[es]"
            : [ds] "=r" (ds),
              [es] "=r" (es),
        );
        if (ds != 0x10 or es != 0x10) {
            return error.LoadFailed;
        }
    }
}
