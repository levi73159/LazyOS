const std = @import("std");
const bootinfo = @import("bootinfo.zig");
const pmem = @import("../memory/pmem.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(._vmem);

const Self = @This();

pub const VirtualAddress = packed struct(u64) {
    offset: u12 = 0,
    pt_index: u9 = 0,
    pd_index: u9 = 0,
    pdpt_index: u9 = 0,
    pml4_index: u9 = 0,
    sign_extension: u16 = 0,

    pub fn from(address: u64) VirtualAddress {
        return @bitCast(address);
    }
};

pub const PageFlags = struct {
    present: bool = false,
    writeable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disabled: bool = false,
    page_size: bool = false,
    execute_disable: bool = false,
    global: bool = false,
    pat: bool = false,
    guard: bool = false,

    pub const rw = PageFlags{ .present = true, .writeable = true };
    pub const ro = PageFlags{ .present = true, .writeable = false };

    pub const user_rw = PageFlags{ .present = true, .writeable = true, .user = true };
    pub const user_ro = PageFlags{ .present = true, .writeable = false, .user = true };

    pub const none = PageFlags{};
};

const PageEntry = packed struct(u64) {
    present: bool = false,
    writeable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disabled: bool = false,
    accessed: bool = false,
    dirty: bool = false, // reserved in non-page-sized entries
    page_size: bool = false,
    global: bool = false,
    guard: bool = false,
    avl: u1 = 0,
    pat: bool = false,
    address: u40 = 0,
    __reserved2: u11 = 0,
    execute_disable: bool = false,

    pub fn init(address: u64, flags: PageFlags) PageEntry {
        std.debug.assert(address & 0xFFF == 0); // address must be page aligned
        return .{
            .present = flags.present,
            .writeable = flags.writeable,
            .user = flags.user,
            .write_through = flags.write_through,
            .cache_disabled = flags.cache_disabled,
            .page_size = flags.page_size,
            .execute_disable = flags.execute_disable,
            .address = @truncate(address >> 12),
            .global = flags.global,
            .pat = flags.pat,
            .guard = flags.guard,
        };
    }

    pub fn getAddress(self: PageEntry) u64 {
        return @as(u64, self.address) << 12;
    }
};

pub const PAGE_SIZE = 4096;
pub const HUGE_PAGE_SIZE = 2 * 1024 * 1024; // 2MB
pub const PageTable = [512]PageEntry;

pub const GuardPage = struct {
    name: []const u8,
    virt: u64,
};

pub const Region = struct {
    name: []const u8,
    start: u64,
    end: u64,
};

pml4: *PageTable,
guard_pages: std.ArrayList(GuardPage) = .empty,
regions: std.StringArrayHashMapUnmanaged(Region) = .empty,

pub fn init() Self {
    const pml4 = createPageTable();
    return .{ .pml4 = pml4 };
}

pub fn deinit(self: *Self) void {
    for (self.pml4[0..256]) |entry| {
        if (!entry.present) continue;
        freePageTableEntry(@ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress())), 3);
    }
    pmem.kernel().freePageV(@intFromPtr(self.pml4));

    const allocator = @import("../memory/heap.zig").allocator();

    self.regions.deinit(allocator);
    self.guard_pages.deinit(allocator);
}

pub fn safeDeinit(self: *Self) void {
    const cr3 = asm volatile ("mov %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );

    const phys = bootinfo.toPhysical(@intFromPtr(self.pml4));
    if (cr3 == phys) {
        log.err("PML4 still in use: {x}", .{phys});
        paging.getKernelVmem().switchTo(); // switch to kernel virtual memory so we don't crash
    }

    self.deinit();
}

// pml4 -> pdpt -> pd -> pt
fn freePageTableEntry(table: *PageTable, level: u8) void {
    for (table) |entry| {
        if (entry.present) {
            if (level != 0 and !entry.page_size) {
                const next: *PageTable = @ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress()));
                freePageTableEntry(next, level - 1);
                pmem.kernel().freePage(entry.getAddress());
            }
        }
    }
}

pub fn addGuardPage(self: *Self, allocator: std.mem.Allocator, name: []const u8, virt: u64) void {
    if (virt & 0xFFF != 0) {
        log.warn("virtual is not page aligned", .{});
    }
    self.mapGuard(virt);
    self.guard_pages.append(allocator, .{
        .name = name,
        .virt = virt,
    }) catch {
        log.warn("Out of memory, can't add guard page: {s}", .{name});
        return;
    };

    log.info("Added guard page {s} at {x}", .{ name, virt });
}

fn createPageTable() *PageTable {
    const phys = pmem.kernel().allocPage() catch {
        @panic("Failed to allocate page: Out of memory");
    };
    std.debug.assert(phys % PAGE_SIZE == 0); // should always hold
    const ptr: *PageTable = @ptrFromInt(bootinfo.toVirtualHHDM(phys));
    ptr.* = std.mem.zeroes(PageTable);
    return ptr;
}

fn getOrCreatePageTable(table: *PageTable, index: u9, user: bool) *PageTable {
    const entry = &table[index];
    if (entry.guard) {
        log.err("Overlapping guard page, return address: 0x{x}", .{@returnAddress()});
    }
    if (entry.present) {
        if (user and !entry.user) {
            entry.user = true;
        }
        if (user and entry.page_size) {
            log.warn("HUGE PAGE CONFLICT WITH SMALL PAGE at {x}", .{entry.getAddress()});
        }
        return @ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress()));
    } else {
        const new_table = createPageTable();
        entry.* = PageEntry.init(bootinfo.toPhysicalHHDM(@intFromPtr(new_table)), if (user) .user_rw else .rw);
        return new_table;
    }
}

fn getPageTable(table: *PageTable, index: u9, user: bool) ?*PageTable {
    const entry = &table[index];
    if (entry.guard) {
        log.err("Overlapping guard page, return address: 0x{x}", .{@returnAddress()});
    }
    if (entry.present) {
        if (user and !entry.user) {
            entry.user = true;
        }
        if (user and entry.page_size) {
            log.warn("HUGE PAGE CONFLICT WITH SMALL PAGE at {x}", .{entry.getAddress()});
        }
        return @ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress()));
    } else {
        return null;
    }
}

// NOTE: virt and phys must be page aligned
pub fn mapPage(self: *const Self, virt: u64, phys: u64, flags: PageFlags) void {
    const va = VirtualAddress.from(virt);

    std.debug.assert(phys & 0xFFF == 0);
    std.debug.assert(virt & 0xFFF == 0);

    const pdpt_table = getOrCreatePageTable(self.pml4, va.pml4_index, flags.user);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index, flags.user);
    if (pd_table[va.pd_index].page_size) {
        log.err("Try to map huge page to small page at {d}", .{va.pd_index});
        log.err("phys: {x}, virt: {x}", .{ phys, virt });
        @panic("Try to map huge page to small page");
    }
    const pt_table = getOrCreatePageTable(pd_table, va.pd_index, flags.user);

    if (pt_table[va.pt_index].present) {
        log.warn("Overwritting page {x}, phys: {x}", .{ virt, pt_table[va.pt_index].getAddress() });
    }
    pt_table[va.pt_index] = PageEntry.init(phys, flags);
}

pub fn unmapPage(self: *const Self, virt: u64) void {
    const va = VirtualAddress.from(virt);

    std.debug.assert(virt & 0xFFF == 0);

    const pdpt_table = getPageTable(self.pml4, va.pml4_index, false) orelse return;
    const pd_table = getPageTable(pdpt_table, va.pdpt_index, false) orelse return;
    const pt_table = getPageTable(pd_table, va.pd_index, false) orelse return;
    if (pd_table[va.pd_index].page_size) {
        log.err("Try to map huge page to small page at {d}", .{va.pd_index});
        log.err("virt: {x}", .{virt});
        @panic("Try to map huge page to small page");
    }
    pt_table[va.pt_index] = PageEntry.init(0, .none);
}

/// NOTE: virt and phys must be page aligned
pub fn mapRange(self: *const Self, virt: u64, phys: u64, size: u64, flags: PageFlags) void {
    var offset: u64 = 0;
    const size_aligned = std.mem.alignForward(u64, size, PAGE_SIZE);
    while (offset < size_aligned) : (offset += PAGE_SIZE) {
        self.mapPage(virt + offset, phys + offset, flags);
    }
}

pub fn unmapRange(self: *const Self, virt: u64, size: u64) void {
    var offset: u64 = 0;
    const size_aligned = std.mem.alignForward(u64, size, PAGE_SIZE);
    while (offset < size_aligned) : (offset += PAGE_SIZE) {
        self.unmapPage(virt + offset);
    }
}

pub fn mapGuard(self: *const Self, virt: u64) void {
    const va = VirtualAddress.from(virt);

    const pdpt_table = getOrCreatePageTable(self.pml4, va.pml4_index, false);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index, false);
    if (pd_table[va.pd_index].page_size) {
        log.info("Spliting huge page", .{});
        splitHugePage(pd_table, va.pd_index, virt);
    }
    const pt_table = getOrCreatePageTable(pd_table, va.pd_index, false);
    pt_table[va.pt_index] = PageEntry.init(0, .{ .guard = true }); // a null entry
}

fn splitHugePage(pd_table: *PageTable, index: u9, va: usize) void {
    const entry = &pd_table[index];

    const huge_phys = entry.getAddress();

    const flags = PageFlags{
        .present = entry.present,
        .writeable = entry.writeable,
        .user = entry.user,
        .write_through = entry.write_through,
        .cache_disabled = entry.cache_disabled,
        .execute_disable = entry.execute_disable,
        .pat = entry.pat,
        .global = entry.global,
    };

    const new_pt = createPageTable();
    for (0..512) |i| {
        new_pt[i] = PageEntry.init(huge_phys + @as(u64, i) * PAGE_SIZE, flags);
    }

    entry.* = PageEntry.init(bootinfo.toPhysicalHHDM(@intFromPtr(new_pt)), if (entry.user) .user_rw else .rw);

    // proper flush of the whole split range
    var flush_offset: u64 = 0;
    while (flush_offset < HUGE_PAGE_SIZE) : (flush_offset += PAGE_SIZE) {
        asm volatile ("invlpg (%[v])"
            :
            : [v] "r" (va + flush_offset),
            : .{ .memory = true });
    }
}

pub fn mapHugePage(self: *const Self, virt: u64, phys: u64, flags: PageFlags) void {
    const va = VirtualAddress.from(virt);
    std.debug.assert(phys & (HUGE_PAGE_SIZE - 1) == 0);
    std.debug.assert(virt & (HUGE_PAGE_SIZE - 1) == 0);
    const pdpt_table = getOrCreatePageTable(self.pml4, va.pml4_index, flags.user);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index, flags.user);
    const entry = pd_table[va.pd_index];
    if (entry.present and !entry.page_size) {
        log.warn("HUGE PAGE CONFLICT WITH SMALL PAGE at {x}, overwriting", .{virt});
    }
    // set huge page bit directly in PD, no PT needed
    pd_table[va.pd_index] = PageEntry.init(phys, .{
        .present = flags.present,
        .writeable = flags.writeable,
        .page_size = true, // this makes it a 2MB page
        .execute_disable = flags.execute_disable,
    });
}

pub fn getPhys(self: *const Self, virt: u64, user: bool) ?u64 {
    const va = VirtualAddress.from(virt);
    const pdpt_table = getOrCreatePageTable(self.pml4, va.pml4_index, false);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index, false);
    const pt_table = getOrCreatePageTable(pd_table, va.pd_index, false);
    const entry = pt_table[va.pt_index];
    if (!entry.present) return null;
    if (!entry.user and user) {
        log.warn("User process try to get privilege page at {x}", .{virt});
        return null;
    }
    return entry.getAddress();
}

pub fn switchTo(self: *const Self) void {
    const phys = bootinfo.toPhysical(@intFromPtr(self.pml4));
    asm volatile (
        \\ mov %[pml4], %%cr3
        :
        : [pml4] "r" (phys),
    );
}

pub fn addRegion(
    self: *Self,
    allocator: std.mem.Allocator,
    name: []const u8,
    start: u64,
    size: u64,
) void {
    const end = start + size;

    self.regions.put(allocator, name, .{
        .name = name,
        .start = start,
        .end = end,
    }) catch {
        log.err("Failed to add region {s}", .{name});
        return;
    };

    log.debug("Region {s}: {x} - {x}", .{ name, start, end });
}

pub fn addRegion2(
    self: *Self,
    allocator: std.mem.Allocator,
    name: []const u8,
    start: u64,
    end: u64,
) void {
    self.regions.put(allocator, name, .{
        .name = name,
        .start = start,
        .end = end,
    }) catch {
        log.err("Failed to add region {s}", .{name});
        return;
    };

    log.debug("Region {s}: {x} - {x}", .{ name, start, end });
}

pub fn getGuardPage(self: *const Self, vaddr: usize) ?GuardPage {
    const aligned_vaddr = std.mem.alignBackward(usize, vaddr, 4096);
    for (self.guard_pages.items) |guard| {
        if (guard.virt == aligned_vaddr) return guard;
    }
    return null;
}

pub fn findRegion(self: *const Self, addr: u64) ?Region {
    for (self.regions.values()) |region| {
        if (addr >= region.start and addr < region.end) {
            return region;
        }
    }
    return null;
}
