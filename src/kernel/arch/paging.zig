const std = @import("std");
const bootinfo = @import("bootinfo.zig");
const pmem = @import("../memory/pmem.zig");
const VirtualSpace = @import("VirtualSpace.zig");

pub const PageFlags = VirtualSpace.PageFlags;

const log = std.log.scoped(.paging);

pub const PAGE_SIZE = 4096;

extern const __text_start: u8;
extern const __text_end: u8;
extern const __rodata_start: u8;
extern const __rodata_end: u8;
extern const __data_start: u8;
extern const __data_end: u8;
extern const __bss_start: u8;
extern const __bss_end: u8;

var kernel_vmem: VirtualSpace = undefined;

fn mapFramebuffer(vmem: *VirtualSpace, fb: bootinfo.Framebuffer) void {
    const size = fb.width * fb.height * fb.bpp / 8;
    const phys = bootinfo.toPhysicalHHDM(fb.address);
    const virt = fb.address;

    var offset: u64 = 0;
    while (offset < size) : (offset += PAGE_SIZE) {
        vmem.mapPage(virt + offset, phys + offset, .{
            .present = true,
            .write_through = false,
            .cache_disabled = false,
            .pat = true,
            .writeable = true,
            .execute_disable = true,
        });
    }
}

pub fn init(mb: *const bootinfo.BootInfo) *VirtualSpace {
    log.debug("Initializing paging", .{});

    kernel_vmem = .init();

    // map all physical memory at HHDM offset (so toVirtual keeps working and this code still works)
    var highest_address: u64 = 0;
    for (mb.memory_map) |entry| {
        highest_address = @max(highest_address, entry.base + entry.length);
    }
    const total_memory = highest_address;
    log.debug("Total memory: {x}", .{total_memory});
    // replace the 4KB HHDM loop with this
    var phys: u64 = 0;
    while (phys < total_memory) : (phys += VirtualSpace.HUGE_PAGE_SIZE) {
        kernel_vmem.mapHugePage(bootinfo.toVirtualHHDM(phys), phys, .rw);
    }

    log.debug("kernel virt range: {x} - {x}", .{ mb.kernel.virt_addr, mb.kernel.virt_addr + mb.kernel.size });

    log.debug("bss: {x} - {x}", .{ @intFromPtr(&__bss_start), @intFromPtr(&__bss_end) });

    // map kernel
    var offset: u64 = 0;
    while (offset < mb.kernel.size) : (offset += PAGE_SIZE) {
        const virt = mb.kernel.virt_addr + offset;
        const physical = mb.kernel.phys_addr + offset;
        const flags = getKernelFlags(virt);
        kernel_vmem.mapPage(virt, physical, flags);
    }

    mapFramebuffer(&kernel_vmem, mb.framebuffer);

    kernel_vmem.switchTo();

    log.debug("Paging initialized", .{});

    return &kernel_vmem;
}

fn getKernelFlags(virt: u64) VirtualSpace.PageFlags {
    const text_start = @intFromPtr(&__text_start);
    const text_end = @intFromPtr(&__text_end);
    const data_start = @intFromPtr(&__data_start);
    const data_end = @intFromPtr(&__data_end);
    const bss_start = @intFromPtr(&__bss_start);
    const bss_end = @intFromPtr(&__bss_end);
    const rodata_start = @intFromPtr(&__rodata_start);
    const rodata_end = @intFromPtr(&__rodata_end);

    if (virt >= text_start and virt < text_end)
        return .{ .present = true, .writeable = false, .execute_disable = false }
    else if (virt >= data_start and virt < data_end)
        return .{ .present = true, .writeable = true, .execute_disable = true }
    else if (virt >= bss_start and virt < bss_end)
        return .{ .present = true, .writeable = true, .execute_disable = true }
    else if (virt >= rodata_start and virt < rodata_end)
        return .{ .present = true, .writeable = false, .execute_disable = true }
    else
        return .rw;
}

pub fn getPageTable(table: *VirtualSpace.PageTable, index: u9) ?*VirtualSpace.PageTable {
    const entry = &table[index];
    if (!entry.present) return null;

    return @ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress()));
}

pub fn getKernelVmem() *const VirtualSpace {
    return &kernel_vmem;
}

pub fn createUserVmem() VirtualSpace {
    const vmem = VirtualSpace.init();

    // copy kernel mappnig into user vmem
    for (256..512) |i| {
        vmem.pml4[i] = kernel_vmem.pml4[i];
    }

    return vmem;
}
