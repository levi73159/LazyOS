const vga = @import("vga.zig");

var terminal_row: u8 = 0;
var terminal_column: u8 = 0;
var terminal_color: u8 = vga.entryColor(.light_grey, .black);

pub fn init() void {
    const entry = vga.entry(' ', terminal_color);

    var y: u8 = 0;
    while (y < vga.VGA_HEIGHT) : (y += 1) {
        var x: u8 = 0;
        while (x < vga.VGA_WIDTH) : (x += 1) {
            const index = @as(usize, y) * vga.VGA_WIDTH + x;
            vga.writeEntry(index, entry);
        }
    }

    terminal_row = 0;
    terminal_column = 0;
    updateCursor();
}

pub fn putEntryAt(c: u8, color: u8, x: u8, y: u8) void {
    const index = @as(usize, y) * vga.VGA_WIDTH + x;
    const entry = vga.entry(c, color);

    vga.writeEntry(index, entry);
}

pub fn putchar(c: u8) void {
    defer updateCursor(); // Update cursor position
    if (c == '\n') {
        terminal_column = 0;
        if (terminal_row < vga.VGA_HEIGHT - 1) {
            terminal_row += 1;
        }
        return;
    }

    putEntryAt(c, terminal_color, terminal_column, terminal_row);
    terminal_column += 1;
    if (terminal_column == vga.VGA_WIDTH) {
        terminal_column = 0;
        if (terminal_row < vga.VGA_HEIGHT - 1) {
            terminal_row += 1;
        }
    }
}

pub fn write(data: []const u8) void {
    for (data) |c| {
        putchar(c);
    }
}

pub fn setColor(color: vga.Color) void {
    terminal_color = vga.entryColor(color, vga.Color.black);
}

pub fn setFgBg(fg: vga.Color, bg: vga.Color) void {
    terminal_color = vga.entryColor(fg, bg);
}

// Inline assembly functions for keyboard input
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

fn updateCursor() void {
    const pos = @as(u16, terminal_row) * vga.VGA_WIDTH + terminal_column;

    // Cursor low byte
    outb(0x3D4, 0x0F);
    outb(0x3D5, @truncate(pos & 0xFF));

    // Cursor high byte
    outb(0x3D4, 0x0E);
    outb(0x3D5, @truncate((pos >> 8) & 0xFF));
}

pub fn setCursor(x: u8, y: u8) void {
    outb(0x3D4, 0x0F);
    outb(0x3D5, y);
    outb(0x3D4, 0x0E);
    outb(0x3D5, x);
}
