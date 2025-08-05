const vga = @import("vga.zig");
const terminal = @import("terminal.zig");

export fn main() noreturn {
    // Initialize VGA text mode
    terminal.init();

    // Print startup messages
    terminal.setColor(.light_cyan);
    terminal.write("LazyOS v0.1.0");

    while (true) {}
}
