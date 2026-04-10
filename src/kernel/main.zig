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
const TTY = @import("fs/TTY.zig");

// NOTE: MUST BE IMPORTED FIRST FOR ACPI TO WORK
comptime {
    _ = acpi_oslevel; // force import
}

const log = std.log.scoped(.kernel);

pub fn _start(mb: *const BootInfo) callconv(.c) void {
    // const kernel_start: usize = @intFromPtr(&__kernel_start);
    // const kernel_end: usize = @intFromPtr(&__kernel_end);
    // arch.paging.init(kernel_start, kernel_end);
    const screen = Screen.init(mb.getFramebuffer(u32), mb.framebuffer);

    const serial_writer = serial.SerialWriter.init(.COM1);
    if (serial_writer != null) {
        console.initSerial(serial_writer.?);
    }
    console.init(screen);
    console.clear();
    console.logDebug(true);
    console.echoToHost(true); // echo all prints to the host

    if (serial_writer == null) {
        console.write("No serial port found\n");
    }

    console.dbg("Init Kernel\n");
    log.debug("Initializing kernel components...\n", .{});

    hal.earlyInit();

    log.debug("Kerenl location: physical 0x{x} virtual 0x{x}", .{ mb.kernel.phys_addr, mb.kernel.virt_addr });

    pmem.init(mb);
    heap.init();
    const vmem = paging.init(mb);
    heap.addRegions();

    log.debug("Framebuffer address: {x}", .{@intFromPtr(screen.buffer.ptr)});

    const allocator = heap.allocator();
    // add guard pages
    {
        const boot = @import("boot.zig");
        vmem.addGuardPage(allocator, "Kernel Stack overflow", @intFromPtr(&boot.kernel_stack));
        const frame_buffer_addr = @intFromPtr(screen.buffer.ptr);
        const frame_buffer_size = screen.buffer.len * 4;

        const upper_frame_buffer = frame_buffer_addr + frame_buffer_size + 4096;
        const below_frame_buffer = frame_buffer_addr - 4096;

        vmem.addGuardPage(allocator, "Framebuffer high guard", upper_frame_buffer);
        vmem.addGuardPage(allocator, "Framebuffer low guard", below_frame_buffer);
    }

    console.logDebug(false);
    pit.init(100);
    hal.init();
    kb.init();
    mouse.init();
    scheduler.init();
    _ = scheduler.addTaskFunc(&TTY.ttyKeyTask, .{});
    console.logDebug(true);

    @import("pci.zig").emunerate();

    screen.use_double_buffer = true;
    screen.createDoubleBuffer() catch |err| {
        log.err("Failed to create double buffer: {s}", .{@errorName(err)});
        screen.use_double_buffer = false; // fall back to dirrect rendering
    };
    if (screen.use_double_buffer) {
        console.clear();
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

    Disk.loadDisks();

    const disk = Disk.get(2);

    blk: {
        ui.init(allocator) catch |err| {
            log.err("Failed to init UI: {s}", .{@errorName(err)});
            break :blk;
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
    }

    // init file system on disk
    if (disk) |d| {
        const fs = FileSystem.init(d) catch |err| {
            log.err("Failed to init file system: {s}", .{@errorName(err)});
            io.hltNoInt();
        };
        FileSystem.setGlobal(fs);
    }

    const cpu = arch.CPU.init() catch |err| blk: {
        log.err("Failed to get the CPU: {s}", .{@errorName(err)});
        break :blk arch.CPU.unknown;
    };
    _ = cpu;

    // enable syscalls
    arch.syscall.init();

    console.echoToHost(false);
    console.logDebug(false);

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

    var shell = Shell.init(heap.allocator(), if (FileSystem.isInitialized()) FileSystem.getGlobal() else null);
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

    if (kb.getKeyDown(.esc)) {
        return error.Exit;
    }
}
