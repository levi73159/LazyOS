const FBCon = @import("./FBCon.zig");
const log = @import("std").log.scoped(.term_fbcon_decsed);

/// Erase in Display
pub fn eraseInDisplay(self: *FBCon, control_sequence: FBCon.ControlSequence) void {
    if (control_sequence.args[0]) |arg| {
        switch (arg) {
            .number => |num| {
                switch (num) {
                    0 => {
                        const total_size: usize = self.pixels_per_scanline * self.pixel_height;
                        const start: usize = self.font.width * self.curpos.column + (self.pixels_per_scanline * self.font.height * self.curpos.row);
                        @memset(self.framebuffer_pointer[start..total_size], 0);
                    },
                    1 => {
                        const start: usize = self.font.width * self.curpos.column + (self.pixels_per_scanline * self.font.height * self.curpos.row);
                        @memset(self.framebuffer_pointer[0..start], 0);
                    },
                    2 => {
                        const total_size: usize = self.pixels_per_scanline * self.pixel_height;
                        @memset(self.framebuffer_pointer[0..total_size], 0);
                        self.curpos.column = 0;
                        self.curpos.row = 0;
                    },
                    else => log.warn("Wrong argument value, skipping", .{}),
                }
            },
            .char => log.warn("Wrong argument type, skipping", .{}),
        }
    }
}
