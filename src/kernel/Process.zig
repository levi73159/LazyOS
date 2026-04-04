const std = @import("std");
const elf = std.elf;
const paging = @import("arch/paging.zig");
const pmem = @import("memory/pmem.zig");
const bootinfo = @import("arch/bootinfo.zig");
const VirtualSpace = @import("arch/VirtualSpace.zig");

const log = std.log.scoped(.process);

pub const USER_STACK_TOP = 0x00007FFFFFFFE000;
pub const USER_STACK_SIZE = 1024 * 1024; // 1MB

const Self = @This();

const MemoryRegion = struct {
    phys: u64,
    page_count: u64,
};

entry: u64,
stack_top: u64,
vmem: VirtualSpace,
fs_base: u64 = 0,

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

    const vmem = paging.createUserVmem();

    var tls_vaddr: u64 = 0;
    var tls_filesz: u64 = 0;
    var tls_memsz: u64 = 0;
    var tls_align: u64 = 0;

    var ph_iter = header.iterateProgramHeadersBuffer(data);
    while (try ph_iter.next()) |ph| {
        switch (ph.p_type) {
            elf.PT_LOAD => try ptLoad(allocator, ph, data, &regions, &vmem),
            elf.PT_TLS => {
                tls_vaddr = ph.p_vaddr;
                tls_filesz = ph.p_filesz;
                tls_memsz = ph.p_memsz;
                tls_align = ph.p_align;
                log.debug("TLS: vaddr={x}, filesz={x}, memsz={x}, align={x}", .{ tls_vaddr, tls_filesz, tls_memsz, tls_align });
            },
            else => {},
        }
    }

    var fs_base_user: u64 = 0;
    if (tls_memsz > 0) {
        const tls_size = std.mem.alignForward(u64, tls_memsz + 8, tls_align);
        const tls_pages = (tls_size + paging.PAGE_SIZE - 1) / paging.PAGE_SIZE;
        const tls_phys = try pmem.kernel().allocPages(tls_pages);

        try regions.append(allocator, .{
            .page_count = tls_pages,
            .phys = tls_phys,
        });

        vmem.mapRange(tls_vaddr, tls_phys, tls_size, .{
            .present = true,
            .user = true,
            .writeable = true,
            .execute_disable = true,
        });

        const tls_hhdm: [*]u8 = @ptrFromInt(bootinfo.toVirtualHHDM(tls_phys));
        @memset(tls_hhdm[0..tls_size], 0);

        fs_base_user = tls_vaddr + tls_memsz;
        const fs_base_hhdm = bootinfo.toVirtualHHDM(tls_phys) + tls_memsz;

        @as(*u64, @ptrFromInt(fs_base_hhdm)).* = fs_base_user;
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

    const stack_top: u64 = bootinfo.toVirtualHHDM(stack_phys) + USER_STACK_SIZE;
    var sp: u64 = stack_top;

    // align
    sp &= ~@as(u64, 0xF);

    // push NULL (envp)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    // push NULL (argv terminator)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    // push argc = 0
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    const user_sp = USER_STACK_TOP - (stack_top - sp);

    // allocate memory for fs and gs base

    return Self{
        .entry = header.entry,
        .stack_top = user_sp,
        .regions = regions,
        .vmem = vmem,
        .fs_base = fs_base_user,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.regions.items) |region| {
        pmem.kernel().freePages(region.phys, region.page_count);
    }
    self.regions.deinit(allocator);

    self.vmem.safeDeinit();
}

fn ptLoad(allocator: std.mem.Allocator, ph: elf.Elf64_Phdr, data: []const u8, regions: *std.ArrayList(MemoryRegion), vmem: *const VirtualSpace) !void {
    if (ph.p_memsz == 0) return; // don't load it

    const aligned_vaddr = std.mem.alignBackward(u64, ph.p_vaddr, paging.PAGE_SIZE);
    const offset = ph.p_vaddr - aligned_vaddr;

    const total_size = std.mem.alignForward(
        u64,
        ph.p_memsz + offset,
        paging.PAGE_SIZE,
    );

    const pages = total_size / paging.PAGE_SIZE;
    const phys = try pmem.kernel().allocPages(pages);

    try regions.append(allocator, .{
        .phys = phys,
        .page_count = pages,
    });

    const virt = bootinfo.toVirtualHHDM(phys);
    const mem_ptr: [*]u8 = @ptrFromInt(virt);

    const memory = mem_ptr[0..total_size];

    @memset(memory, 0);

    if (ph.p_filesz > 0) {
        const src = data[ph.p_offset..][0..ph.p_filesz];
        @memcpy(memory[0..src.len], src);
    }

    log.debug("Mapped {d} bytes from {x} to {x}", .{ total_size, ph.p_vaddr, virt });
    log.debug("File size: {d}", .{ph.p_filesz});

    const flags = paging.PageFlags{
        .present = true,
        .user = true,
        .writeable = (ph.p_flags & elf.PF_W) != 0,
        .execute_disable = (ph.p_flags & elf.PF_X) == 0,
    };

    const user_virt = std.mem.alignBackward(u64, ph.p_vaddr, paging.PAGE_SIZE);
    vmem.mapRange(user_virt, phys, total_size, flags);
}
