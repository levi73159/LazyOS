const io = @import("../io.zig");
const log = @import("std").log.scoped(.pic);

pub const REMAP_OFFSET = 32;

// pic1 == master
// pic2 == slave
const pic1_command_port = 0x20;
const pic1_data_port = 0x21;
const pic2_command_port = 0xa0;
const pic2_data_port = 0xa1;

// the specific end of interrupt command (see sendEndOfInterrupt function to see why this is needed)
const cmd_end_of_interrupt = 0x60;

const cmd_read_irr = 0x0a;
const cmd_read_isr = 0x0b;

// the line to which the pic2 (slave) is connected to the pic1 (master)
const pic_cascade_line = 0x02;

// Init control word 1
const icw1_expect_icw4 = 1 << 0;
const icw1_single_mode = 1 << 1;
const icw1_interval4 = 1 << 2;
const icw1_edge_trigger = 0;
const icw1_level_trigger = 1 << 3;
const icw1_initialize = 1 << 4;

// Init control word 4
const icw4_8086_mode = 1 << 0;
const icw4_auto_eoi = 1 << 1;
const icw4_buffered_master = 1 << 2;
const icw4_buffered_slave = 0;
const icw4_buffered_mode = 1 << 3;
const icw4_special_fully_nested = 1 << 4;

var interrupt_mask: u16 = 0;

pub fn config(offset_pic1: u8, offset_pic2: u8) void {
    log.debug("Configuring PIC", .{});
    log.debug("offset_pic1: {d}, offset_pic2: {d}", .{ offset_pic1, offset_pic2 });
    // Init control word 1
    io.outb(pic1_command_port, icw1_expect_icw4 | icw1_initialize);
    io.wait();
    io.outb(pic2_command_port, icw1_expect_icw4 | icw1_initialize);
    io.wait();

    // Init control word 2 - the offsets
    io.outb(pic1_data_port, offset_pic1);
    io.wait();
    io.outb(pic2_data_port, offset_pic2);
    io.wait();

    // Init control word 3
    io.outb(pic1_data_port, 0x4); // tell PIC1 (master) that is has a slave a IRQ2
    io.wait();
    io.outb(pic2_data_port, 0x2); // tell PIC2 (slave) it cascade identiy
    io.wait();

    // Init control word 4
    io.outb(pic1_data_port, icw4_8086_mode);
    io.wait();
    io.outb(pic2_data_port, icw4_8086_mode);
    io.wait();

    setMask(0);
}

fn getPort(irq: *u8) u8 {
    return if (irq.* < 8) pic1_data_port else blk: {
        irq.* -= 8;
        break :blk pic2_data_port;
    };
}

pub fn mask(irq: u8) void {
    var new_irq = irq;
    const port = getPort(&new_irq);
    const m: u8 = getMask(irq);

    io.outb(port, m | (@as(u8, 1) << @intCast(irq)));
}

pub fn unmask(irq: u8) void {
    var new_irq = irq;
    const port = getPort(&new_irq);
    const m: u8 = getMask(irq);

    io.outb(port, m & ~(@as(u8, 1) << @intCast(new_irq)));
}

pub fn setMask(m: u16) void {
    interrupt_mask = m;

    io.outb(pic1_data_port, @truncate(m & 0xFF));
    io.wait();
    io.outb(pic2_data_port, @truncate(m >> 8));
    io.wait();
}

pub fn getMask(irq: u8) u8 {
    return if (irq < 8) @truncate(interrupt_mask & 0xFF) else @truncate(interrupt_mask >> 8);
}

pub fn disable() void {
    interrupt_mask = 0xffff;
    io.outb(pic1_data_port, 0xff);
    io.wait();
    io.outb(pic2_data_port, 0xff);
    io.wait();
}

// this uses the specific end of interrupt command to signal whcih irq has been handled
// the reason why we choose this one over the non specific one is that the non specific one can be error proned and clears the highest irq
// this is not the case with the specific one it clears the specific irq that has been handled
pub fn sendEndOfInterrupt(irq: u8) void {
    if (irq < 8) {
        io.outb(pic1_command_port, cmd_end_of_interrupt | (irq & 0b111));
    } else {
        const real_irq = irq - 8;
        io.outb(pic2_command_port, cmd_end_of_interrupt | (real_irq & 0b111));
        io.outb(pic1_command_port, cmd_end_of_interrupt | pic_cascade_line);
    }
}

pub fn readIRQRequestRegister() u16 {
    io.outb(pic1_command_port, cmd_read_irr);
    io.outb(pic2_command_port, cmd_read_irr);
    return io.inb(pic2_data_port) | (io.inb(pic2_data_port) << 8);
}

pub fn readInServiceRegister() u16 {
    io.outb(pic1_command_port, cmd_read_isr);
    io.outb(pic2_command_port, cmd_read_isr);
    return io.inb(pic1_data_port) | (io.inb(pic2_data_port) << 8);
}
