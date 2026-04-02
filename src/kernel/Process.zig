const std = @import("std");
const elf = std.elf;
const paging = @import("arch/paging.zig");
const pmem = @import("memory/pmem.zig");
const bootinfo = @import("arch/bootinfo.zig");

const log = std.log.scoped(.process);

pub const USER_STACK_TOP = 0x00007FFFFFFFE000;
pub const USER_STACK_SIZE = 64 * 1024; // 64kb

const Self = @This();

const MemoryRegion = struct {
    phys: u64,
    page_count: u64,
};

entry: u64,
stack_top: u64,
// TODO: cr3 coming soon

regions: std.ArrayList(MemoryRegion),

pub fn loadElf(data: []const u8, allocator: std.mem.Allocator) !Self {
    var reader: std.Io.Reader = std.Io.Reader.fixed(data);
    const header = try elf.Header.read(&reader);

    var regions = try std.ArrayList(MemoryRegion).initCapacity(allocator, 3); // we know there will be at least 3 (code, data, stack)
    errdefer regions.deinit(allocator);

    if (header.machine != .X86_64) {
        log.err("Unsupported machine type: {s}", .{@tagName(header.machine)});
        return error.UnsupportedMachineType;
    }

    if (!header.is_64) return error.Not64Bit;

    const vmem = paging.getKernelVmem();

    var ph_iter = header.iterateProgramHeadersBuffer(data);
    while (try ph_iter.next()) |ph| {
        if (ph.p_type != elf.PT_LOAD) continue; // don't load it
        if (ph.p_memsz == 0) continue; // don't load it

        const bytes = std.mem.alignForward(u64, ph.p_memsz, paging.PAGE_SIZE);
        const pages = bytes / paging.PAGE_SIZE;
        const phys = try pmem.kernel().allocPages(pages);

        try regions.append(allocator, .{
            .phys = phys,
            .page_count = pages,
        });

        const virt = bootinfo.toVirtualHHDM(phys);
        const mem_ptr: [*]u8 = @ptrFromInt(virt);

        const memory = mem_ptr[0..bytes];

        @memset(memory, 0);

        if (ph.p_filesz > 0) {
            const src = data[ph.p_offset..][0..ph.p_filesz];
            @memcpy(memory[0..src.len], src);
        }

        log.debug("Mapped {d} bytes from {x} to {x}", .{ bytes, ph.p_vaddr, virt });
        log.debug("File size: {d}", .{ph.p_filesz});

        const flags = paging.PageFlags{
            .present = true,
            .user = true,
            .writeable = (ph.p_flags & elf.PF_W) != 0,
            .execute_disable = (ph.p_flags & elf.PF_X) == 0,
        };

        const user_virt = std.mem.alignBackward(u64, ph.p_vaddr, paging.PAGE_SIZE);
        vmem.mapRange(user_virt, phys, bytes, flags);
    }

    const stack_pages = (USER_STACK_SIZE + paging.PAGE_SIZE - 1) / paging.PAGE_SIZE;
    const stack_phys = try pmem.kernel().allocPages(stack_pages);

    try regions.append(allocator, .{
        .phys = stack_phys,
        .page_count = stack_pages,
    });

    const stack_bottom = USER_STACK_TOP - USER_STACK_SIZE;

    vmem.mapRange(stack_bottom, stack_phys, USER_STACK_SIZE, .{ .present = true, .user = true, .writeable = true, .execute_disable = true });

    log.debug("Mapped stack from {x} to {x}", .{ stack_bottom, USER_STACK_TOP });
    log.debug("Entry point: {x}", .{header.entry});

    return Self{
        .entry = header.entry,
        .stack_top = USER_STACK_TOP,
        .regions = regions,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.regions.items) |region| {
        pmem.kernel().freePages(region.phys, region.page_count);
    }
    self.regions.deinit(allocator);
}
