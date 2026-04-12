const std = @import("std");
const root = @import("root");
const pmem = root.pmem;
const SyscallFrame = root.arch.syscall.SyscallFrame;
const VirtualSpace = root.arch.VirtualSpace;
const proc = root.proc;

const errno = @import("errno.zig");

pub fn brk(frame: *SyscallFrame) i64 {
    const addr = std.mem.alignForward(usize, frame.rdi, root.PAGE_SIZE);

    const process = proc.scheduler.getCurrentProcess() orelse {
        std.log.err("No current process", .{});
        return errno.EAGAIN;
    };

    if (addr == 0) {
        return @intCast(process.brk_current);
    }

    if (addr < process.brk_base) {
        std.log.err("Invalid address: addr({x}) < brk_base({x})", .{ addr, process.brk_base });
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
            const phys = vmem.getPhys(virt) orelse {
                // here just in case but it should never happen since we or deallocating only mapped pages, (only happens if somthing gets currupted or very wrong)
                // may be smarter to just do `.?`
                @branchHint(.cold);
                std.log.warn("Virtual address not mapped: {x}", .{virt});
                continue;
            };

            pmem.user().freePage(phys); // we don't do freePages since it may not be contiguous
        }

        vmem.unmapRange(start_virt, pages * root.PAGE_SIZE); // unmap the range
    }

    process.brk_current = addr;

    return @intCast(addr);
}
