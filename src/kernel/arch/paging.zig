const std = @import("std");
const root = @import("root");
const arch = root.arch;
const bootinfo = @import("bootinfo.zig");
const pmem = root.pmem;
const VirtualSpace = @import("VirtualSpace.zig");
const io = @import("io.zig");
const heap = root.heap;
const acpi = root.acpi;

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

const FRAMEBUFFER_BASE = 0xFFFF_C000_0000_0000;

fn mapFramebuffer(vmem: *VirtualSpace, fb: bootinfo.Framebuffer) void {
    const size = fb.width * fb.height * fb.bpp / 8;
    const phys = bootinfo.toPhysicalHHDM(fb.address);
    const virt = FRAMEBUFFER_BASE;

    var offset: u64 = 0;
    const flags = PageFlags{
        .present = true,
        .write_through = false,
        .cache_disabled = false,
        .pat = true,
        .writeable = true,
        .execute_disable = true,
    };
    while (offset < size) : (offset += VirtualSpace.HUGE_PAGE_SIZE) {
        vmem.mapHugePage(virt + offset, phys + offset, flags);
    }
    vmem.addRegion2(heap.allocator(), "Framebuffer", virt - 4096, virt + offset + 4096);

    // update screen
    const Screen = @import("../graphics/Screen.zig");
    const screen = Screen.get();
    screen.updateBuffer(virt);
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
    addKernelRegions(&kernel_vmem, mb.kernel.virt_addr, mb.kernel.size);

    mapFramebuffer(&kernel_vmem, mb.framebuffer);

    kernel_vmem.switchTo();

    @import("isr.zig").register(14, &pageFaultHandler);
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

fn addKernelRegions(vmem: *VirtualSpace, start: usize, size: usize) void {
    const allocator = heap.allocator();
    const boot = @import("root");

    const text_start = @intFromPtr(&__text_start);
    const text_end = @intFromPtr(&__text_end);
    const data_start = @intFromPtr(&__data_start);
    const data_end = @intFromPtr(&__data_end);
    const bss_start = @intFromPtr(&__bss_start);
    const bss_end = @intFromPtr(&__bss_end);
    const rodata_start = @intFromPtr(&__rodata_start);
    const rodata_end = @intFromPtr(&__rodata_end);

    vmem.addRegion(allocator, "Kernel Stack", @intFromPtr(&boot.kernel_stack), boot.KERNEL_STACK_SIZE);
    vmem.addRegion2(allocator, "Kernel .text", text_start, text_end);
    vmem.addRegion2(allocator, "Kernel .data", data_start, data_end);
    vmem.addRegion2(allocator, "Kernel .bss", bss_start, bss_end);
    vmem.addRegion2(allocator, "Kernel .rodata", rodata_start, rodata_end);
    vmem.addRegion(allocator, "Kernel data/code unmapped", start, size);
}

pub fn getPageTable(table: *VirtualSpace.PageTable, index: u9) ?*VirtualSpace.PageTable {
    const entry = &table[index];
    if (!entry.present) return null;

    return @ptrFromInt(bootinfo.toVirtualHHDM(entry.getAddress()));
}

pub fn getKernelVmem() *VirtualSpace {
    return &kernel_vmem;
}

pub fn createUserVmem() VirtualSpace {
    var vmem = VirtualSpace.init();

    // copy kernel mappnig into user vmem
    for (256..512) |i| {
        vmem.pml4[i] = kernel_vmem.pml4[i];
    }

    vmem.regions.appendSlice(heap.allocator(), kernel_vmem.regions.items) catch {};

    return vmem;
}

pub const ErrorCode = packed struct(u32) {
    present: bool, // bit 0
    write: bool, // bit 1
    user: bool, // bit 2
    reserved_write: bool, // bit 3
    instruction_fetch: bool, // bit 4
    protection_key: bool, // bit 5
    shadow_stack: bool, // bit 6
    _reserved0: u8, // bits 7–14
    sgx: bool, // bit 15
    _reserved1: u16, // bits 16–31
};

pub fn pageFaultHandler(frame: *arch.registers.InterruptFrame) void {
    const console = root.console;

    const error_code: ErrorCode = @bitCast(@as(u32, @truncate(frame.error_code))); // ignore upper bits
    const address = asm volatile ("mov %%cr2, %[addr]\n"
        : [addr] "=r" (-> u64),
    );

    console.printB("\x1b[97;41m", .{});

    const vmem = getVmem(error_code.user);
    const guard_page = vmem.getGuardPage(address);
    const spacer = if (guard_page != null) " | guard page: " else "";

    const region = vmem.findRegion(address);

    console.printB(
        \\ ====================PAGE FAULT====================
        \\ Type:   {s}
        \\ Reason: {s}{s}{s}
        \\ Addr:   0x{x}
        \\ RIP:    0x{x}
        \\
    , .{
        faultType(error_code),
        describeFault(error_code),
        spacer,
        if (guard_page) |page| page.name else "",
        address,
        frame.rip,
    });
    console.printB(
        " Flags:  [{s}{s}{s}{s}{s}{s}{s}]\n",
        .{
            if (error_code.present) "P" else "-",
            if (error_code.write) "W" else "R",
            if (error_code.user) "U" else "K",
            if (error_code.instruction_fetch) "I" else "-",
            if (error_code.reserved_write) "Rsv" else "-",
            if (error_code.protection_key) "PK" else "-",
            if (error_code.shadow_stack) "SS" else "-",
        },
    );

    if (region) |r| {
        console.printB(" Region: {s} (0x{x} - 0x{x})\n", .{ r.name, r.start, r.end });
    } else {
        console.printB(" Region: <unmapped>\n", .{});
    }

    if (address == 0) {
        console.printB("Hint: NULL pointer dereference\n", .{});
    } else if (address < 0x1000) {
        console.printB("Hint: low memory access (likely NULL offset)\n", .{});
    }

    console.printB(" ==================================================\n", .{});

    console.printB("Frame:\n", .{});
    console.printB("{f}\n", .{frame});

    console.printB("\x1b[0m", .{});

    if (error_code.user) {
        root.proc.scheduler.taskExit(255);
    } else {
        console.printB("Rebooting...\n", .{});
        acpi.reboot();
    }

    io.hlt();
}

fn faultType(err: ErrorCode) []const u8 {
    return if (err.user) "USER" else "KERNEL";
}

fn getVmem(user: bool) VirtualSpace {
    const vmem: ?VirtualSpace = if (!user) kernel_vmem else blk: {
        const process = root.proc.scheduler.getCurrentTask().process orelse break :blk null;
        break :blk process.vmem;
    };
    if (vmem == null) {
        log.err("can't get virtual address space", .{});
    }
    return vmem.?;
}

fn describeFault(err: ErrorCode) []const u8 {
    if (!err.present) {
        return "non-present page (null / unmapped)";
    }
    if (err.reserved_write) {
        return "reserved bit violation (corrupt page tables)";
    }
    if (err.instruction_fetch) {
        return "NX violation (execute on non-exec page)";
    }
    if (err.write) {
        return "write to read-only page";
    }
    return "read protection fault";
}
