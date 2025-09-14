const std = @import("std");
const log = std.log.scoped(.paging);
const io = @import("../io.zig");

const PAGE_SIZE: usize = 4096;
const PDE_SIZE = 0x400000; // 4 MiB

const ENTRIES: usize = 1024;
const MAX_PDE: usize = 1024; // static alloc 1024 PDEs

// Flags
const PRESENT = 1 << 0;
const WRITEABLE = 1 << 1;
const USER = 1 << 2;
const PAGE_WRITE_THROUGH = 1 << 3;
const PAGE_CACHE_DISABLE = 1 << 4;
const ACCESSED = 1 << 5;
const DIRTY = 1 << 6; // ONLY IN PTE
// this is a PDE flag that instead of pointing to a page table, points to a 4MiB page of memory
const MAP_4Mib_PAGE = 1 << 6; // ONLY IN PDE
const PAGE_ATTRIBUTE_TABLE = 1 << 7; // Alternate memory type (only in PTE)
const GLOBAL = 1 << 8;

var page_directory: [ENTRIES]u32 align(PAGE_SIZE) = undefined;
var page_tables: [MAX_PDE][ENTRIES]u32 align(PAGE_SIZE) = undefined;

inline fn loadPageDirectory(addr: usize) void {
    // addr MUST be the PHYSICAL address of the page directory, 4KiB aligned
    log.debug("load CR3 with PD @ 0x{x}", .{addr});
    asm volatile (
        \\ movl %[a], %%eax
        \\ movl %%eax, %%cr3
        :
        : [a] "r" (addr),
        : .{ .eax = true, .memory = true }
    );
}

inline fn enablePaging() void {
    log.debug("enable paging (CR0.PG)", .{});
    asm volatile (
        \\ movl %%cr0, %%eax
        \\ orl  $0x80000000, %%eax      // set PG bit (bit 31)
        \\ movl %%eax, %%cr0
        ::: .{ .eax = true, .memory = true });
}

// stack pointers + KERNEL_ADDR_OFFSET
inline fn updateStackPointers(offset: usize) void {
    asm volatile (
        \\ add %[offset], %%esp
        \\ add %[offset], %%ebp
        :
        : [offset] "r" (offset),
    );
}

fn disablePaging() void {
    log.debug("disable paging (CR0.PG)", .{});
    asm volatile (
        \\ movl %%cr0, %%eax
        \\ andl $0x7FFFFFFF, %%eax      // clear PG bit (bit 31)
        \\ movl %%eax, %%cr0
        ::: .{ .eax = true, .memory = true });
}

fn disable4MibPaging() void {
    log.debug("disablling 4MiB paging", .{});
    asm volatile (
        \\mov %%cr4, %%eax
        \\and $0xFFFFFFEF, %%eax
        \\mov %%eax, %%cr4
    );
}

// helpers
inline fn alignDown(addr: usize) usize {
    return addr & ~(PAGE_SIZE - 1);
}

inline fn alignUp(addr: usize) usize {
    return (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
}

inline fn getPDEIndex(virtaddr: usize) u16 {
    return @truncate((virtaddr >> 22) & 0x3FF);
}

inline fn getPTEIndex(virtaddr: usize) u16 {
    return @truncate((virtaddr >> 12) & 0x3FF);
}

inline fn pt_entry(phys: usize) u32 {
    return @as(u32, (phys & 0xFFFFF000) | 0x3); // present | rw
}

/// Disables interupts, loads the page directory, and enables paging
/// NEVER ENABLES INTERRUPTS (must enable if needed)
pub fn init(kernel_start: usize, kernel_end: usize, phys_map_start: usize) void {
    log.debug("kernel_end_phys = 0x{x}", .{kernel_end});

    // ZERO page structures
    @memset(page_directory[0..], 0);
    for (page_tables[0..]) |*pt| {
        @memset(pt[0..], 0);
    }

    // map slightly past kernel to include stacks & page tables
    const margin: usize = 2 * 1024 * 1024; // 2 MiB margin
    const map_end: usize = kernel_end + margin;

    // map the kernel
    mapRegionToRegion(kernel_start, map_end, phys_map_start);

    const pd_phys = @intFromPtr(&page_directory);

    // finally enable (cli -> load CR3 -> set CR0.PG -> sti)
    io.cli();
    loadPageDirectory(pd_phys);
    enablePaging();
}

// returns true if a new page table was created
fn createDirectoryIfNeeded(pde_index: u16, flags: u16) void {
    // check if page directory exists
    if (page_directory[pde_index] & 1 == 0) {
        const pt_phys = @intFromPtr(&page_tables[pde_index]);
        log.debug("create page table @ 0x{x}", .{pt_phys});
        @memset(page_tables[pde_index][0..], 0);
        page_directory[pde_index] = (pt_phys & 0xFFFFF000) | flags;
    }
}

// map a section of memory at an identity-mapped address (phys = virt)
pub fn mapSectionIdentiy(start: usize, end: usize) void {
    log.debug("mapIdentiy 0x{x}..0x{x}", .{ start, end });

    var addr = alignDown(start);
    const limit = alignUp(end);

    while (addr < limit) : (addr += PAGE_SIZE) {
        const pde_index = getPDEIndex(addr);
        const pte_index = getPTEIndex(addr);

        // get or create page table
        createDirectoryIfNeeded(pde_index, 0x03);

        // now set the entry in the page table
        const pt = &page_tables[pde_index];
        pt[pte_index] = (addr & 0xFFFFF000) | 0x03;
    }
}

// map virtual region to a physical region
pub fn mapRegionToRegion(start: usize, end: usize, phys_start: usize) void {
    log.debug("mapRegion 0x{x}..0x{x} -> 0x{x}", .{ start, end, phys_start });
    var addr = alignDown(start);
    const limit = alignUp(end);

    var phys_addr = alignDown(phys_start);

    while (addr < limit) : (addr += PAGE_SIZE) {
        const pde_index = getPDEIndex(addr);
        const pte_index = getPTEIndex(addr);

        // get or create page table
        createDirectoryIfNeeded(pde_index, 0x03);

        // log.debug("MAP: 0x{x} -> 0x{x}", .{ addr, phys_addr });

        // now set the entry in the page table
        const pt = &page_tables[pde_index];
        pt[pte_index] = (phys_addr & 0xFFFFF000) | 0x03; // present | rw
        phys_addr += PAGE_SIZE;
    }
}
