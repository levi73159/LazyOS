const std = @import("std");
const mem = std.mem;

const root = @import("root");
const pmem = root.pmem;
const SyscallFrame = root.arch.syscall.SyscallFrame;
const VirtualSpace = root.arch.VirtualSpace;
const proc = root.proc;

const errno = @import("errno.zig");

const log = std.log.scoped(._sysmem);

pub fn brk(frame: *SyscallFrame) i64 {
    const addr = std.mem.alignForward(usize, frame.rdi, root.PAGE_SIZE);

    const process = proc.scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (addr == 0) {
        return @intCast(process.brk_current);
    }

    if (addr < process.brk_base) {
        log.err("Invalid address: addr({x}) < brk_base({x})", .{ addr, process.brk_base });
        return errno.ENOMEM;
    }

    const old_break = process.brk_current;

    const vmem = &process.vmem;
    const mem_size: isize = @as(isize, @intCast(addr)) - @as(isize, @intCast(old_break)); // how much memory to add
    const pages: usize = (@as(usize, @abs(mem_size)) + root.PAGE_SIZE - 1) / root.PAGE_SIZE; // how many pages to alloc/dealloc if mem_size is positive/negative
    if (mem_size > 0) {
        // alloc path
        const phys = pmem.user().allocPages(pages) catch {
            return errno.ENOMEM;
        };

        // assumes range brk_base to brk_current is already mapped so it only maps brk_current to add4
        vmem.mapRange(old_break, phys, pages * root.PAGE_SIZE, .{ .present = true, .user = true, .writeable = true });
        vmem.addGuardPage(root.heap.allocator(), "brk start", addr + root.PAGE_SIZE);
        vmem.addRegion2(root.heap.allocator(), "user brk", process.brk_base, addr);
    } else {
        // dealloc path
        const start_virt = addr;

        for (0..pages) |i| {
            const virt = start_virt + (i * root.PAGE_SIZE);
            const phys = vmem.getPhys(virt, true) orelse {
                // here just in case but it should never happen since we or deallocating only mapped pages, (only happens if somthing gets currupted or very wrong)
                // may be smarter to just do `.?`
                @branchHint(.cold);
                log.warn("Virtual address not mapped: {x}", .{virt});
                continue;
            };

            pmem.user().freePage(phys); // we don't do freePages since it may not be contiguous
        }

        vmem.unmapRange(start_virt, pages * root.PAGE_SIZE); // unmap the range
    }

    process.brk_current = addr;

    return @intCast(addr);
}

pub fn mmap(frame: *SyscallFrame) i64 {
    const addr = frame.rdi;
    const len = frame.rsi;
    const prot = frame.rdx;
    const flags = frame.r10;
    const fd = frame.r8;
    const offset = frame.r9;

    _ = fd;
    _ = offset;

    const MAP_ANONYMOUS = 0x20;
    const MAP_SHARED = 0x02;
    _ = MAP_SHARED; // autofix

    const PROT_NONE = 0x0; // — no access
    const PROT_READ = 0x1; // — readable
    _ = PROT_READ; // autofix
    const PROT_WRITE = 0x2; // — writable
    const PROT_EXEC = 0x4; // — executable

    if (flags & MAP_ANONYMOUS == 0) {
        log.err("Only MAP_ANONYMOUS is supported", .{});
        return errno.ENOSYS;
    }

    const process = proc.scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    const vmem = &process.vmem;

    const size = mem.alignForward(usize, len, root.PAGE_SIZE);

    const va: usize = if (addr == 0) blk: {
        process.mmap_current -= size; // mmap grows downards (mimics stack, linux does the same)
        const va = process.mmap_current;
        break :blk va;
    } else addr;

    if (prot == PROT_NONE) {
        log.warn("Prot NONE reseveration, ignoring", .{});
        return @bitCast(va);
    }

    const page_flags = VirtualSpace.PageFlags{
        .present = true,
        .user = true,
        .writeable = prot & PROT_WRITE != 0,
        .execute_disable = prot & PROT_EXEC == 0,
    };
    const MAP_FIXED = 0x10;

    var i: u64 = 0;
    while (i < size) : (i += root.PAGE_SIZE) {
        // mamp doesn't have to be physically contiguous so we just alloc one page at a time
        // TODO: add support for lazy mappings (map page, but doesn't allocate physical page until page fault)
        if (flags & MAP_FIXED != 0) {
            if (vmem.getPhys(va + i, true)) |old_phys| {
                pmem.user().freePage(old_phys);
            }
        }

        const phys = pmem.user().allocPage() catch {
            return errno.ENOMEM;
        };

        vmem.mapPage(va + i, phys, page_flags);
    }

    return @bitCast(va);
}

pub fn munmap(frame: *SyscallFrame) i64 {
    const addr = frame.rdi;
    const len = frame.rsi;

    const process = proc.scheduler.getCurrentProcess() orelse {
        @branchHint(.cold);
        log.err("No current process", .{});
        return errno.EAGAIN;
    };

    const vmem = &process.vmem;

    const size = mem.alignForward(usize, len, root.PAGE_SIZE);

    var i: u64 = 0;
    while (i < size) : (i += root.PAGE_SIZE) {
        const va = addr + i;
        if (vmem.getPhys(va, true)) |phys| {
            pmem.user().freePage(phys);
            vmem.unmapPage(va);
        }
    }

    return 0;
}
