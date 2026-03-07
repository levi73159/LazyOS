pub const PAGE_SIZE = 4096;
const HUGE_SIZE = 2 * 1024 * 1024;

const KERNEL_BASE = 0xffffffff80000000;

const Entry = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge: bool = false,
    global: bool = false,
    _ignored: u3 = 0,
    addr: u40 = 0,
    _reserved: u11 = 0,
    nx: bool = false,

    pub fn set(self: *Entry, phys: u64, flags: u64) void {
        self.* = @bitCast((phys & 0x000ffffffffff000) | flags);
    }
};

var pml4 align(PAGE_SIZE) = [_]Entry{.{}} ** 512;
var pdpt align(PAGE_SIZE) = [_]Entry{.{}} ** 512;
var pd align(PAGE_SIZE) = [_]Entry{.{}} ** 512;

pub fn setupPaging(kernel_phys_start: u64, kernel_phys_end: u64, offset: u64) void {
    // Clear tables
    @memset(&pml4, .{});
    @memset(&pdpt, .{});
    @memset(&pd, .{});

    // Link tables
    pml4[511].set(@intFromPtr(&pdpt) - offset, 0x3); // present + writable
    pdpt[510].set(@intFromPtr(&pd) - offset, 0x3);

    // Identity map first 1GiB using huge pages
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        pd[i].set(@as(u64, i) * HUGE_SIZE, 0x83);
    }

    // Map kernel higher-half using huge pages
    var phys = kernel_phys_start & ~(@as(u64, HUGE_SIZE - 1));
    var virt: u64 = KERNEL_BASE;

    while (phys < kernel_phys_end) : ({
        phys += HUGE_SIZE;
        virt += HUGE_SIZE;
    }) {
        const index = (virt >> 21) & 0x1ff;
        pd[index].set(phys, 0x83);
    }

    enablePaging(@intFromPtr(&pml4) - offset);
}

fn enablePaging(pml4_phys: u64) void {
    asm volatile (
        \\ mov %%cr4, %%rax
        \\ mov $0x20, %%rbx
        \\ or  %%rbx, %%rax
        \\ mov %%rax, %%cr4
        \\ mov %[pml4], %%cr3
        \\ mov %%cr0, %%rax
        \\ mov $0x80000000, %%rbx
        \\ or  %%rbx, %%rax
        \\ mov %%rax, %%cr0
        :
        : [pml4] "r" (pml4_phys),
        : .{ .rax = true, .rbx = true, .memory = true });
}

pub fn mapPage(virt: u64, phys: u64) void {
    // Extract indices
    const pml4_index = (virt >> 39) & 0x1ff;
    const pdpt_index = (virt >> 30) & 0x1ff;
    const pd_index = (virt >> 21) & 0x1ff;

    // Ensure PDPT and PD entries exist (you can extend this for real PT)
    if (pml4[pml4_index].present == false)
        pml4[pml4_index].set(@intFromPtr(&pdpt), 0x3); // Present + Writable

    if (pdpt[pdpt_index].present == false)
        pdpt[pdpt_index].set(@intFromPtr(&pd), 0x3); // Present + Writable

    // Map the page in PD (4 KiB, so PT needed)
    // For now, we’ll use the PD as PT to keep it simple (identity mapping small kernel)
    pd[pd_index].set(phys, 0x3); // Present + Writable
}
