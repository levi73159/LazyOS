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
}

pub fn putEntryAt(c: u8, color: u8, x: u8, y: u8) void {
    const index = @as(usize, y) * vga.VGA_WIDTH + x;
    const entry = vga.entry(c, color);

    vga.writeEntry(index, entry);
}

pub fn putchar(c: u8) void {
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

pub fn writeln(data: []const u8) void {
    write(data);
    putchar('\n');
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
