pub const FisType = enum(u8) {
    reg_h2d = 0x27, // Register FIS - host to device
    reg_d2h = 0x34, // Register FIS - device to host
    dma_act = 0x39, // DMA activate FIS - device to host
    dma_setup = 0x41, // DMA setup FIS - bidirectional
    data = 0x46, // Data FIS - bidirectional
    bist = 0x58, // BIST activate FIS - bidirectional
    pio_setup = 0x5F, // PIO setup FIS - device to host
    dev_bits = 0xA1, // Set device bits FIS - device to host
};

/// THE HOST TO DEVICE REGISTER FIS
pub const RegH2D = packed struct {
    // dword 0
    fis_type: FisType = .reg_h2d, // must be FisType.reg_h2d

    port_multiplier: u4 = 0, // Port multiplier
    __reserved: u3 = 0,
    c: enum(u1) { command = 1, control = 0 } = .control, // 1: Command, 0: Control
    command: u8 = 0, // command register
    feature_low: u8 = 0, // feature register, 7:0

    // dword 1
    lba_low: u24 = 0,
    device: u8 = 0,

    // dword 2
    lba_high: u24 = 0,
    feature_high: u8 = 0, // Feature register, 15:8

    // dword 3
    count: u16 = 0,
    icc: u8 = 0, // Isochronous command completion
    control: u8 = 0, // Control register

    // dword 4
    __reserved2: u32 = 0, // reserved
};

pub const RegD2H = packed struct {
    // dword 0
    fis_type: FisType = .reg_d2h,

    port_multiplier: u4 = 0, // Port multiplier
    __reserved: u2,
    intrerupt: bool,
    __reserved2: u1,

    status: u8,
    err: u8,

    // dword 1
    lba_low: u24,
    device: u8,

    // dword 2
    lba_high: u24,
    __reserved3: u8,

    // dword 3
    count_low: u8, // Count register, 7:0
    count_high: u8, // Count register, 15:8
    __reserved4: u16,

    // dword 4
    __reserved5: u32 = 0,
};

pub const Data = packed struct {
    // dword 0
    fis_type: FisType = .data,
    port_multiplier: u4 = 0, // Port multiplier
    __reserved: u4,

    __reserved2: u16,

    // dword 1 ~ N (data size can vary)
    // place directly in memory after this

    pub fn dataSlice(self: *Data, count: u16) []u32 {
        const base: [*]u32 = @ptrFromInt(@intFromPtr(self) + @sizeOf(Data));
        return base[0..count];
    }
};

pub const PioSetup = packed struct {
    // dword 0
    fis_type: FisType = .pio_setup,

    port_multiplier: u4 = 0, // Port multiplier
    __reserved: u1,
    device_to_host: bool = false, // true = device to host
    interrupt: bool = false,
    __reserved2: u1,

    status: u8,
    err: u8,

    // dword 1
    lba_low: u24,
    device: u8,

    // dword 2
    lba_high: u24,
    __reserved3: u8,

    // dword 3
    count: u16,
    __reserved4: u8,
    e_status: u8, // new value of status register

    // dword 4
    transfer_count: u16,
    __reserved5: u16,
};
