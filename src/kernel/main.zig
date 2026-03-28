const std = @import("std");
const builtin = @import("builtin");

const acpi_oslevel = @import("acpi/osl.zig");
const arch = @import("arch.zig");
const BootInfo = @import("arch/bootinfo.zig").BootInfo;
const paging = @import("arch/paging.zig");
const serial = @import("arch/serial.zig");
const console = @import("console.zig");
const Disk = @import("Disk.zig");
const FileSystem = @import("fs/FileSystem.zig");
const renderer = @import("graphics/renderer.zig");
const Screen = @import("graphics/Screen.zig");
const ui = @import("graphics/ui.zig");
const hal = @import("hal.zig");
const io = @import("arch.zig").io;
const kb = @import("keyboard.zig");
const heap = @import("memory/heap.zig");
const pmem = @import("memory/pmem.zig");
const mouse = @import("mouse.zig");
const pit = @import("pit.zig");
const scheduler = @import("scheduler.zig");
const Shell = @import("Shell.zig");

// NOTE: MUST BE IMPORTED FIRST FOR ACPI TO WORK
comptime {
    _ = acpi_oslevel; // force import
}

const log = std.log.scoped(.kernel);

pub fn _start(mb: *const BootInfo) callconv(.c) void {
    // const kernel_start: usize = @intFromPtr(&__kernel_start);
    // const kernel_end: usize = @intFromPtr(&__kernel_end);
    // arch.paging.init(kernel_start, kernel_end);
    var serial_writer = serial.SerialWriter.init(.COM1);
    if (serial_writer != null) {
        const writer = &serial_writer.?.writer;
        console.initSerial(writer);
    }

    console.dbg("Init Kernel\n");
    log.debug("Initializing kernel components...\n", .{});
    hal.earlyInit();

    log.debug("Kerenl location: physical 0x{x} virtual 0x{x}", .{ mb.kernel.phys_addr, mb.kernel.virt_addr });

    pmem.init(mb);
    paging.init(mb);
    heap.init();

    pit.init(100);
    hal.init();
    kb.init();
    mouse.init();
    scheduler.init();

    @import("pci.zig").emunerate();

    const framebuffer = mb.getFramebuffer(u32);

    const allocator = heap.allocator();

    const screen = Screen.init(framebuffer, mb.framebuffer);
    screen.use_double_buffer = true;
    screen.createDoubleBuffer() catch |err| {
        log.err("Failed to create double buffer: {s}", .{@errorName(err)});
    };

    console.init(screen);
    console.clear();
    console.echoToHost(true); // echo all prints to the host

    if (serial_writer == null) {
        console.write("No serial port found\n");
    }

    blk: {
        const ahci = @import("disks/ahci.zig");
        var ports_buf: [32]?ahci.Port = undefined;
        const ports = ahci.init(allocator, &ports_buf) catch |err| {
            log.warn("Failed to init ahci: {s}", .{@errorName(err)}); // on legacy systems we don't have ahci, but that's ok (somtimes)
            break :blk;
        };
        Disk.loadAHCIPorts(&ports_buf, ports.len);
    }

    var disk = Disk.init(2) catch |err| {
        log.err("Failed to init disk: {s}", .{@errorName(err)});
        io.hltNoInt();
    };

    // init file system on disk 1 (boot disk)
    const fs = FileSystem.init(&disk) catch |err| {
        log.err("Failed to init file system: {s}", .{@errorName(err)});
        io.hltNoInt();
    };
    FileSystem.setGlobal(fs);

    ui.init(FileSystem.getGlobal(), "ui", allocator) catch |err| {
        log.err("Failed to init UI Components: {s}", .{@errorName(err)});
        io.hltNoInt();
    };

    renderer.init(allocator);
    renderer.addElement(.initNamed(.{ .relative = .{
        .x = -10,
        .y = 10,
        .anchor = .top_right,
    } }, "POWER")) catch |err| {
        log.err("Failed to add power button: {s}", .{@errorName(err)});
    };

    renderer.subscribeToUpdates(&update);

    const cpu = arch.CPU.init() catch |err| blk: {
        log.err("Failed to get the CPU: {s}", .{@errorName(err)});
        break :blk arch.CPU.unknown;
    };
    _ = cpu;

    console.echoToHost(false);

    io.sti();
    mainWrapper();
    while (true) {}
    std.log.debug("HALTING", .{});
    io.hlt();
}

fn mainWrapper() callconv(.c) noreturn {
    const screen = Screen.get();
    main(screen) catch |err| {
        std.log.scoped(.host).err("Main failed: {s}", .{@errorName(err)});
    };
    arch.acpi.shutdown();
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

    console.print("Optimize mode: {s}\n", .{@tagName(builtin.mode)});
    console.print("Initializing shell...\n", .{});

    var shell = Shell.init(heap.allocator(), FileSystem.getGlobal());
    shell.inputLoop() catch |err| {
        std.log.scoped(.host).err("Shell failed: {s}", .{@errorName(err)});
    };
}

fn update(screen: *Screen, state: *renderer.State) anyerror!void {
    if (state.elements.items.len > 0) {
        const power_button = state.elements.items[0];

        const mouse_state = power_button.getMouseState(screen);

        if (mouse_state.left_clicked) {
            arch.acpi.shutdown();
            return error.ShutdownFailed;
        }
    }
}
