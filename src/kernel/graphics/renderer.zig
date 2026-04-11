const std = @import("std");
const Screen = @import("Screen.zig");
const root = @import("root");

const kb = root.dev.keyboard;
const mouse = root.dev.mouse;

const acpi = root.acpi;
const console = root.console;
const io = root.io;

const ui = @import("ui.zig");
const Color = @import("Color.zig");
const Element = @import("Element.zig");

const log = std.log.scoped(._renderer);

pub const State = struct {
    cursor_texture: *const ui.Texture,
    elements: std.ArrayList(Element),
    allocator: std.mem.Allocator,

    update_listerner: ?*const fn (*Screen, *State) anyerror!void = null,
};

var state: State = undefined;
var initialized = false;

pub fn init(allocator: std.mem.Allocator) void {
    state = State{
        .cursor_texture = ui.get("CURSOR") orelse @panic("Cursor texture not found"),
        .elements = std.ArrayList(Element).empty,
        .allocator = allocator,
        .update_listerner = null,
    };

    initialized = true;
}

pub inline fn isInitialized() bool {
    return initialized;
}

pub fn drawLoop(screen: *Screen) void {
    if (!initialized) {
        @panic("Renderer not initialized");
    }

    console.echoToHost(true); // set echo to host since we won't be able to see the shell
    defer console.echoToHost(false);

    const old_double_buffer = screen.use_double_buffer;
    screen.use_double_buffer = true;
    defer screen.use_double_buffer = old_double_buffer;

    defer kb.flush();

    mouse.resetState();
    mouse.addClamp(screen.width - 2, screen.height - 2);

    const power_texture = ui.get("POWER");
    if (power_texture == null) {
        std.log.scoped(.host).err("Power texture not found", .{});
    }

    const cursor = state.cursor_texture;

    while (true) {
        const mouse_x = mouse.x();
        const mouse_y = mouse.y();
        io.cli();
        screen.clear(Color.white());
        io.sti();

        if (state.update_listerner) |update| {
            update(screen, &state) catch |err| {
                if (err == error.OutOfMemory) {
                    @panic("Out of memory");
                }
                if (err == error.Exit) {
                    return;
                }
                log.err("Failed to update: {}", .{err});
                continue;
            };
        }

        for (state.elements.items) |element| {
            const pos = element.absolutePosition(screen);
            screen.drawTexture(pos.x, pos.y, element.tex);
        }

        screen.drawTexture(mouse_x, mouse_y, cursor);
        io.cli();
        screen.swapBuffers();
        mouse.updateMouse();
        io.sti();

        if (kb.getKeyDown(.q))
            break;
    }
}

pub fn subscribeToUpdates(listener: *const fn (*Screen, *State) anyerror!void) void {
    state.update_listerner = listener;
}

pub fn addElement(element: Element) !void {
    try state.elements.append(state.allocator, element);
}

pub fn getElement(idx: u32) Element {
    return state.elements.items[idx];
}
