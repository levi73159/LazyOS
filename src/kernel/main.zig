const vga = @import("vga.zig");
const terminal = @import("terminal.zig");

export fn main() noreturn {
    // Initialize VGA text mode
    terminal.init();

    // Print startup messages
    terminal.setColor(.light_cyan);
    terminal.writeln("LazyOS v0.1.0");

    terminal.setColor(.light_green);
    terminal.writeln("Kernel loaded successfully!");

    terminal.setColor(.white);
    terminal.writeln("64-bit x86_64 kernel running");

    terminal.setColor(.yellow);
    terminal.writeln("Press keys (ESC to halt):");

    terminal.setColor(.light_grey);

    // Simple keyboard input loop
    while (true) {
        // Check if keyboard data is available
        const status = terminal.inb(0x64);
        if ((status & 1) != 0) {
            const scancode = terminal.inb(0x60);

            // ESC key to exit
            if (scancode == 0x01) {
                terminal.write("\nHalting...\n");
                break;
            } else if (scancode < 0x80) { // Key press (not release)
                // Simple scancode to ASCII conversion
                var ascii_char: u8 = '?';
                switch (scancode) {
                    0x1E => ascii_char = 'a',
                    0x30 => ascii_char = 'b',
                    0x2E => ascii_char = 'c',
                    0x20 => ascii_char = 'd',
                    0x12 => ascii_char = 'e',
                    0x21 => ascii_char = 'f',
                    0x22 => ascii_char = 'g',
                    0x23 => ascii_char = 'h',
                    0x17 => ascii_char = 'i',
                    0x24 => ascii_char = 'j',
                    0x25 => ascii_char = 'k',
                    0x26 => ascii_char = 'l',
                    0x32 => ascii_char = 'm',
                    0x31 => ascii_char = 'n',
                    0x18 => ascii_char = 'o',
                    0x19 => ascii_char = 'p',
                    0x10 => ascii_char = 'q',
                    0x13 => ascii_char = 'r',
                    0x1F => ascii_char = 's',
                    0x14 => ascii_char = 't',
                    0x16 => ascii_char = 'u',
                    0x2F => ascii_char = 'v',
                    0x11 => ascii_char = 'w',
                    0x2D => ascii_char = 'x',
                    0x15 => ascii_char = 'y',
                    0x2C => ascii_char = 'z',
                    0x39 => ascii_char = ' ',
                    0x1C => ascii_char = '\n',
                    else => {},
                }
                terminal.putchar(ascii_char);
            }
        }

        // Small CPU pause
        asm volatile ("pause");
    }

    // Infinite HLT loop
    while (true) {
        asm volatile ("hlt");
    }
}
