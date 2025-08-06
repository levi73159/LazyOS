const Color = @This();

red: u8,
green: u8,
blue: u8,
reserved: u8,

/// Get the values of the color as u32
pub fn getInt(self: Color, pxl_fmt: u32) u32 {
    const red: u32 = self.red;
    const green: u32 = self.green;
    const blue: u32 = self.blue;
    const reserved: u32 = self.reserved;
    switch (pxl_fmt) {
        0 => {
            // RedGreenBlueReserved8BitPerColor
            return red + (green << 8) + (blue << 16) + (reserved << 24);
        },
        1 => {
            // BlueGreenRedReserved8BitPerColor
            return blue + (green << 8) + (red << 16) + (reserved << 24);
        },
        else => {
            // nothing
            @panic("Unsupported pixel format");
        },
    }
}
