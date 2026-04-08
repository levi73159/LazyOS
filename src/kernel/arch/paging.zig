const std = @import("std");
const arch = @import("../arch.zig");
const bootinfo = @import("bootinfo.zig");
const pmem = @import("../memory/pmem.zig");
const VirtualSpace = @import("VirtualSpace.zig");
const scheduler = @import("../scheduler.zig");

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
    while (offset < size) : (offset += VirtualSpace.HUGE_PAGE_SIZE) {
        vmem.mapHugePage(virt + offset, phys + offset, .{
            .present = true,
            .write_through = false,
            .cache_disabled = false,
            .pat = true,
            .writeable = true,
            .execute_disable = true,
        });
    }

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

pub const ErrorCode = packed struct(u32) {
    present: u1, // bit 0
    write: u1, // bit 1
    user: u1, // bit 2
    reserved_write: u1, // bit 3
    instruction_fetch: u1, // bit 4
    protection_key: u1, // bit 5
    shadow_stack: u1, // bit 6
    _reserved0: u8, // bits 7–14
    sgx: u1, // bit 15
    _reserved1: u16, // bits 16–31
};

pub fn pageFaultHandler(frame: *arch.registers.InterruptFrame) void {
    const console = @import("../console.zig");
    const gdt = @import("descriptors.zig").gdt;
    console.printB("\x1b[97;41m", .{});
    console.printB("!!! PAGE FAULT EXCEPTION !!!\n", .{});

    const cs_enum: gdt.Segment = @enumFromInt(frame.cs);
    const ds_enum: gdt.Segment = @enumFromInt(frame.ds);

    console.printB("cs: {s}, ds: {s}\n", .{ @tagName(cs_enum), @tagName(ds_enum) });
    const address = asm volatile ("mov %%cr2, %[addr]\n"
        : [addr] "=r" (-> u64),
    );

    console.printB("Invalid Page fault at address: 0x{x}\n", .{address});
    const error_code: ErrorCode = @bitCast(@as(u32, @truncate(frame.error_code))); // ignore upper bits

    const vmem: ?VirtualSpace = if (ds_enum == .kernel_data) kernel_vmem else blk: {
        const process = scheduler.getCurrentTask().process orelse break :blk null;
        break :blk process.vmem;
    };
    if (vmem) |v| blk: {
        const guard = v.getGuardPage(address) orelse break :blk;
        console.printB("Guard Page accessed: {s}", .{guard.name});
    } else {
        console.printB("Can't get virtual memory of process...", .{});
    }

    console.printB("Present: {}\n", .{error_code.present});
    console.printB("Write: {}\n", .{error_code.write});
    console.printB("User: {}\n", .{error_code.user});
    console.printB("Instruction fetch: {}\n", .{error_code.instruction_fetch});
    console.printB("Protection key: {}\n", .{error_code.protection_key});
    console.printB("Shadow stack: {}\n", .{error_code.shadow_stack});
    console.printB("SGX: {}\n", .{error_code.sgx});

    console.printB("Frame: \n", .{});
    console.printB("{f}\n", .{frame});

    @panic("Unhandled exception");
}
