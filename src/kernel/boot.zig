const std = @import("std");
const main = @import("main.zig");
const console = @import("graphics/console.zig");
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

export var kernel_file_request: limine.ExecutableFileRequest linksection(".limine_requests") = .{};

pub const KERNEL_STACK_SIZE: usize = 4096 + 1024 * 1024; // 1 MiB
pub export var kernel_stack: [KERNEL_STACK_SIZE]u8 align(4096) linksection(".bss") = undefined; // KERNEL_STACK_SIZE + 1 page aka the stack overflow page

// ─────────────────────────────────────────────────────────────────────────────
// Linker script variables
// ─────────────────────────────────────────────────────────────────────────────

extern const kernel_size: u8;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point — must be .naked, no compiler prologue allowed
// ─────────────────────────────────────────────────────────────────────────────

export fn boot_init() callconv(.naked) noreturn {
    asm volatile ("lea kernel_stack + " ++ std.fmt.comptimePrint("{d}", .{KERNEL_STACK_SIZE}) ++ "(%rip), %rsp\n" ++ "xor %ebp, %ebp\n"

            // enable SSE
        ++ "mov %cr0, %rax\n" ++ "and $0xFFFFFFFFFFFFFFFB, %rax\n" ++ "or  $0x2, %rax\n" ++ "mov %rax, %cr0\n"

            // enable SSE + AVX in CR4
        ++ "mov %cr4, %rax\n" ++ "or  $0x40600, %rax\n" // OSFXSR(bit9) | OSXMMEXCPT(bit10) | OSXSAVE(bit18)
        ++ "mov %rax, %cr4\n"

            // enable AVX in XCR0 via xsetbv
            // XCR0 bit 0 = x87, bit 1 = SSE, bit 2 = AVX
        ++ "xor %ecx, %ecx\n" // XCR0 index = 0
        ++ "xgetbv\n" // read current XCR0 into edx:eax
        ++ "or  $0x7, %eax\n" // enable x87 + SSE + AVX
        ++ "xsetbv\n" // write back

        ++ "call boot_init_stage2\n" ::: .{ .memory = true });
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

    if (kernel_file_request.response) |response| {
        const file = response.executable_file;
        @import("debug/symbols.zig").init(file.address[0..file.size]);
    }

    // Draw a red stripe directly — no abstraction, no page tables, no heap
    // If you see this, framebuffer works
    const pixels: [*]u32 = @ptrCast(@alignCast(fb.address));
    const stride = fb.pitch / 4;
    for (0..50) |y| {
        for (0..fb.width) |x| {
            pixels[y * stride + x] = 0x00FF0000; // red
        }
    }

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

pub fn panic(msg: []const u8, stack: ?*std.builtin.StackTrace, ret: ?usize) noreturn {
    @branchHint(.cold);
    @import("panic_handler.zig").panic(msg, stack, ret);
}
