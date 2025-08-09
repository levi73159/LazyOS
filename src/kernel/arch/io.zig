pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn hlt() noreturn {
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

pub fn cli() void {
    asm volatile ("cli");
}

pub fn sti() void {
    asm volatile ("sti");
}

pub fn setCursor(x: u16, y: u16, width: u16) void {
    const pos = @as(u16, y) * width + x;

    // Cursor low byte
    outb(0x3D4, 0x0F);
    outb(0x3D5, @truncate(pos & 0xFF));

    // Cursor high byte
    outb(0x3D4, 0x0E);
    outb(0x3D5, @truncate((pos >> 8) & 0xFF));
}
