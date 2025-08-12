const std = @import("std");
const isr = @import("isr.zig");
const pic = @import("pic.zig");
const io = @import("../io.zig");

const log = @import("std").log.scoped(.irq);

const InterruptFrame = @import("registers.zig").InterruptFrame;

const Handler = *const fn (frame: *InterruptFrame) void;

var handlers: [16]?Handler = [_]?Handler{null} ** 16;

pub fn init() void {
    log.debug("Initializing IRQs", .{});
    pic.config(pic.REMAP_OFFSET, pic.REMAP_OFFSET + 8);

    // registers ISR handlers for each of the 16 IRQs lines
    for (0..16) |i| {
        isr.register(@intCast(pic.REMAP_OFFSET + i), &irqHandler);
    }
}

fn irqHandler(frame: *InterruptFrame) void {
    const irq: u8 = @intCast(frame.interrupt_number - pic.REMAP_OFFSET);
    if (irq != 0) {
        log.debug("IRQ {d} aka {d}", .{ irq, frame.interrupt_number });
    }
    // just to be safe we make sure the irq is in range
    if (irq >= handlers.len) {
        std.debug.panic("IRQ {d} out of range, 0-{d}", .{ irq, handlers.len - 1 });
    }

    if (handlers[irq]) |func| {
        func(frame);
    } else {
        log.debug("IRQ {d} unhandled", .{irq});
    }

    pic.sendEndOfInterrupt(irq);
}

pub fn register(irq: u8, handler: Handler) void {
    // don't worry about error because we know the irq is valid if this function is called (user fault if not)
    handlers[irq] = handler;
}

pub fn unregister(irq: u8) void {
    handlers[irq] = null;
}
