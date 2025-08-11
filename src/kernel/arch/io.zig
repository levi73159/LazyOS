const unused_port = 0x80;

pub fn in(comptime Type: type, port: u16) Type {
    return switch (Type) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("Invalid data type. Only u8, u16 or u32, found: " ++ @typeName(Type)),
    };
}

pub fn out(port: u16, data: anytype) void {
    switch (@TypeOf(data)) {
        u8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("Invalid data type. Only u8, u16 or u32, found: " ++ @typeName(@TypeOf(data))),
    }
}

pub fn outb(port: u16, data: u8) void {
    out(port, data);
}

pub fn outw(port: u16, data: u16) void {
    out(port, data);
}

pub fn outl(port: u16, data: u32) void {
    out(port, data);
}

pub fn inb(port: u16) u8 {
    return in(u8, port);
}

pub fn inw(port: u16) u16 {
    return in(u16, port);
}

pub fn inl(port: u16) u32 {
    return in(u32, port);
}

pub fn hlt() noreturn {
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
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

pub fn wait() void {
    outb(unused_port, 0);
}
