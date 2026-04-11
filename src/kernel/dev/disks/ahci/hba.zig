pub const dma = @import("dma.zig");
pub const fis = @import("fis.zig");

pub const PxCMD_ST: u32 = 0x0001; // start
pub const PxCMD_FRE: u32 = 0x0010; // fis recive enable
pub const PxCMD_FR: u32 = 0x4000; // fis recive running
pub const PxCMD_CR: u32 = 0x8000; // command list running
pub const PxIS_TFES: u32 = 1 << 30; // task file error

pub const PORT_IPM_ACTIVE = 1;
pub const PORT_DET_PRESENT = 3;

pub const Port = extern struct {
    cmd_list_base: u64,
    fis_base: u64,
    int_status: u32, // 0x10, interrupt status
    int_enable: u32, // 0x14, interrupt enable
    cmd: u32, // 0x18, command and status
    __reserved0: u32, // 0x1C
    task_file_data: u32, // 0x20, task file data
    sig: u32, // 0x24, signature
    sata_status: u32, // 0x28, SATA status
    sata_control: u32, // 0x2C, SATA control
    sata_error: u32, // 0x30, SATA error
    sata_active: u32, // 0x34, SATA active
    cmd_issue: u32, // 0x38, command issue
    sata_note: u32, // 0x3C, SATA notification
    fis_switch: u32, // 0x40, FIS-based switch control
    __reserved1: [11]u32, // 0x44 ~ 0x6F
    vendor: [4]u32, // 0x70 ~ 0x7F
};

pub const Mem = extern struct {
    host_cap: Capability, // 0x00, host capability
    global_host_ctl: GlobalHostCtl, // 0x04, global host control
    int_status: u32, // 0x08, interrupt status
    port_impl: u32, // 0x0C, ports implemented
    version: u32, // 0x10, version
    ccc_ctl: u32, // 0x14, command completion coalescing control
    ccc_ports: u32, // 0x18, command completion coalescing ports
    em_loc: u32, // 0x1C, enclosure management location
    em_ctl: u32, // 0x20, enclosure management control
    host_cap_extended: CapabilityExtended, // 0x24, host capabilities extended
    bohc: BiosOSHandOffControl, // 0x28, BIOS/OS handoff control and status
    __reserved: [0xA0 - 0x2C]u8, // 0x2C - 0x9F
    vendor: [0x100 - 0xA0]u8, // 0xA0 - 0xFF
    ports: [32]Port, // 0x100 - 0x10FF

    // was used before added the Capability packed struct
    pub inline fn numSlots(self: *volatile Mem) u8 {
        return self.host_cap.number_of_slots;
    }
};

pub const GlobalHostCtl = packed struct(u32) {
    hba_reset: bool,
    int_enable: bool,
    mrsm: bool, // MSI Revert to Single Message
    __reserved: u28,
    ahci_enable: bool,
};

pub const BiosOSHandOffControl = packed struct(u32) {
    bios_owned: bool,
    os_owned: bool,
    /// SMI on OS Ownership Change Enable (SOOE): This bit, when set to ‘1’, enables an SMI when the OOC bit has been set to ‘1’.
    sooe: bool,
    os_ownership_changed: bool,
    bios_busy: bool,
    __reserved: u27,
};

pub const Capability = packed struct(u32) {
    number_of_ports: u5,
    external_sata: bool,
    enclosure_management: bool,
    command_completion_coalescing: bool,
    number_of_slots: u5,
    partial_state_capable: bool,
    slumber_state_capable: bool,
    pio_multiple_drq_block: bool,
    fis_based_switching: bool,
    port_multiplier: bool,
    ahci_mode_only: bool,
    __reserved: u1 = 0,
    interface_speed: InterfaceSpeeds,
    command_list_override: bool,
    activity_led: bool,
    /// Name was to long, stands for "Supports Agrresive Link Power Management"
    salp: bool,
    staggered_spin_up: bool,
    mechinical_presence_switch: bool,
    snotify_reg_supported: bool,
    native_command_queueing: bool,
    dma_64adressable: bool,
};

pub const CapabilityExtended = packed struct(u32) {
    bios_os_handoff: bool,
    nvmhci_pressent: bool,
    /// Automatic Partial to Slumber Transition
    apst: bool,
    support_device_sleep: bool,
    aggressive_device_sleep_management: bool,
    devsleep_entrance_from_slumber: bool,
    __reserved: u26,
};

pub const InterfaceSpeeds = enum(u4) {
    @"1.5Gbps" = 1,
    @"3Gbps" = 2,
    @"6Gbps" = 3,
};

pub const Fis = extern struct {
    dma_setup: dma.Setup,
    __pad0: [4]u8,

    pio_setup: fis.PioSetup,
    __pad1: [12]u8,

    reg_d2h: fis.RegD2H,
    __pad2: [4]u8,

    dev_bits: u64,

    ufis: [64]u8,

    rsv: [0x100 - 0xA0]u8,
};
