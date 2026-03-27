//! THE Ahci disk driver for x86_64
const std = @import("std");
const mem = std.mem;
const pci = @import("../pci.zig");
const heap = @import("../memory/heap.zig");
const pmem = @import("../memory/pmem.zig");
const bootinfo = @import("../arch.zig").bootinfo;
const ata = @import("ata.zig");
const pit = @import("../pit.zig");

const commands = @import("ahci/commands.zig");
const CommandHeader = commands.CommandHeader;
const PrdtEntry = commands.PrdtEntry;
const CommandTable = commands.CommandTable;

const dma = @import("ahci/dma.zig");
const fis = @import("ahci/fis.zig");
const hba = @import("ahci/hba.zig");
const scsi = @import("ahci/scsi.zig");

const log = std.log.scoped(.ahci);

pub const SataType = enum(u8) {
    sata = 0,
    semb = 1, // enclosure management bridge
    pm = 2,
    satapi = 3,
};

pub const Port = struct {
    hba: *volatile hba.Port,
    port_num: u8,
    num_of_slots: u8,
    type: SataType,
};

pub const DiskError = error{
    PortHung,
    TaskFileError,
    NoFreeCommandList,
    UnsupportedDiskType,
};

const SATA_SIG_ATA = 0x00000101;
const SATA_SIG_ATAPI = 0xEB140101;
const SATA_SIG_SEMB = 0xC33C0101; // Enclosure management bridge
const SATA_SIG_PM = 0x96690101; // Port multiplier

const ATA_DEV_BUSY = 0x80;
const ATA_DEV_DRQ = 0x08;
const MAX_MEMORY_READABLE = 16 * 1024 * 1024; // we can read up to 16MB

const BUS_MASTER = 1 << 2;
const MEMORY_SPACE = 1 << 1;
const IO_SPACE = 1 << 0;

fn findAHCI() ?*const pci.FoundDevice {
    const device = pci.find(.mass_storage, 0x06);
    if (device == null) log.warn("No AHCI device found", .{});
    return device;
}

// return list of ports
pub fn init(allocator: mem.Allocator, port_buf: *[32]?Port) ![]?Port {
    const device = findAHCI() orelse return error.NoAHCI;
    std.debug.assert(device.info.class_code == .mass_storage and device.info.subclass == 0x06);
    std.debug.assert(device.info.vendor_id == 0x8086); // 0x8086 is Intel Vendor ID

    if (device.info.bar_count < 5) {
        log.warn("Not enough BARs for AHCI: bar count: {d}", .{device.info.bar_count});
        return error.NoBARS;
    }
    const abar_location = device.info.bar[5];
    const abar_virt = bootinfo.toVirtualHHDM(abar_location);

    const hba_mem: *volatile hba.Mem = @ptrFromInt(abar_virt);
    log.debug("Found AHCI at 0x{x}", .{abar_virt});

    const cabaiblties_reg = hba_mem.host_cap;
    if (!cabaiblties_reg.dma_64adressable) return error.MustSupport64BitDMA;

    const cmd = pci.configRead(u16, device.bus, device.slot, device.func, 0x04);
    pci.configWrite(u16, device.bus, device.slot, device.func, 0x04, cmd | BUS_MASTER | MEMORY_SPACE | IO_SPACE); // enable pci command bits

    hba_mem.global_host_ctl.hba_reset = true;

    while (hba_mem.global_host_ctl.hba_reset) {} // wait for reset to clear
    pit.sleep(1);
    hba_mem.global_host_ctl.ahci_enable = true;
    // TODO: add interrupt handler for disk
    hba_mem.global_host_ctl.int_enable = false; // disable interrupts (not used)

    const nums_of_slots = try probeAndRebase(hba_mem, allocator, port_buf);
    return port_buf[0..nums_of_slots];
}

fn handOffToOS(abar: *volatile hba.Mem) void {
    const bohc: *volatile hba.BiosOSHandOffControl = &abar.bohc;

    if (bohc.bios_owned) {
        bohc.os_owned = true;

        while (bohc.bios_busy or bohc.bios_owned) {} // wait for BIOS to release ownership
    }
}

fn probeAndRebase(abar: *volatile hba.Mem, allocator: std.mem.Allocator, port_buf: *[32]?Port) !u32 {
    var pi = abar.port_impl;
    var i: u32 = 0;

    const nums_of_slots = abar.numSlots();
    while (i < nums_of_slots) : ({
        pi >>= 1;
        i += 1;
    }) {
        if (pi & 1 == 0) continue;
        port_buf[i] = null;

        if (!waitForLinkUp(&abar.ports[i])) {
            log.info("No drive found at port {d}", .{i});
            continue;
        }

        try portRebase(&abar.ports[i], nums_of_slots, allocator);

        pit.sleep(10);

        // check if port is connected
        const dt = getType(i, &abar.ports[i]);
        if (dt) |d| {
            log.info("{s} drive found at port {d}", .{ @tagName(d), i });

            port_buf[i] = Port{
                .hba = &abar.ports[i],
                .port_num = @intCast(i),
                .num_of_slots = nums_of_slots,
                .type = d,
            };
        } else {
            log.info("No drive found at port {d}", .{i});
            port_buf[i] = null;
        }
    }

    return i; // or numberof slots (doesn't matter since they are the same)
}

fn waitForLinkUp(port: *volatile hba.Port) bool {
    const ssts = port.sata_status;
    const det: u8 = @truncate(ssts & 0x0F);

    // det=0 means no device at all — no point waiting
    if (det == 0) return false;

    // det=1 means device detected but comms not yet established — worth waiting
    // det=3 means fully up already
    const max_ms = 500;
    var elapsed: u32 = 0;

    while (elapsed < max_ms) : (elapsed += 10) {
        const ssts2 = port.sata_status;
        const det2: u8 = @truncate(ssts2 & 0x0F);
        const ipm: u8 = @truncate(ssts2 >> 8);

        if (det2 == hba.PORT_DET_PRESENT and ipm == hba.PORT_IPM_ACTIVE) {
            log.debug("link up after {d}ms", .{elapsed});
            return true;
        }

        // device disappeared — no point waiting further
        if (det2 == 0) return false;

        pit.sleep(10);
    }

    return false;
}

fn portActive(port: *volatile hba.Port) bool {
    const ssts = port.sata_status;

    const ipm: u8 = @truncate(ssts >> 8);
    const det: u8 = @truncate(ssts & 0x0F);

    if (det != hba.PORT_DET_PRESENT) {
        return false;
    }
    if (ipm != hba.PORT_IPM_ACTIVE) {
        return false;
    }

    return true;
}

fn getType(num: u32, port: *volatile hba.Port) ?SataType {
    const ssts = port.sata_status;

    const ipm: u8 = @truncate(ssts >> 8);
    const det: u8 = @truncate(ssts & 0x0F);

    if (det != hba.PORT_DET_PRESENT) {
        log.warn("Port {d} is not present", .{num});
        return null;
    }
    if (ipm != hba.PORT_IPM_ACTIVE) {
        log.warn("Port {d} is not active", .{num});
        return null;
    }

    return switch (port.sig) {
        SATA_SIG_ATAPI => SataType.satapi,
        SATA_SIG_SEMB => SataType.semb,
        SATA_SIG_PM => SataType.pm,
        SATA_SIG_ATA => SataType.sata,
        else => |sig| {
            log.warn("Port {d} has unknown signature 0x{x}", .{ num, sig });
            return null;
        },
    };
}

// start command engine
fn startCmd(port: *volatile hba.Port) void {
    while (port.cmd & hba.PxCMD_CR != 0) {}

    port.cmd |= hba.PxCMD_FRE;
    port.cmd |= hba.PxCMD_ST;
}

fn stopCmd(port: *volatile hba.Port) void {
    port.cmd &= ~hba.PxCMD_FRE;
    port.cmd &= ~hba.PxCMD_ST;

    while (true) {
        if (port.cmd & hba.PxCMD_FR != 0) continue;
        if (port.cmd & hba.PxCMD_CR != 0) continue;
        break;
    }
}

fn portRebase(port: *volatile hba.Port, nums_of_slots: u16, allocator: mem.Allocator) !void {
    stopCmd(port);

    const cmd_list = try allocator.alignedAlloc(u8, .fromByteUnits(1024), 1024); // 1024 bytes, 1K alignment
    @memset(cmd_list, 0);

    const cmd_list_phys = bootinfo.toPhysical(@intFromPtr(cmd_list.ptr));
    port.cmd_list_base = cmd_list_phys;

    const fis_mem = try allocator.alignedAlloc(u8, .fromByteUnits(256), 256); // 256 bytes, 256 alignment
    @memset(fis_mem, 0);

    const fis_phys = bootinfo.toPhysical(@intFromPtr(fis_mem.ptr));
    port.fis_base = fis_phys;

    const prdt_count = 4; // 1 PRDT describes 4MB of memory (4 * 4MB = 16MB)
    const table_size = @sizeOf(CommandTable) + prdt_count * @sizeOf(PrdtEntry);

    const cmd_headers: [*]CommandHeader = @ptrCast(@alignCast(cmd_list.ptr));

    for (0..nums_of_slots) |i| {
        const table_mem = try allocator.alignedAlloc(u8, .fromByteUnits(128), table_size);
        @memset(table_mem, 0);

        const table_phys = bootinfo.toPhysical(@intFromPtr(table_mem.ptr));

        cmd_headers[i].prdtl = prdt_count;
        cmd_headers[i].command_table_base = table_phys;
        cmd_headers[i].prdbc = 0;
        cmd_headers[i].fis_len = 0;
        cmd_headers[i].atapi = false;
        cmd_headers[i].write = false;
        cmd_headers[i].prefetchable = false;
        cmd_headers[i].reset = false;
        cmd_headers[i].bist = false;
        cmd_headers[i].clear = false;
        cmd_headers[i].port_multiplier = 0;
        cmd_headers[i].__reserved1 = 0;
    }

    startCmd(port);
    log.debug("port rebased: cmdlist=0x{x} fis=0x{x}", .{ cmd_list_phys, fis_phys });
}

pub const SECTOR_SIZE = 512;
pub const Sector = [SECTOR_SIZE]u8;

pub fn readSectors(port: *const Port, lba: u48, buf: []Sector) DiskError!void {
    if (buf.len == 0) return;
    port.hba.int_status = @bitCast(@as(i32, -1)); // clear pending interrupts

    const mem_reading = buf.len * SECTOR_SIZE;
    if (mem_reading > MAX_MEMORY_READABLE) @panic("TODO: add chunked up memory reading"); // TODO

    const slot = findCmdSlot(port.hba, port.num_of_slots) orelse return error.NoFreeCommandList;

    const cmd_list_virt = bootinfo.toVirtualHHDM(port.hba.cmd_list_base);
    const headers: [*]CommandHeader = @ptrFromInt(cmd_list_virt);
    const header = &headers[slot];

    const MAX_MEM_PER_ENTRY = 4 * 1024 * 1024; // 4MB per PRDT entry

    const total_bytes = buf.len * SECTOR_SIZE;
    const prdt_count: u16 = @intCast((total_bytes + MAX_MEM_PER_ENTRY - 1) / MAX_MEM_PER_ENTRY);
    header.fis_len = @sizeOf(fis.RegH2D) / 4; // in DWRODS
    header.write = false;
    header.prdtl = prdt_count;
    header.prdbc = 0;
    header.atapi = port.type == .satapi;

    const table_virt = bootinfo.toVirtualHHDM(header.command_table_base);
    const table: *CommandTable = @ptrFromInt(table_virt);
    // do it this way so we can easily set it to zero
    @memset(
        @as([*]u8, @ptrCast(table))[0 .. @sizeOf(CommandTable) + prdt_count * @sizeOf(PrdtEntry)],
        0,
    );

    const prdt = table.prdtSlice(prdt_count);
    var remaining_bytes = buf.len * SECTOR_SIZE;
    var buf_phys = bootinfo.toPhysical(@intFromPtr(buf.ptr));

    for (prdt[0..prdt_count]) |*entry| {
        const chunk = @min(remaining_bytes, MAX_MEM_PER_ENTRY);
        entry.* = .{
            .data_base = buf_phys,
            .__reserved = 0,
            .byte_count = @intCast(chunk - 1),
            .__reserved2 = 0,
            .interrupt_on_completion = false, // we are polling rn (TODO: add interrupt driven IO)
        };
        buf_phys += chunk;
        remaining_bytes -= chunk;
    }

    switch (port.type) {
        .sata => sendCommandATA(table, lba, buf),
        .satapi => sendCommandATAPI(table, lba, buf),
        else => {
            log.err("Unsupported disk type: {s}", .{@tagName(port.type)});
            return error.UnsupportedDiskType;
        },
    }

    try issueCommand(port.hba, slot);
}

fn sendCommandATA(table: *CommandTable, lba: u48, buf: []Sector) void {
    // ATA READ DMA EXT
    const cmdfis: *fis.RegH2D = @ptrCast(@alignCast(&table.cmd_fis));
    cmdfis.* = .{
        .fis_type = .reg_h2d,
        .c = .command,
        .command = 0x25, // READ DMA EXT
        .device = 1 << 6, // LBA mode
        .lba_low = @truncate(lba),
        .lba_high = @truncate(lba >> 24),
        .count = @intCast(buf.len),
        .feature_low = 0,
        .feature_high = 0,
        .icc = 0,
        .control = 0,
    };
}

fn sendCommandATAPI(table: *CommandTable, lba: u48, buf: []Sector) void {
    const cmdfis: *fis.RegH2D = @ptrCast(@alignCast(&table.cmd_fis));
    cmdfis.* = .{
        .fis_type = .reg_h2d,
        .c = .command,
        .command = 0xA0,
        .device = 0,
        .lba_low = 0,
        .lba_high = 0,
        .count = 0,
        .feature_low = 1, // DMA bit
        .feature_high = 0,
        .icc = 0,
        .control = 0,
    };

    // 12-byte scsi READ(12) command
    const lba32: u32 = @intCast(lba);
    const count32: u32 = @intCast(buf.len);

    const packet: *scsi.Read12Packet = @ptrCast(@alignCast(&table.atapi_cmd));
    packet.* = .init(lba32, count32);
}

fn issueCommand(port: *volatile hba.Port, slot: u16) !void {
    var spin: u32 = 0;
    while (port.task_file_data & (ATA_DEV_BUSY | ATA_DEV_DRQ) != 0) {
        spin += 1;
        if (spin >= 1_000_000) return error.PortHung;
    }

    port.cmd_issue = @as(u32, 1) << @intCast(slot); // issue a command

    spin = 0;
    while (true) : (spin += 1) {
        if (port.cmd_issue & (@as(u32, 1) << @intCast(slot)) == 0) break; // done
        if (port.int_status & hba.PxIS_TFES != 0) return error.TaskFileError;
        if (spin >= 1_000_000) return error.PortHung;
    }

    if (port.int_status & hba.PxIS_TFES != 0) return error.TaskFileError;
}

fn findCmdSlot(port: *volatile hba.Port, cmd_slots: u8) ?u16 {
    var slots = port.sata_active | port.cmd_issue;
    for (0..cmd_slots) |i| {
        if (slots & 1 == 0) return @intCast(i);
        slots >>= 1;
    }
    log.warn("Cannot find free command list entry", .{});
    return null;
}

pub fn identify(port: *const Port, buf: []u16) !void {
    const slot = findCmdSlot(port.hba, port.num_of_slots) orelse return error.NoFreeCommandList;

    const cmd_list_virt = bootinfo.toVirtualHHDM(port.hba.cmd_list_base);
    const headers: [*]CommandHeader = @ptrFromInt(cmd_list_virt);
    const header = &headers[slot];

    header.fis_len = @sizeOf(fis.RegH2D) / 4;
    header.write = false;
    header.prdtl = 1;
    header.atapi = port.type == .satapi;

    const cmd_table_virt = bootinfo.toVirtualHHDM(header.command_table_base);
    const table: *CommandTable = @ptrFromInt(cmd_table_virt);

    @memset(
        @as([*]u8, @ptrCast(table))[0 .. @sizeOf(CommandTable) + @sizeOf(PrdtEntry)],
        0,
    );

    const prdt = &table.prdtSlice(1)[0];
    prdt.* = .{
        .data_base = bootinfo.toPhysical(@intFromPtr(buf.ptr)),
        .byte_count = @intCast((buf.len * 2) - 1),
        .interrupt_on_completion = false,
    };

    const reg_h2d: *fis.RegH2D = @ptrCast(@alignCast(&table.cmd_fis));
    reg_h2d.* = .{
        .fis_type = .reg_h2d,
        .c = .command,
        .command = if (port.type == .satapi) 0xA1 else 0xEC,
        .device = 0,
        .lba_low = 0,
        .lba_high = 0,
        .count = 0,
        .feature_low = 0,
        .feature_high = 0,
        .icc = 0,
        .control = 0,
    };

    port.hba.int_status = 0xFFFF_FFFF; // clear int status
    try issueCommand(port.hba, slot);
}

fn stopAllPorts(abar: *volatile hba.Mem) void {
    const pi = abar.port_impl;
    for (0..abar.numSlots()) |i| {
        if (pi & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const port: *volatile hba.Port = &abar.ports[i];

        stopCmd(port);
    }
}

pub fn sectorSize(port: *const Port) u32 {
    return if (port.type == .satapi) 2048 else 512;
}
