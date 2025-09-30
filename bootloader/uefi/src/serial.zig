const std = @import("std");
const io = @import("io.zig");

pub const Port = enum(u16) {
    com1 = 0x3f8,
    com2 = 0x2f8,
    com3 = 0x3e8,
    com4 = 0x2e8,
    com5 = 0x5f8,
    com6 = 0x4f8,
    com7 = 0x5e8,
    com8 = 0x4e8,

    fn write(self: Port, offset: Offset, data: anytype) void {
        if (@typeInfo(@TypeOf(data)) == .comptime_int) {
            io.out(@intFromEnum(self) + @intFromEnum(offset), @as(u8, data));
        } else {
            io.out(@intFromEnum(self) + @intFromEnum(offset), @as(u8, @bitCast(data)));
        }
    }

    fn testCon(self: Port, data: u8) bool {
        io.out(@intFromEnum(self), data);
        return io.in(u8, @intFromEnum(self)) == data;
    }
};

pub const Offset = enum(u8) {
    rxtx_buffer = 0, // if divisor latch is set => divisor lsb
    int_enable, // if divisor latch is set => divisor msb
    fifo_ctrl,
    line_ctrl,
    modem_ctrl,
    line_status,
    modem_status,
    scratch,
};

const LineCtrlReg = packed struct(u8) {
    data: u2 = 0,
    stop: u1 = 0,
    parity: u3 = 0,
    break_enable: bool = false,
    divisor_latch: bool = false,
};

const FifoCtrlReg = packed struct(u8) {
    enable: bool = false,
    clear_rx: bool = false,
    clear_tx: bool = false,
    dma_mode: u1 = 0,
    rsrvd: u2 = undefined, // never used
    int_trigger: u2 = 0,
};

const ModemCtrlReg = packed struct(u8) {
    dtr: bool = false,
    rts: bool = false,
    out1: bool = false,
    out2: bool = false,
    loop: bool = false,
    unused: u3 = undefined,
};

pub const SerialWriter = struct {
    port: Port,

    pub const SerialError = error{};
    pub const Writer = std.io.GenericWriter(*const SerialWriter, SerialError, write);

    pub fn init(port: Port) !SerialWriter {
        port.write(.int_enable, 0);
        port.write(.line_ctrl, LineCtrlReg{ .divisor_latch = true });
        port.write(.rxtx_buffer, 3);
        port.write(.int_enable, 0);
        port.write(.line_ctrl, LineCtrlReg{ .data = 0b11, .stop = 0, .divisor_latch = false });
        port.write(.fifo_ctrl, FifoCtrlReg{ .enable = true, .clear_rx = true, .clear_tx = true });

        var modem_ctrl: ModemCtrlReg = ModemCtrlReg{
            .dtr = true,
            .rts = true,
            .out1 = true,
            .out2 = true,
            .loop = true,
        };
        port.write(.modem_ctrl, modem_ctrl);

        var success: bool = true;
        success = port.testCon(0xAA);
        success = port.testCon(0x55) and success;
        success = port.testCon(0xC7) and success;

        if (!success) {
            return error.SerialConnectionFailed;
        }

        // disable looping
        modem_ctrl.loop = false;
        port.write(.modem_ctrl, modem_ctrl);

        return SerialWriter{ .port = port };
    }

    pub fn writer(self: *const SerialWriter) Writer {
        return .{ .context = self };
    }

    fn write(self: *const SerialWriter, data: []const u8) SerialError!usize {
        const port = @intFromEnum(self.port);
        return io.outStr(port, data);
    }
};
