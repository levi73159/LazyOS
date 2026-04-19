const Self = @This();

r: u8,
g: u8,
b: u8,

pub fn init(r: u8, g: u8, b: u8) Self {
    return Self{ .r = r, .g = g, .b = b };
}

pub fn get(self: Self) u32 {
    const r: u32 = @as(u32, self.r) << 16;
    const g: u32 = @as(u32, self.g) << 8;
    const b: u32 = @as(u32, self.b);
    return r | g | b;
}

pub fn red() Self {
    return init(255, 0, 0);
}

pub fn green() Self {
    return init(0, 255, 0);
}

pub fn blue() Self {
    return init(0, 0, 255);
}

pub fn white() Self {
    return init(255, 255, 255);
}

pub fn black() Self {
    return init(0, 0, 0);
}

pub fn yellow() Self {
    return init(255, 255, 0);
}

pub fn magenta() Self {
    return init(255, 0, 255);
}

pub fn cyan() Self {
    return init(0, 255, 255);
}

pub fn gray() Self {
    return init(128, 128, 128);
}
