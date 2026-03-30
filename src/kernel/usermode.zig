const arch = @import("arch.zig");
const pmem = @import("memory/pmem.zig");

const USER_CODE_BASE = 0x400000;
const USER_STACK_TOP = 0x00007FFFFFFFE000;
const USER_STACK_SIZE = 2 * 1024 * 1024; // 2 MiB
