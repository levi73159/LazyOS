const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch.zig");
const io = @import("arch.zig").io;
const console = @import("console.zig");
const hal = @import("hal.zig");
const kb = @import("keyboard.zig");
const mouse = @import("mouse.zig");
const pit = @import("pit.zig");
const BootInfo = @import("arch/bootinfo.zig").BootInfo;
const paging = @import("arch/paging.zig");
const acpi = arch.acpi;
const scheduler = @import("scheduler.zig");
const serial = @import("arch/serial.zig");
const pmem = @import("memory/pmem.zig");
const Iso9660 = @import("fs/Iso9660.zig");
const Disk = @import("Disk.zig");
const FileSystem = @import("fs/FileSystem.zig");
const ui = @import("ui.zig");
const Shell = @import("Shell.zig");

const acpi_oslevel = @import("acpi/osl.zig"); // NOTE: MUST BE IMPORTED FIRST FOR ACPI TO WORK
comptime {
    _ = acpi_oslevel; // force import
}

const heap = @import("memory/heap.zig");

const Screen = @import("Screen.zig");
const Color = @import("Color.zig");

const regs = arch.registers;

const log = std.log.scoped(.kernel);

pub fn _start(mb: *const BootInfo) callconv(.c) void {
    // const kernel_start: usize = @intFromPtr(&__kernel_start);
    // const kernel_end: usize = @intFromPtr(&__kernel_end);
    // arch.paging.init(kernel_start, kernel_end);
    var serial_writer = serial.SerialWriter.init(.COM1);
    const writer = &serial_writer.writer;
    console.initSerial(writer);

    console.dbg("Init Kernel\n");
    log.debug("Initializing kernel components...\n", .{});
    hal.earlyInit();

    log.debug("Kerenl location: physical 0x{x} virtual 0x{x}", .{ mb.kernel.phys_addr, mb.kernel.virt_addr });

    pmem.init(mb);
    paging.init(mb);
    heap.init();

    pit.init(100);
    hal.init();

    const framebuffer = mb.getFramebuffer(u32);

    const screen = Screen.init(framebuffer, mb.framebuffer);
    screen.use_double_buffer = true;
    screen.createDoubleBuffer() catch |err| {
        log.err("Failed to create double buffer: {s}", .{@errorName(err)});
    };

    var disk = Disk.init(1) catch |err| {
        log.err("Failed to init disk: {s}", .{@errorName(err)});
        io.hlt();
    };

    // init file system on disk 1 (boot disk)
    const fs = FileSystem.init(&disk) catch |err| {
        log.err("Failed to init file system: {s}", .{@errorName(err)});
        io.hlt();
    };
    FileSystem.setGlobal(fs);

    ui.init(FileSystem.getGlobal(), "ui", heap.allocator()) catch |err| {
        log.err("Failed to init UI Components: {s}", .{@errorName(err)});
        io.hlt();
    };

    console.init(screen);
    console.clear();
    console.echoToHost(true); // echo all prints to the host

    // init hardware
    // pit timer 100Hz
    kb.init();
    mouse.init();

    const cpu = arch.CPU.init() catch |err| blk: {
        log.err("Failed to get the CPU: {s}", .{@errorName(err)});
        break :blk arch.CPU.unknown;
    };
    _ = cpu;

    console.echoToHost(false);

    scheduler.init();

    io.sti();
    mainWrapper();
    while (true) {}
    std.log.debug("HALTING", .{});
    io.hlt();
}

fn blinkTask() callconv(.c) void {
    const screen = Screen.get();
    var tick: u32 = 0;
    while (true) {
        const c = if (tick % 2 == 0) Color.red() else Color.blue();
        screen.drawRect(0, 0, 20, 20, c);
        screen.swapBuffers();
        // busy wait ~100ms
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) {
            asm volatile ("pause");
        }
        tick += 1;
    }
}

fn returnTask() callconv(.c) void {
    const screen = Screen.get();
    var tick: u32 = 0;
    while (true) {
        if (tick == 10) return;
        const c = if (tick % 2 == 0) Color.red() else Color.blue();
        screen.drawRect(100, 100, 20, 20, c);
        screen.swapBuffers();
        // busy wait ~100ms
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) {
            asm volatile ("pause");
        }
        tick += 1;
    }
}

inline fn color(r: u32, g: u32, b: u32) u32 {
    return (r << 16) | (g << 8) | b;
}

fn getFreeRegion(map: []arch.bootinfo.MemoryMapEntry) ?arch.bootinfo.MemoryMapEntry {
    for (map) |entry| {
        if (entry.type == .available and entry.addr != 0) {
            return entry;
        }
    }

    return null;
}

fn mainWrapper() callconv(.c) noreturn {
    const screen = Screen.get();
    main(screen) catch |err| {
        std.log.scoped(.host).err("Main failed: {s}", .{@errorName(err)});
    };
    acpi.shutdown();
    while (true) {
        asm volatile ("hlt");
    }
}

fn main(_: *Screen) !void {
    std.log.debug("main", .{});
    const is64bit = builtin.target.cpu.arch == .x86_64;
    if (is64bit) {
        console.print("Welcome to LazyOS 64-bit\n", .{});
    } else {
        console.print("Welcome to LazyOS 32-bit\n", .{});
    }
    console.print("Initializing shell...\n", .{});

    var shell = Shell.init(heap.allocator(), FileSystem.getGlobal());
    shell.inputLoop() catch |err| {
        std.log.scoped(.host).err("Shell failed: {s}", .{@errorName(err)});
    };
}

fn drawLoop(screen: *Screen) void {
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
