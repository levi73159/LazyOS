const std = @import("std");
const Screen = @import("Screen.zig");
const kb = @import("../keyboard.zig");
const acpi = @import("../arch/acpi.zig");

const mouse = @import("../mouse.zig");
const ui = @import("ui.zig");
const Color = @import("Color.zig");

pub fn drawLoop(screen: *Screen) void {
    screen.use_double_buffer = true;
    defer screen.use_double_buffer = false;

    defer kb.flush();

    mouse.resetState();
    mouse.addClamp(screen.width, screen.height);

    const power_texture = ui.get("POWER");
    if (power_texture == null) {
        std.log.scoped(.host).err("Power texture not found", .{});
    }

    const cursor = ui.get("CURSOR") orelse @panic("Cursor texture not found");

    var mouse_color = Color.black();
    while (true) {
        const mouse_x = mouse.x();
        const mouse_y = mouse.y();
        screen.clear(Color.white());

        if (power_texture) |tex| {
            const x = screen.width / 2;
            const y = screen.height / 2;
            screen.drawTexture(x, y, tex);

            const tex_left = x;
            const tex_right = x + tex.width;

            const tex_top = y;
            const tex_bottom = y + tex.height;

            if (mouse_x >= tex_left and mouse_x <= tex_right and mouse_y >= tex_top and mouse_y <= tex_bottom) {
                mouse_color = Color.green();
                if (mouse.isButtonJustPressed(.left)) {
                    acpi.shutdown();
                }
            } else {
                mouse_color = Color.black();
            }
        }

        screen.drawTexture(mouse_x, mouse_y, cursor);
        screen.swapBuffers();
        mouse.updateMouse();

        if (kb.getKeyDown(.q))
            break;
    }
}
