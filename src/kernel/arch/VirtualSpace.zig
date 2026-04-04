const std = @import("std");
const bootinfo = @import("bootinfo.zig");
const pmem = @import("../memory/pmem.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.vmem);

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

    pub const rw = PageFlags{ .present = true, .writeable = true };
    pub const ro = PageFlags{ .present = true, .writeable = false };

    pub const user_rw = PageFlags{ .present = true, .writeable = true, .user = true };
    pub const user_ro = PageFlags{ .present = true, .writeable = false, .user = true };
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
    avl: u2 = 0,
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
        };
    }

    pub fn getAddress(self: PageEntry) u64 {
        return @as(u64, self.address) << 12;
    }
};

pub const PAGE_SIZE = 4096;
pub const HUGE_PAGE_SIZE = 2 * 1024 * 1024; // 2MB
pub const PageTable = [512]PageEntry;

pml4: *PageTable,

pub fn init() Self {
    const pml4 = createPageTable();
    return .{ .pml4 = pml4 };
}

pub fn deinit(self: *const Self) void {
    for (self.pml4[0..256]) |entry| {
        if (!entry.present) continue;
        freePageTableEntry(@ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress())), 3);
    }
    pmem.kernel().freePageV(@intFromPtr(self.pml4));
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

pub fn safeDeinit(self: *const Self) void {
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

fn createPageTable() *PageTable {
    const phys = pmem.kernel().allocPage() catch {
        @panic("Failed to allocate page: Out of memory");
    };
    std.debug.assert(phys % PAGE_SIZE == 0); // should always hold

    return @ptrFromInt(bootinfo.toVirtualHHDM(phys));
}

fn getOrCreatePageTable(table: *PageTable, index: u9, user: bool) *PageTable {
    const entry = &table[index];
    if (entry.present) {
        if (user and !entry.user) {
            entry.user = true;
        }
        return @ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress()));
    } else {
        const new_table = createPageTable();
        entry.* = PageEntry.init(bootinfo.toPhysicalHHDM(@intFromPtr(new_table)), if (user) .user_rw else .rw);
        return new_table;
    }
}

// NOTE: virt and phys must be page aligned
pub fn mapPage(self: *const Self, virt: u64, phys: u64, flags: PageFlags) void {
    const va = VirtualAddress.from(virt);

    std.debug.assert(phys & 0xFFF == 0);
    std.debug.assert(virt & 0xFFF == 0);

    const pdpt_table = getOrCreatePageTable(self.pml4, va.pml4_index, flags.user);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index, flags.user);
    const pt_table = getOrCreatePageTable(pd_table, va.pd_index, flags.user);

    pt_table[va.pt_index] = PageEntry.init(phys, flags);
}

/// NOTE: virt and phys must be page aligned
pub fn mapRange(self: *const Self, virt: u64, phys: u64, size: u64, flags: PageFlags) void {
    var offset: u64 = 0;
    const size_aligned = std.mem.alignForward(u64, size, PAGE_SIZE);
    while (offset < size_aligned) : (offset += PAGE_SIZE) {
        self.mapPage(virt + offset, phys + offset, flags);
    }
}

pub fn mapHugePage(self: *const Self, virt: u64, phys: u64, flags: PageFlags) void {
    const va = VirtualAddress.from(virt);
    std.debug.assert(phys & (HUGE_PAGE_SIZE - 1) == 0);
    std.debug.assert(virt & (HUGE_PAGE_SIZE - 1) == 0);
    const pdpt_table = getOrCreatePageTable(self.pml4, va.pml4_index, flags.user);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index, flags.user);
    const entry = pd_table[va.pd_index];
    if (entry.present and entry.page_size) {
        log.debug("HUGE PAGE CONFLICT at {x}", .{virt});
    }
    // set huge page bit directly in PD, no PT needed
    pd_table[va.pd_index] = PageEntry.init(phys, .{
        .present = flags.present,
        .writeable = flags.writeable,
        .page_size = true, // this makes it a 2MB page
        .execute_disable = flags.execute_disable,
    });
}

pub fn switchTo(self: *const Self) void {
    const phys = bootinfo.toPhysical(@intFromPtr(self.pml4));
    asm volatile (
        \\ mov %[pml4], %%cr3
        :
        : [pml4] "r" (phys),
    );
}
