const std = @import("std");
const arch = @import("arch.zig");
const irq = arch.irq;
const io = arch.io;

const log = std.log.scoped(._mouse);

pub const MousePos = struct {
    x: u32,
    y: u32,
};

pub const MouseButton = enum {
    left,
    right,
    middle,
};

const DATA_PORT = 0x60;
const COMMAND_REGISTER = 0x64;
const STATUS_REGISTER = 0x64;

const MOUSE_PORT = 0xD4;

// BUG: find cause and fix these bugs
// [mouse] error: Failed to send mouse command (NO ACK): recived e0
// [mouse] error: Failed to set mouse defaults: NoAck

const StatusRegister = packed struct(u8) {
    output_buffer_full: bool,
    input_buffer_full: bool,
    system_flag: bool,
    use_command: bool,
    unknown1: bool,
    unknown2: bool,
    time_out_error: bool,
    parity_error: bool,

    pub fn read() StatusRegister {
        return @bitCast(io.inb(STATUS_REGISTER));
    }
};

const MouseCommand = enum(u8) {
    scale_11 = 0xE6,
    scale_21 = 0xE7,
    set_resolution = 0xE8,
    status_request = 0xE9,
    set_stream_mode = 0xEA,
    read_data = 0xEB,
    reset_wrap_mouse = 0xEC,
    set_wrap_mode = 0xEE,
    set_remote_mode = 0xF0,
    get_device_id = 0xF2,
    set_sampling_rate = 0xF3,
    enable_data_reporting = 0xF4,
    disable_data_reporting = 0xF5,
    set_defaults = 0xF6,
    resend = 0xFE,
    reset = 0xFF,
};

fn sendCommand(command: MouseCommand) !void {
    io.outb(COMMAND_REGISTER, MOUSE_PORT); // tell the ps2 controller were address port 2 (mouse)
    io.outb(DATA_PORT, @intFromEnum(command));

    waitForData();

    const ack = io.inb(DATA_PORT);
    if (ack != 0xFA) {
        log.err("Failed to send mouse command (NO ACK): recived {x}", .{ack});
        return error.NoAck;
    }
}

fn waitForData() void {
    while (!StatusRegister.read().output_buffer_full) {
        asm volatile ("pause");
    }
}

var mouse_pos: MousePos = .{ .x = 0, .y = 0 };
var mouse_clamp: MousePos = .{ .x = std.math.maxInt(u32), .y = std.math.maxInt(u32) };
var packet: [3]u8 = undefined;
var packet_idx: u32 = 0;

pub fn init() void {
    log.debug("Initializing mouse", .{});
    // io.outb(COMMAND_REGISTER, 0xA8); // enable aux mouse device
    //
    // // enable mouse interrupts via command byte
    // io.outb(COMMAND_REGISTER, 0x20); // read command byte
    // waitForData();
    // var cmd = io.inb(DATA_PORT);
    // cmd |= 0x02; // enable IRQ12
    // cmd &= ~@as(u8, 0x20); // enable mouse clock
    // io.outb(COMMAND_REGISTER, 0x60);
    // io.outb(DATA_PORT, cmd);

    sendCommand(.set_defaults) catch |err| {
        log.err("Failed to set mouse defaults: {s}", .{@errorName(err)});
    };
    sendCommand(.enable_data_reporting) catch |err| {
        log.err("Failed to enable mouse data reporting: {s}", .{@errorName(err)});
    };

    irq.register(12, &handler);
    irq.enable(12);
}

pub fn handler(_: *arch.registers.InterruptFrame) void {
    const status = StatusRegister.read();

    if (status.time_out_error) {
        log.err("Mouse timeout error", .{});
        return;
    }

    if (status.parity_error) {
        log.err("Mouse parity error", .{});
        return;
    }

    // nothing to do
    if (!status.output_buffer_full) {
        return;
    }

    packet[packet_idx] = io.inb(DATA_PORT);
    packet_idx += 1;

    if (packet_idx == 3) {
        packet_idx = 0;
        processPacket();
    }
}

fn processPacket() void {
    const mouse_status = packet[0];
    const xu8 = packet[1];
    const yu8 = packet[2];

    if (mouse_status & 0x08 == 0) {
        log.warn("Packet is dsynced", .{});
        return;
    }

    const xi8: i8 = @bitCast(xu8);
    const yi8: i8 = @bitCast(yu8);

    const xi32: i32 = @intCast(mouse_pos.x);
    const yi32: i32 = @intCast(mouse_pos.y);

    mouse_pos.x = @intCast(std.math.clamp(xi32 + xi8, 0, mouse_clamp.x));
    mouse_pos.y = @intCast(std.math.clamp(yi32 - yi8, 0, mouse_clamp.y));
}

pub fn addClamp(_x: u32, _y: u32) void {
    mouse_clamp = .{ .x = _x, .y = _y };
}

pub fn getPosition() MousePos {
    return mouse_pos;
}

pub fn x() u32 {
    return mouse_pos.x;
}

pub fn y() u32 {
    return mouse_pos.y;
}
