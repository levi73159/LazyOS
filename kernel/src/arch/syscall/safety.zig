const root = @import("root");
const std = @import("std");

pub const UserAccess = enum { read, write };

pub fn validateUserRange(addr: usize, len: usize, access: UserAccess) bool {
    const USER_SPACE_END: usize = 0x0000_8000_0000_0000;
    if (len == 0) return true;

    if (addr == 0) return false;
    if (addr >= USER_SPACE_END) return false;
    if (len > USER_SPACE_END - addr) return false;

    const lastaddr = addr + len - 1;
    var page = std.mem.alignBackward(usize, addr, root.PAGE_SIZE);
    const lastPage = std.mem.alignBackward(usize, lastaddr, root.PAGE_SIZE);

    const current_process = root.proc.scheduler.getCurrentProcess().?;
    const vmem = &current_process.vmem;
    while (true) : (page += root.PAGE_SIZE) {
        _ = vmem.get(page, true, access == .write) orelse return false; // no mapping exist return false

        if (page == lastPage) break;
    }

    return true;
}
