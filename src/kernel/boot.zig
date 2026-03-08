const std = @import("std");
const main = @import("main.zig");
const console = @import("console.zig");
const bootinfo = @import("arch/bootinfo.zig");
const BootInfo = @import("arch/bootinfo.zig").BootInfo;
const paging = @import("arch/paging.zig");
const limine = @import("arch/limine.zig");

// ─────────────────────────────────────────────────────────────────────────────
// Limine tags
// ─────────────────────────────────────────────────────────────────────────────
/// First two words shared by every request ID.
const COMMON_MAGIC = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// ─────────────────────────────────────────────────────────────────────────────
// Protocol markers — place exactly once anywhere in your kernel
// ─────────────────────────────────────────────────────────────────────────────

/// Place in section ".limine_requests_start"
/// Tells Limine v10 where your requests begin.
export var requests_start: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
    0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

/// Place in section ".limine_requests_end"
/// Tells Limine v10 where your requests end.
export var requests_end: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};

/// Place in section ".limine_requests"
/// Revision 4 is the latest, and is required for Limine v10 features such as
/// LIMINE_MEMMAP_ACPI_TABLES.  If Limine does not support revision 4 it will
/// respond with the highest revision it does support (written into [2]).
export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc,
    4, // ← base revision number
};

export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

export var memmap_request: limine.MemmapRequest linksection(".limine_requests") = .{};
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};

export var kernel_addr_request: limine.KernelAddressRequest linksection(".limine_requests") = .{};

// ─────────────────────────────────────────────────────────────────────────────
// Boot stack
// ─────────────────────────────────────────────────────────────────────────────

const KERNEL_STACK_SIZE: usize = 1024 * 1024; // 1 MiB
export var kernel_stack: [KERNEL_STACK_SIZE]u8 align(16) linksection(".bss") = undefined;

// ─────────────────────────────────────────────────────────────────────────────
// Linker script variables
// ─────────────────────────────────────────────────────────────────────────────

extern const kernel_size: u8;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point — must be .naked, no compiler prologue allowed
// ─────────────────────────────────────────────────────────────────────────────

export fn boot_init() callconv(.naked) noreturn {
    asm volatile (
    // ── 1. Set our stack ─────────────────────────────────────────────
    // RIP-relative LEA: pure address arithmetic, no memory access,
    // safe before RSP is valid.
        "lea kernel_stack + " ++ std.fmt.comptimePrint("{d}", .{KERNEL_STACK_SIZE}) ++ "(%rip), %rsp\n" ++ "xor %ebp, %ebp\n"

            // ── 2. Enable SSE ────────────────────────────────────────────────
            // Zig emits SSE instructions constantly. CR0.EM=1 causes #UD on
            // every SSE opcode → triple fault with no IDT.
        ++ "mov %cr0, %rax\n" ++ "and $0xFFFFFFFFFFFFFFFB, %rax\n" // clear EM (bit 2)
        ++ "or  $0x2, %rax\n" // set  MP (bit 1)
        ++ "mov %rax, %cr0\n" ++ "mov %cr4, %rax\n" ++ "or  $0x600, %rax\n" // OSFXSR | OSXMMEXCPT
        ++ "mov %rax, %cr4\n" ++ "call boot_init_stage2\n" ::: .{ .memory = true });
}

// ─────────────────────────────────────────────────────────────────────────────
// Stage 2 — RSP valid, SSE on, still on Limine's CR3
// ─────────────────────────────────────────────────────────────────────────────

export fn boot_init_stage2() callconv(.c) noreturn {
    const fb = framebuffer_request.response.?.framebuffers[0];

    const mmap = memmap_request.response.?.entries;
    const mmap_count = memmap_request.response.?.entry_count;
    const mb = bootinfo.registerBootInfo(.{ .framebuffer = .{
        .address = @intFromPtr(fb.address),
        .width = fb.width,
        .height = fb.height,
        .pitch = fb.pitch,
        .bpp = fb.bpp,
    }, .memory_map = mmap[0..mmap_count], .hhdm_offset = hhdm_request.response.?.offset, .kernel = .{
        .phys_addr = kernel_addr_request.response.?.physical_base,
        .virt_addr = kernel_addr_request.response.?.virtual_base,
        .size = @intFromPtr(&kernel_size),
    } });

    main._start(mb);

    while (true) {
        asm volatile ("hlt");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zig hooks
// ─────────────────────────────────────────────────────────────────────────────

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = console.logFn,
    .page_size_min = 4096,
    .page_size_max = 4096,
};

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret: ?usize) noreturn {
    @branchHint(.cold);
    console.panic(msg, trace, ret);
}
