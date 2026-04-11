//! First we will do the safe way (will run on all recent hardware) aka the Configuration Space Access Mechanism #1
//! Then we will later add the Memory Mapped PCI Configureation Space
//! We won't worry about Access mechanism #2 for now since it is deprecated and only found on hardware around 1992
const std = @import("std");
const io = @import("root").io;

const log = std.log.scoped(._pci);

const CONFIG_ADDRESS = 0xcf8;
const CONFIG_DATA = 0xcfc;

const EMPTY_VENDOR = 0xffff;
const MULTI_FUNC = 0x80;

const SLOT_LIMIT = 32;
const FUNC_LIMIT = 8;

pub const ConfigAddress = packed struct(u32) {
    _zero: u2, // bits 1-0, always 0
    register_offset: u6, // bits 7-2
    function_number: u3, // bits 10-8
    device_number: u5, // bits 15-11
    bus_number: u8, // bits 23-16
    __reserved: u7, // bits 30-24
    enabled: bool, // bit 31
};

pub const Device = struct {
    vendor_id: u16,
    device_id: u16,
    status: u16,
    command: u16,
    class_code: ClassCode,
    subclass: u8,
    progif: u8,
    revision_id: u8,
    bist: u8,
    header_type: u8,
    latency_timer: u8,
    cache_line_size: u8,

    bar: [6]u32, // BAR for header_type 0x0 and 0x1, for header_type 0x2 we will ignore
    bar_count: u8,
};

pub const ClassCode = enum(u8) {
    unclassifed = 0,
    mass_storage = 0x01,
    network = 0x02,
    display = 0x03,
    multimedia = 0x04,
    memory = 0x05,
    bridge = 0x06,
    simple = 0x07,
    base_system = 0x08,
    input_device = 0x09,
    docking_station = 0x0a,
    processor = 0x0b,
    serial_bus = 0x0c,
    wireless = 0x0d,
    intelligent = 0x0e,
    satellite = 0x0f,
    wireless_display = 0x10,
    single_processor = 0x11,
    processing_accelerator = 0x12,
    // Non-Essential Instrumentation
    non_essential = 0x13,
    // 0x14 - 0x3f reserved
    coprocessor = 0x40,
    // 0x41 - 0xfe reserved
    unassigned = 0xff, // vendor specific
};

pub const FoundDevice = struct {
    bus: u8,
    slot: u8,
    func: u8,
    info: Device,
};

const DeviceList = struct {
    items: [256]FoundDevice,
    count: u8,

    // assumes that self.count will always be < self.items.len
    pub fn add(self: *DeviceList, found: FoundDevice) void {
        self.items[self.count] = found;
        self.count += 1;
    }
};

var devices: DeviceList = .{
    .items = undefined,
    .count = 0,
};

fn configRead32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const config_address = ConfigAddress{
        ._zero = 0,
        .register_offset = @truncate(offset >> 2),
        .function_number = @truncate(func),
        .device_number = @truncate(slot),
        .bus_number = @truncate(bus),
        .__reserved = 0,
        .enabled = true,
    };

    io.outl(CONFIG_ADDRESS, @bitCast(config_address));

    const data = io.inl(CONFIG_DATA);
    return data;
}

pub fn configRead(comptime T: type, bus: u8, slot: u8, func: u8, offset: u8) T {
    if (@typeInfo(T) != .int) {
        @compileError("Only integer types are supported");
    }

    const data = configRead32(bus, slot, func, offset);

    const int_info = @typeInfo(T).int;
    return switch (int_info.bits) {
        8 => @truncate(data >> (@as(u5, @truncate(offset & 3)) * 8)),
        16 => @truncate(data >> (@as(u5, @truncate(offset & 2)) * 8)),
        32 => data,
        else => @compileError("Only 8, 16 and 32 bit integers are supported"),
    };
}

fn configWrite32(bus: u8, slot: u8, func: u8, offset: u8, data: u32) void {
    const config_address = ConfigAddress{
        ._zero = 0,
        .register_offset = @truncate(offset >> 2),
        .function_number = @truncate(func),
        .device_number = @truncate(slot),
        .bus_number = @truncate(bus),
        .__reserved = 0,
        .enabled = true,
    };

    io.outl(CONFIG_ADDRESS, @bitCast(config_address));
    io.outl(CONFIG_DATA, data);
}

pub fn configWrite(comptime T: type, bus: u8, slot: u8, func: u8, offset: u8, data: T) void {
    if (@typeInfo(T) != .int) {
        @compileError("Only integer types are supported");
    }
    const int_info = @typeInfo(T).int;
    switch (int_info.bits) {
        8 => {
            const shift = @as(u5, @truncate(offset & 3)) * 8;
            const mask = ~(@as(u32, 0xFF) << shift);
            const current = configRead32(bus, slot, func, offset);
            configWrite32(bus, slot, func, offset, (current & mask) | (@as(u32, data) << shift));
        },
        16 => {
            const shift = @as(u5, @truncate(offset & 2)) * 8;
            const mask = ~(@as(u32, 0xFFFF) << shift);
            const current = configRead32(bus, slot, func, offset);
            configWrite32(bus, slot, func, offset, (current & mask) | (@as(u32, data) << shift));
        },
        32 => configWrite32(bus, slot, func, offset, data),
        else => @compileError("Only 8, 16 and 32 bit integers are supported"),
    }
}

fn vendorRead(bus: u8, slot: u8, func: u8) u16 {
    return configRead(u16, bus, slot, func, 0);
}

fn readHeader(bus: u8, slot: u8, func: u8) u8 {
    return configRead(u8, bus, slot, func, 0x0E);
}

fn readDevice(bus: u8, slot: u8, func: u8) Device {
    const vendor_id = vendorRead(bus, slot, func);
    const device_id = configRead(u16, bus, slot, func, 0x2);
    const command = configRead(u16, bus, slot, func, 0x4);
    const status = configRead(u16, bus, slot, func, 0x6);
    const revision_id = configRead(u8, bus, slot, func, 0x8);
    const progif = configRead(u8, bus, slot, func, 0x9);
    const subclass = configRead(u8, bus, slot, func, 0xA);
    const class_code = configRead(u8, bus, slot, func, 0xB);
    const cache_line_size = configRead(u8, bus, slot, func, 0xC);
    const latency_timer = configRead(u8, bus, slot, func, 0xD);
    const header_type = configRead(u8, bus, slot, func, 0xE);
    const bist = configRead(u8, bus, slot, func, 0xF);

    const base_address_count: u8 = switch (header_type & ~@as(u8, MULTI_FUNC)) {
        0x0 => 6,
        0x1 => 2,
        else => 0,
    };
    const base_address_start = 0x10;

    var bars: [6]u32 = undefined;

    for (0..base_address_count) |bar| {
        bars[bar] = configRead(u32, bus, slot, func, @intCast(base_address_start + bar * 4));
    }

    return .{
        .vendor_id = vendor_id,
        .device_id = device_id,
        .command = command,
        .status = status,
        .revision_id = revision_id,
        .progif = progif,
        .subclass = subclass,
        .class_code = @enumFromInt(class_code),
        .cache_line_size = cache_line_size,
        .latency_timer = latency_timer,
        .header_type = header_type,
        .bist = bist,
        .bar = bars,
        .bar_count = base_address_count,
    };
}

fn checkDevice(bus: u8, slot: u8) void {
    const vendor_id = vendorRead(bus, slot, 0);
    if (vendor_id == EMPTY_VENDOR) return;
    checkFunction(bus, slot, 0);
    const header_tyoe = readHeader(bus, slot, 0);

    if (header_tyoe & MULTI_FUNC != 0) {
        for (1..8) |func| {
            if (vendorRead(bus, slot, @intCast(func)) != EMPTY_VENDOR) {
                checkFunction(bus, slot, @intCast(func));
            }
        }
    }
}

fn checkFunction(bus: u8, slot: u8, func: u8) void {
    const device = readDevice(bus, slot, func);

    log.debug("Found device at bus {d} slot {d} function {d}: {any}", .{ bus, slot, func, device });
    const found = FoundDevice{
        .bus = bus,
        .slot = slot,
        .func = func,
        .info = device,
    };
    devices.add(found);

    if (device.class_code == .bridge and device.subclass == 0x04) {
        const seconday_bus = configRead(u8, bus, slot, func, 0x19);
        checkBus(seconday_bus);
    }
}

fn checkBus(bus: u8) void {
    for (0..SLOT_LIMIT) |slot| {
        checkDevice(bus, @intCast(slot));
    }
}

pub fn emunerate() void {
    const header_type = readHeader(0, 0, 0);
    if (header_type & MULTI_FUNC == 0) {
        checkBus(0); // single pci host controller
    } else {
        // multi function pci host controller
        for (0..FUNC_LIMIT) |func| {
            if (vendorRead(0, 0, @intCast(func)) == EMPTY_VENDOR) continue;

            checkBus(@intCast(func));
        }
    }
}

pub fn find(class: ClassCode, subclass: u8) ?*const FoundDevice {
    var i: u32 = 0;
    while (i < devices.count) : (i += 1) {
        if (devices.items[i].info.class_code == class and devices.items[i].info.subclass == subclass) {
            return &devices.items[i];
        }
    }
    return null;
}
