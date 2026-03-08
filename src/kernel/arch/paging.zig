const std = @import("std");
const pmem = @import("../memory/pmem.zig");
const bootinfo = @import("bootinfo.zig");

const log = std.log.scoped(.paging);

const PAGE_SIZE = 4096;

const VirtualAddress = packed struct(u64) {
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

const PageFlags = struct {
    present: bool = false,
    writeable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disabled: bool = false,
    page_size: bool = false,
    execute_disable: bool = false,

    pub const rw = PageFlags{ .present = true, .writeable = true };
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
    avl: u4 = 0, // available to software, not reserved
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
        };
    }

    pub fn getAddress(self: PageEntry) u64 {
        return @as(u64, self.address) << 12;
    }
};

pub const PageTable = [512]PageEntry;

var pml4: PageTable align(PAGE_SIZE) = .{PageEntry{}} ** 512;

pub fn createPageTable() *PageTable {
    const phys = pmem.allocPage() catch {
        @panic("Failed to allocate page: Out of memory");
    };
    std.debug.assert(phys % PAGE_SIZE == 0); // should always hold

    const virt = bootinfo.toVirtualHHDM(phys);
    const table: *PageTable align(PAGE_SIZE) = @ptrFromInt(virt);
    @memset(table, .{});

    return table;
}

fn getOrCreatePageTable(table: *PageTable, index: u9) *PageTable {
    const entry = table[index];
    if (entry.present) {
        return @ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress()));
    } else {
        const new_table = createPageTable();
        table[index] = PageEntry.init(bootinfo.toPhysicalHHDM(@intFromPtr(new_table)), .rw);
        return new_table;
    }
}

// NOTE: virt and phys must be page aligned
pub fn mapPage(virt: u64, phys: u64, flags: PageFlags) void {
    const va = VirtualAddress.from(virt);

    std.debug.assert(phys & 0xFFF == 0);
    std.debug.assert(virt & 0xFFF == 0);

    const pdpt_table = getOrCreatePageTable(&pml4, va.pml4_index);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index);
    const pt_table = getOrCreatePageTable(pd_table, va.pd_index);

    pt_table[va.pt_index] = PageEntry.init(phys, flags);
}

const HUGE_PAGE_SIZE = 2 * 1024 * 1024; // 2MB

pub fn mapHugePage(virt: u64, phys: u64, flags: PageFlags) void {
    const va = VirtualAddress.from(virt);
    std.debug.assert(phys & (HUGE_PAGE_SIZE - 1) == 0);
    std.debug.assert(virt & (HUGE_PAGE_SIZE - 1) == 0);
    const pdpt_table = getOrCreatePageTable(&pml4, va.pml4_index);
    const pd_table = getOrCreatePageTable(pdpt_table, va.pdpt_index);
    // set huge page bit directly in PD, no PT needed
    pd_table[va.pd_index] = PageEntry.init(phys, .{
        .present = flags.present,
        .writeable = flags.writeable,
        .page_size = true, // this makes it a 2MB page
        .execute_disable = flags.execute_disable,
    });
}

fn mapFramebuffer(fb: bootinfo.Framebuffer) void {
    const size = fb.width * fb.height * fb.bpp / 8;
    const phys = bootinfo.toPhysicalHHDM(fb.address);
    const virt = fb.address;

    var offset: u64 = 0;
    while (offset < size) : (offset += PAGE_SIZE) {
        mapPage(virt + offset, phys + offset, .{
            .present = true,
            .write_through = true,
            .writeable = true,
            .execute_disable = true,
        });
    }
}

pub fn init(mb: *const bootinfo.BootInfo) void {
    log.debug("Initializing paging", .{});

    // map all physical memory at HHDM offset (so toVirtual keeps working and this code still works)
    const total_memory = pmem.getHighestAddress(); // total_papges * PAGE_SIZE
    log.debug("Total memory: {x}", .{total_memory});
    // replace the 4KB HHDM loop with this
    var phys: u64 = 0;
    while (phys < total_memory) : (phys += HUGE_PAGE_SIZE) {
        mapHugePage(bootinfo.toVirtualHHDM(phys), phys, .rw);
    }
    log.debug("Initializing paging", .{});

    // map kernel
    var offset: u64 = 0;
    while (offset < mb.kernel.size) : (offset += PAGE_SIZE) {
        mapPage(mb.kernel.virt_addr + offset, mb.kernel.phys_addr + offset, .rw);
    }
    log.debug("Initializing paging", .{});

    mapFramebuffer(mb.framebuffer);

    const pml4_phys = bootinfo.kernelToPhysical(@intFromPtr(&pml4));
    log.debug("kernel_virt_start: {x}", .{mb.kernel.virt_addr});
    log.debug("kernel_phys_start: {x}", .{mb.kernel.phys_addr});
    log.debug("kernel_size: {x}", .{mb.kernel.size});
    log.debug("pml4_phys: {x}", .{pml4_phys});
    const pml4_virt = @intFromPtr(&pml4);
    log.debug("pml4 virt: {x}", .{pml4_virt});
    log.debug("hhdm offset: {x}", .{bootinfo.getBootInfo().hhdm_offset});

    // switches to our page tables
    asm volatile (
        \\mov %[pml4], %%cr3
        :
        : [pml4] "r" (pml4_phys),
        : .{ .memory = true });

    log.debug("Paging initialized", .{});
}
