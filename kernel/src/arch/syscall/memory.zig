const std = @import("std");
const mem = std.mem;

const root = @import("root");
const pmem = root.pmem;
const SyscallFrame = root.arch.syscall.SyscallFrame;
const VirtualSpace = root.arch.VirtualSpace;
const proc = root.proc;

const errno = @import("errno.zig");

const log = std.log.scoped(._sysmem);

// Allocate and zero all data frames before replacing any existing mapping.
// Reservations have ownership records too, but no physical allocation.
fn mapAnonymous(process: *proc.Process, addr: usize, size: usize, flags: VirtualSpace.PageFlags, kind: enum { mmap, brk }, replace: bool) !void {
    const allocator = root.heap.allocator();
    const pages = size / root.PAGE_SIZE;
    try process.anonymous_pages.ensureUnusedCapacity(allocator, pages);
    const frames = try allocator.alloc(?u64, pages);
    defer allocator.free(frames);
    @memset(frames, null);
    var committed = false;
    defer if (!committed) {
        for (frames) |frame| {
            if (frame) |phys| pmem.user().freePage(phys);
        }
    };

    if (flags.present) {
        for (frames) |*frame| {
            const phys = try pmem.user().allocPage();
            frame.* = phys;
            const ptr: [*]u8 = @ptrFromInt(root.arch.bootinfo.toVirtualHHDM(phys));
            @memset(ptr[0..root.PAGE_SIZE], 0);
        }
    }
    for (frames, 0..) |frame, i| {
        const virt = addr + i * root.PAGE_SIZE;
        if (replace) {
            if (process.anonymousPageIndex(virt)) |index| process.freeAnonymousPage(index);
        }
        if (frame) |phys| process.vmem.mapPage(virt, phys, flags);
        process.anonymous_pages.appendAssumeCapacity(.{
            .virt = virt,
            .phys = frame,
            .kind = if (kind == .mmap) .mmap else .brk,
        });
    }
    committed = true;
}

pub fn brk(frame: *SyscallFrame) i64 {
    const process = proc.scheduler.getCurrentProcess() orelse return errno.EAGAIN;
    if (frame.rdi == 0) return @intCast(process.brk_current);
    if (frame.rdi > std.math.maxInt(usize) - (root.PAGE_SIZE - 1)) return errno.ENOMEM;
    const addr = std.mem.alignForward(usize, frame.rdi, root.PAGE_SIZE);
    if (addr < process.brk_base or addr >= 0x0000_8000_0000_0000) return errno.ENOMEM;
    const old_break = process.brk_current;
    if (addr == old_break) return @intCast(addr);

    if (addr > old_break) {
        var virt = old_break;
        while (virt < addr) : (virt += root.PAGE_SIZE) {
            if (process.anonymousPageIndex(virt) != null or
                process.vmem.get(virt, false, false) != null or
                process.vmem.getGuardPage(virt) != null) return errno.ENOMEM;
        }
        mapAnonymous(process, old_break, addr - old_break, .user_rw, .brk, false) catch return errno.ENOMEM;
    } else {
        // Check every page before freeing any; never free a frame owned by
        // the ELF loader or an mmap request through this heap-shrink path.
        var virt = addr;
        while (virt < old_break) : (virt += root.PAGE_SIZE) {
            const index = process.anonymousPageIndex(virt) orelse return errno.EINVAL;
            if (process.anonymous_pages.items[index].kind != .brk) return errno.EINVAL;
        }
        virt = addr;
        while (virt < old_break) : (virt += root.PAGE_SIZE) {
            process.freeAnonymousPage(process.anonymousPageIndex(virt).?);
        }
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

    const MAP_ANONYMOUS = 0x20;
    const MAP_SHARED = 0x02;
    const MAP_FIXED = 0x10;
    _ = MAP_SHARED; // autofix

    const PROT_READ = 0x1; // — readable
    _ = PROT_READ; // autofix
    const PROT_WRITE = 0x2; // — writable
    const PROT_EXEC = 0x4; // — executable

    log.debug("Calling mmap with addr, len, prot, flags, fd, offset: {}, {}, {}, {}, {}, {}", .{ addr, len, prot, flags, fd, offset });

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

    const PAGE_SIZE = root.PAGE_SIZE;
    const USER_SPACE_END: usize = 0x0000_8000_0000_0000;

    if (len == 0) return errno.EINVAL; // len cannot be null/0

    // alignForward adds up to PAGE_SIZE - 1 so we do a bounds check.
    if (len > std.math.maxInt(usize) - (PAGE_SIZE - 1))
        return errno.ENOMEM;

    const size = std.mem.alignForward(usize, len, PAGE_SIZE);
    const fixed = flags & MAP_FIXED != 0;

    if (fixed and addr % PAGE_SIZE != 0) // fixed means can't round page size
        return errno.EINVAL;

    if (addr != 0 or fixed) {
        if (addr == 0 or addr >= USER_SPACE_END)
            return errno.EINVAL;

        if (size > USER_SPACE_END - addr)
            return errno.ENOMEM;
    }

    if (addr == 0 and !fixed) {
        if (process.mmap_current > USER_SPACE_END)
            return errno.ENOMEM;
        if (process.mmap_current <= PAGE_SIZE)
            return errno.ENOMEM;
        if (size > process.mmap_current - PAGE_SIZE)
            return errno.ENOMEM;
    }

    const va: usize = if (addr == 0 and !fixed) blk: {
        const va = process.mmap_current - size;
        break :blk va;
    } else std.mem.alignBackward(usize, addr, PAGE_SIZE);

    // Replacing an anonymous mmap page is supported. Loader pages,
    // brk pages, and guards must never be freed by this path.
    var check: usize = 0;
    while (check < size) : (check += PAGE_SIZE) {
        const virt = va + check;
        if (process.anonymousPageIndex(virt)) |index| {
            if (!fixed or process.anonymous_pages.items[index].kind != .mmap) return errno.ENOMEM;
        } else if (vmem.get(virt, false, false) != null or vmem.getGuardPage(virt) != null) {
            return errno.ENOMEM;
        }
    }

    const page_flags = VirtualSpace.PageFlags{
        .present = prot != 0,
        .user = true,
        .writeable = prot & PROT_WRITE != 0,
        .execute_disable = prot & PROT_EXEC == 0,
    };

    mapAnonymous(process, va, size, page_flags, .mmap, fixed) catch return errno.ENOMEM;
    if (addr == 0 and !fixed) process.mmap_current = va;

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

    const PAGE_SIZE = root.PAGE_SIZE;
    const USER_SPACE_END: usize = 0x0000_8000_0000_0000;
    if (addr % PAGE_SIZE != 0 or len == 0) return errno.EINVAL;
    if (len > std.math.maxInt(usize) - (PAGE_SIZE - 1)) return errno.EINVAL;
    const size = mem.alignForward(usize, len, PAGE_SIZE);
    if (addr >= USER_SPACE_END or size > USER_SPACE_END - addr) return errno.EINVAL;

    // Preflight the entire range so a rejected request makes no changes.
    var offset: usize = 0;
    while (offset < size) : (offset += PAGE_SIZE) {
        const virt = addr + offset;
        if (process.anonymousPageIndex(virt)) |index| {
            if (process.anonymous_pages.items[index].kind != .mmap) return errno.EINVAL;
        } else if (process.vmem.get(virt, false, false) != null or process.vmem.getGuardPage(virt) != null) {
            return errno.EINVAL;
        }
    }
    // Unmapped holes are harmless. Only recorded mmap allocations are freed.
    var i: usize = 0;
    while (i < process.anonymous_pages.items.len) {
        const page = process.anonymous_pages.items[i];
        if (page.virt >= addr and page.virt - addr < size) {
            process.freeAnonymousPage(i);
        } else i += 1;
    }
    return 0;
}
