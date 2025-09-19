const std = @import("std");
const InterruptFrame = @import("arch.zig").registers.InterruptFrame;
const console = @import("console.zig");

const arch = @import("arch.zig");
const io = arch.io;

const log = std.log.scoped(.keyboard);

const PORT_COMMAND = 0x64;
const PORT_STATUS = 0x64;
const PORT_DATA = 0x60;
const CMD_SETLED = 0xed;

const Scancode = enum(u8) {
    esc = 1,
    one = 2,
    two = 3,
    three = 4,
    four = 5,
    five = 6,
    six = 7,
    seven = 8,
    eight = 9,
    nine = 10,
    zero = 11,
    minus = 12,
    equals = 13,
    backspace = 14,
    tab = 15,
    q = 16,
    w = 17,
    e = 18,
    r = 19,
    t = 20,
    y = 21,
    u = 22,
    i = 23,
    o = 24,
    p = 25,
    left_bracket = 26,
    right_bracket = 27,
    enter = 28,
    ctrl = 29,
    a = 30,
    s = 31,
    d = 32,
    f = 33,
    g = 34,
    h = 35,
    j = 36,
    k = 37,
    l = 38,
    semicolon = 39,
    quote = 40,
    tilde = 41,
    left_shift = 42,
    backslash = 43,
    z = 44,
    x = 45,
    c = 46,
    v = 47,
    b = 48,
    n = 49,
    m = 50,
    comma = 51,
    period = 52,
    slash = 53,
    right_shfit = 54,
    keypad_star = 55,
    alt = 56,
    space = 57,
    caps_lock = 58,
    f1 = 59,
    f2 = 60,
    f3 = 61,
    f4 = 62,
    f5 = 63,
    f6 = 64,
    f7 = 65,
    f8 = 66,
    f9 = 67,
    f10 = 68,
    num_lock = 69,
    scroll_lock = 70,
    keypad_7 = 71,
    keypad_8 = 72,
    keypad_9 = 73,
    keypad_minus = 74,
    keypad_4 = 75,
    keypad_5 = 76,
    keypad_6 = 77,
    keypad_plus = 78,
    keypad_1 = 79,
    keypad_2 = 80,
    keypad_3 = 81,
    keypad_0 = 82,
    keypad_period = 83,
    f11 = 87,
    f12 = 88,
    _,

    pub fn getChar(self: Scancode) ?u8 {
        return switch (self) {
            .one => '1',
            .two => '2',
            .three => '3',
            .four => '4',
            .five => '5',
            .six => '6',
            .seven => '7',
            .eight => '8',
            .nine => '9',
            .zero => '0',
            .a => 'a',
            .b => 'b',
            .c => 'c',
            .d => 'd',
            .e => 'e',
            .f => 'f',
            .g => 'g',
            .h => 'h',
            .i => 'i',
            .j => 'j',
            .k => 'k',
            .l => 'l',
            .m => 'm',
            .n => 'n',
            .o => 'o',
            .p => 'p',
            .q => 'q',
            .r => 'r',
            .s => 's',
            .t => 't',
            .u => 'u',
            .v => 'v',
            .w => 'w',
            .x => 'x',
            .y => 'y',
            .z => 'z',
            .space => ' ',
            .enter => '\n',
            .tilde => '`',
            else => null,
        };
    }

    pub fn getShiftChar(self: Scancode) ?u8 {
        return switch (self) {
            .one => '!',
            .two => '@',
            .three => '#',
            .four => '$',
            .five => '%',
            .six => '^',
            .seven => '&',
            .eight => '*',
            .nine => '(',
            .zero => ')',
            .a => 'A',
            .b => 'B',
            .c => 'C',
            .d => 'D',
            .e => 'E',
            .f => 'F',
            .g => 'G',
            .h => 'H',
            .i => 'I',
            .j => 'J',
            .k => 'K',
            .l => 'L',
            .m => 'M',
            .n => 'N',
            .o => 'O',
            .p => 'P',
            .q => 'Q',
            .r => 'R',
            .s => 'S',
            .t => 'T',
            .u => 'U',
            .v => 'V',
            .w => 'W',
            .x => 'X',
            .y => 'Y',
            .z => 'Z',
            .left_bracket => '{',
            .right_bracket => '}',
            .semicolon => ':',
            .quote => '"',
            .tilde => '~',
            .backslash => '|',
            .comma => '<',
            .period => '>',
            else => self.getChar(),
        };
    }
};

const Key = struct {
    scancode: Scancode,
    modifiers: Modifiers,
    pressed: bool,
    special: bool, // modifier keys like caps lock or shift

    pub fn getChar(self: Key) ?u8 {
        return if (self.modifiers.shift) self.scancode.getShiftChar() else self.scancode.getChar();
    }
};

const State = struct {
    scroll_lock: bool = false,
    num_lock: bool = false,
    caps_lock: bool = false,

    fn getBits(self: State) u3 {
        var bits: u3 = 0;
        if (self.scroll_lock) bits |= 1;
        if (self.num_lock) bits |= 2;
        if (self.caps_lock) bits |= 4;
        return bits;
    }
};

const Status = packed struct(u8) {
    output_buffer_full: bool = false,
    input_buffer_full: bool = false,
    system_flag: bool = false,
    is_command_sent: bool = false,
    _reserved: u4 = 0,
};

const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
};

var buf: [40]Key = undefined;
var end_index: usize = 0;
var start_index: usize = 0;

var wait_key: bool = false;
var prev: ?Key = null;

var modifiers: Modifiers = .{};
var state: State = .{};

// polling
const Keys = std.EnumArray(Scancode, bool);
var keys: Keys = Keys.initFill(false);

fn bufferFull() bool {
    return ((end_index + 1) % buf.len) == start_index;
}

pub fn init() void {
    arch.irq.register(1, handler);
    arch.irq.enable(1);
}

pub fn handler(_: InterruptFrame) void {
    io.cli();

    const scancode = io.inb(PORT_DATA);

    const key_presses = scancode & 0x80 == 0;
    const key_code = scancode & 0x7f;

    const code: Scancode = @enumFromInt(key_code);
    keys.set(code, key_presses);

    var is_special = false;
    switch (code) {
        // modifiers keys
        .caps_lock => {
            if (!key_presses) {
                state.caps_lock = !state.caps_lock;
            }
            is_special = true;
        },
        .num_lock => {
            if (!key_presses) {
                state.num_lock = !state.num_lock;
            }
            is_special = true;
        },
        .scroll_lock => {
            if (!key_presses) {
                state.scroll_lock = !state.scroll_lock;
            }
            is_special = true;
        },

        .left_shift, .right_shfit => {
            if (key_presses) {
                log.debug("shift pressed", .{});
                modifiers.shift = true;
            } else {
                log.debug("shift released", .{});
                modifiers.shift = false;
            }
            is_special = true;
        },
        .alt => {
            if (key_presses) {
                modifiers.alt = false;
            } else {
                modifiers.alt = true;
            }
            is_special = true;
        },
        .ctrl => {
            if (key_presses) {
                modifiers.ctrl = false;
            } else {
                modifiers.ctrl = true;
            }
            is_special = true;
        },
        else => {},
    }

    const key = Key{ .scancode = @enumFromInt(key_code), .pressed = key_presses, .modifiers = modifiers, .special = is_special };
    buf[end_index] = key;
    prev = key;

    if (!bufferFull())
        end_index = (end_index + 1) % buf.len;

    wait_key = false;

    io.sti();
}

fn sendCommand(command: u8, params: ?u8) void {
    io.cli();
    io.outb(0x64, command);
    io.wait();
    if (params) |p| {
        io.outb(0x60, p);
        io.wait();
    }
    io.sti();
}

fn getStatusRegsiter() Status {
    return @bitCast(io.inb(PORT_STATUS));
}

pub fn getKey() Key {
    // nothing in the buffer
    if (start_index == end_index) {
        waitForKey();
    }

    const key = buf[start_index];
    start_index = (start_index + 1) % buf.len;
    return key;
}

pub fn flush() void {
    start_index = 0;
    end_index = 0;
}

pub fn waitForKey() void {
    wait_key = true;
    while (wait_key) {}
}

pub fn getKeyDown(scancode: Scancode) bool {
    return keys.get(scancode);
}

pub fn getKeyUp(scancode: Scancode) bool {
    return !keys.get(scancode);
}
