pub const CommandHeader = packed struct {
    fis_len: u5,
    atapi: bool,
    write: bool, // false = read (device -> host), true = write (host -> device)
    prefetchable: bool,

    reset: bool,
    bist: bool,
    clear: bool, // clear busy upon R_OK
    __reserved0: bool,
    port_multiplier: u4,

    prdtl: u16,
    prdbc: u32,

    command_table_base: u64,

    __reserved1: u128,
};

pub const PrdtEntry = packed struct {
    data_base: u64,
    __reserved: u32 = 0,

    // dw3
    byte_count: u22,
    __reserved2: u9 = 0,
    interrupt_on_completion: bool,
};

pub const CommandTable = extern struct {
    cmd_fis: [64]u8,
    atapi_cmd: [16]u8,
    reserved: [48]u8,
    // 0x80 prdt entry is right after this in memory 0 ~ 65535

    pub fn prdtSlice(self: *CommandTable, count: u16) []PrdtEntry {
        const base: [*]PrdtEntry = @ptrFromInt(@intFromPtr(self) + @sizeOf(CommandTable));
        return base[0..count];
    }
};
