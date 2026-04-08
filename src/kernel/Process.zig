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

    var vmem = paging.createUserVmem();

    var first_load_seen = false;
    var phdr_vaddr: u64 = 0;
    var first_load_mapped_addr: usize = 0;

    var ph_iter = header.iterateProgramHeadersBuffer(data);
    while (try ph_iter.next()) |ph| {
        switch (ph.p_type) {
            elf.PT_LOAD => {
                if (!first_load_seen) {
                    const mapped_virt = std.mem.alignBackward(u64, ph.p_vaddr, paging.PAGE_SIZE);
                    phdr_vaddr = ph.p_vaddr;
                    first_load_seen = true;
                    first_load_mapped_addr = mapped_virt;
                }
                try ptLoad(allocator, ph, data, &regions, &vmem);
            },
            else => {},
        }
    }

    const stack_pages = (USER_STACK_SIZE + paging.PAGE_SIZE - 1) / paging.PAGE_SIZE;
    const stack_phys = try pmem.kernel().allocPages(stack_pages);

    try regions.append(allocator, .{
        .phys = stack_phys,
        .page_count = stack_pages,
    });

    const stack_bottom = USER_STACK_TOP - USER_STACK_SIZE;

    vmem.mapRange(stack_bottom, stack_phys, USER_STACK_SIZE, .{ .present = true, .user = true, .writeable = true, .execute_disable = true });
    vmem.addRegion2(allocator, "user stack", stack_bottom, USER_STACK_TOP);
    vmem.addGuardPage(allocator, "user stack overflow", stack_bottom - 4096);

    const base = first_load_mapped_addr - phdr_vaddr;
    log.debug("Mapped stack from {x} to {x}", .{ stack_bottom, USER_STACK_TOP });
    log.debug("Entry point: {x}", .{header.entry});
    log.debug("Base: {x}", .{base});

    const user_sp = loadStack(stack_phys, ElfInfo{
        .entry = header.entry,
        .phdr_vaddr = phdr_vaddr,
        .phent = header.phentsize,
        .phnum = header.phnum,
        .interp_base = 0,
    });

    return Self{
        .entry = header.entry,
        .stack_top = user_sp,
        .regions = regions,
        .vmem = vmem,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.regions.items) |region| {
        pmem.kernel().freePages(region.phys, region.page_count);
    }
    self.regions.deinit(allocator);

    self.vmem.safeDeinit();
}

fn ptLoad(allocator: std.mem.Allocator, ph: elf.Elf64_Phdr, data: []const u8, regions: *std.ArrayList(MemoryRegion), vmem: *VirtualSpace) !void {
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
        // BUG: put this here on purpose so we can test page fault
        @memcpy(memory[0..src.len], src);
        // @memcpy(memory[offset..][0..src.len], src); // TODO: this is the correct way
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

    const section_name = switch (ph.p_flags) {
        elf.PF_X => "user text",
        elf.PF_W => "user data",
        else => "user rodata",
    };

    vmem.addRegion(allocator, section_name, user_virt, total_size);
}

const AT_NULL: u64 = 0;
const AT_PHDR: u64 = 3;
const AT_PHENT: u64 = 4;
const AT_PHNUM: u64 = 5;
const AT_PAGESZ: u64 = 6;
const AT_BASE: u64 = 7;
const AT_FLAGS: u64 = 8;
const AT_ENTRY: u64 = 9;
const AT_UID: u64 = 11;
const AT_EUID: u64 = 12;
const AT_GID: u64 = 13;
const AT_EGID: u64 = 14;
const AT_PLATFORM: u64 = 15;
const AT_SECURE: u64 = 23;
const AT_RANDOM: u64 = 25;

pub const ElfInfo = struct {
    phdr_vaddr: u64,
    phent: u64,
    phnum: u64,
    interp_base: u64,
    entry: u64,
};

fn loadStack(
    stack_phys: usize,
    info: ElfInfo,
) usize {
    const hhdm_base: usize = bootinfo.toVirtualHHDM(stack_phys);
    const hhdm_top: usize = hhdm_base + USER_STACK_SIZE;

    // the matching user virtual address will be USER_STACK_TOP - (stack_top - sp)
    // since (stack_top - sp) is the offset from the top of the stack to the stack pointer
    var sp = hhdm_top;

    const helpers = struct {
        fn pushU64(stack: *usize, val: u64) void {
            stack.* -= 8;
            @as(*u64, @ptrFromInt(stack.*)).* = val;
        }

        fn pushBytes(stack: *usize, bytes: []const u8) void {
            stack.* -= bytes.len;
            const dst: [*]u8 = @ptrFromInt(stack.*);
            @memcpy(dst[0..bytes.len], bytes);
        }

        fn toUser(top: u64, stack: u64) u64 {
            return USER_STACK_TOP - (top - stack);
        }
    };

    const pushU64 = helpers.pushU64;
    const pushBytes = helpers.pushBytes;
    const toUser = helpers.toUser;

    pushBytes(&sp, "x86_64\x00");
    const platform_addr = toUser(hhdm_top, sp);

    const random_data = [16]u8{
        0xbe, 0xba, 0xfe, 0xca, 0xef, 0xbe, 0xad, 0xde,
        0xef, 0xcd, 0xab, 0x90, 0x78, 0x56, 0x34, 0x12,
    };
    sp -= 16;
    @memcpy(@as([*]u8, @ptrFromInt(sp))[0..16], &random_data);
    const at_random_addr = toUser(hhdm_top, sp);

    sp &= ~@as(usize, 0xF); // align to 16

    pushU64(&sp, 0);
    pushU64(&sp, AT_NULL);

    pushU64(&sp, platform_addr);
    pushU64(&sp, AT_PLATFORM);

    pushU64(&sp, at_random_addr);
    pushU64(&sp, AT_RANDOM);

    pushU64(&sp, 0);
    pushU64(&sp, AT_SECURE);
    pushU64(&sp, 0);
    pushU64(&sp, AT_EGID);
    pushU64(&sp, 0);
    pushU64(&sp, AT_GID);
    pushU64(&sp, 0);
    pushU64(&sp, AT_EUID);
    pushU64(&sp, 0);
    pushU64(&sp, AT_UID);
    pushU64(&sp, info.entry);
    pushU64(&sp, AT_ENTRY);
    pushU64(&sp, 0);
    pushU64(&sp, AT_FLAGS);
    pushU64(&sp, info.interp_base);
    pushU64(&sp, AT_BASE);
    pushU64(&sp, info.phnum);
    pushU64(&sp, AT_PHNUM);
    pushU64(&sp, info.phent);
    pushU64(&sp, AT_PHENT);
    pushU64(&sp, info.phdr_vaddr);
    pushU64(&sp, AT_PHDR);
    pushU64(&sp, 4096);
    pushU64(&sp, AT_PAGESZ);

    pushU64(&sp, 0); // envp NULL terminator
    pushU64(&sp, 0); // argv NULL terminator
    pushU64(&sp, 0); // argc = 0

    return toUser(hhdm_top, sp);
}
