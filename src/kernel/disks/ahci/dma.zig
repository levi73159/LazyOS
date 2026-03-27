pub const FisType = @import("fis.zig").FisType;

pub const Setup = packed struct {
    fis_type: FisType = .dma_setup,

    port_multiplier: u4 = 0, // Port multiplier
    __reserved: u1,
    device_to_host: bool = false, // true = device to host
    interrupt: bool = false,
    auto_active: bool = false,

    __reserved2: u16,
    buffer_id: u64,
    __reserved3: u32 = 0,
    buffer_offset: u32, // first 2 bits must be zero
    transfer_count: u32, // number of bytes to transfer (bit 0 must be 0)
    __reserved4: u32 = 0,
};
