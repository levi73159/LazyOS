const std = @import("std");
const arch = @import("arch.zig");
const Position = @import("Position.zig");
const irq = arch.irq;
const io = arch.io;

const log = std.log.scoped(._mouse);

pub const MouseState = struct {
    pos: Position,
    clamp: Position,
    buttons: u8,
    old_buttons: u8,

    pub fn getButton(self: MouseState, button: MouseButton) bool {
        return self.buttons & @intFromEnum(button) != 0;
    }

    pub fn getOldButton(self: MouseState, button: MouseButton) bool {
        return self.old_buttons & @intFromEnum(button) != 0;
    }
};

pub const MouseButton = enum(u8) {
    left = 0b001,
    right = 0b010,
    middle = 0b100,
};

const DATA_PORT = 0x60;
const COMMAND_REGISTER = 0x64;
const STATUS_REGISTER = 0x64;

const MOUSE_PORT = 0xD4;

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
    waitInputReady();
    io.outb(COMMAND_REGISTER, MOUSE_PORT); // tell the ps2 controller were address port 2 (mouse)
    waitInputReady();
    io.outb(DATA_PORT, @intFromEnum(command));

    if (!waitForData()) {
        log.err("Timeout sending mouse command", .{});
        return error.Timeout;
    }

    const ack = io.inb(DATA_PORT);
    if (ack != 0xFA) {
        log.err("Failed to send mouse command (NO ACK): recived {x}", .{ack});
        return error.NoAck;
    }
}

fn waitInputReady() void {
    while (StatusRegister.read().input_buffer_full) {
        asm volatile ("pause");
    }
}

pub fn flushBuffer() void {
    // read and discard up to 16 bytes until buffer is empty
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const status = io.inb(0x64);
        if (status & 0x01 == 0) break; // output buffer empty
        _ = io.inb(0x60);
    }
}

var state: MouseState = .{
    .pos = .{ .x = 0, .y = 0 },
    .clamp = .{ .x = std.math.maxInt(u32), .y = std.math.maxInt(u32) },
    .buttons = 0,
    .old_buttons = 0,
};
var packet: [3]u8 = undefined;
var packet_idx: u32 = 0;

fn readCommandByte() ?u8 {
    flushBuffer();
    waitInputReady();
    io.outb(COMMAND_REGISTER, 0x20);
    if (!waitForData()) {
        log.err("Timeout reading PS/2 command byte", .{});
        return null;
    }
    return io.inb(DATA_PORT);
}

fn writeCommandByte(cmd: u8) void {
    waitInputReady();
    io.outb(COMMAND_REGISTER, 0x60);
    waitInputReady();
    io.outb(DATA_PORT, cmd);
}

// returns true if data appeared, false if timed out
fn waitForData() bool {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if (StatusRegister.read().output_buffer_full) return true;
        asm volatile ("pause");
    }
    return false;
}

pub fn init() void {
    log.debug("Initializing mouse", .{});
    io.cli();
    defer io.sti();

    const cmd_byte = readCommandByte() orelse {
        log.err("Failed to read PS/2 command byte", .{});
        return;
    };
    log.debug("PS/2 command byte: 0x{x}", .{cmd_byte});

    const aux_disabled = cmd_byte & 0x20 != 0;
    if (aux_disabled) {
        log.debug("Aux device disabled, enabling...", .{});
        waitInputReady();
        io.outb(COMMAND_REGISTER, 0xA8);
        flushBuffer();
    }

    // only touch bits 1 and 5 — leave everything else (esp bit 6) intact
    var new_cmd = cmd_byte;
    new_cmd |= 0x02; // enable IRQ12
    new_cmd &= ~@as(u8, 0x20); // enable mouse clock
    writeCommandByte(new_cmd);

    flushBuffer();

    sendCommand(.set_defaults) catch |err| {
        log.err("Failed to set mouse defaults: {s}", .{@errorName(err)});
        return;
    };
    sendCommand(.enable_data_reporting) catch |err| {
        log.err("Failed to enable mouse data reporting: {s}", .{@errorName(err)});
        return;
    };

    irq.register(12, &handler);
    irq.enable(12);
    log.debug("Mouse initialized", .{});
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

    const xi32: i32 = @intCast(state.pos.x);
    const yi32: i32 = @intCast(state.pos.y);

    state.pos.x = @intCast(std.math.clamp(xi32 + xi8, 0, state.clamp.x));
    state.pos.y = @intCast(std.math.clamp(yi32 - yi8, 0, state.clamp.y));

    const mask = 0b111;
    state.old_buttons = state.buttons;
    state.buttons = (mouse_status & mask);
}

pub fn addClamp(_x: u32, _y: u32) void {
    state.clamp = .{ .x = _x, .y = _y };
}

pub fn getPosition() Position {
    return state.pos;
}

pub fn x() u32 {
    return state.pos.x;
}

pub fn y() u32 {
    return state.pos.y;
}

pub fn isButtonPressed(btn: MouseButton) bool {
    return state.getButton(btn);
}

pub fn isButtonReleased(btn: MouseButton) bool {
    return !state.getButton(btn);
}

pub fn isButtonJustPressed(btn: MouseButton) bool {
    return state.getButton(btn) and !state.getOldButton(btn);
}

pub fn isButtonJustReleased(btn: MouseButton) bool {
    return !state.getButton(btn) and state.getOldButton(btn);
}

pub fn updateMouse() void {
    state.old_buttons = state.buttons;
}

pub fn resetState() void {
    state = .{
        .pos = .{ .x = 0, .y = 0 },
        .clamp = .{ .x = std.math.maxInt(u32), .y = std.math.maxInt(u32) },
        .buttons = 0,
        .old_buttons = 0,
    };
}
