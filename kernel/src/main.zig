const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const dev = root.dev;

const acpi_oslevel = @import("acpi/osl.zig");
const acpi = root.acpi;
const arch = root.arch;
const BootInfo = arch.bootinfo.BootInfo;
const paging = arch.paging;
const serial = root.dev.serial;
const console = root.console;
const Disk = root.dev.Disk;
const FileSystem = root.fs.FileSystem;
const renderer = root.graphics.renderer;
const Screen = root.graphics.Screen;
const ui = root.graphics.ui;
const hal = @import("hal.zig");
const io = root.io;
const kb = root.dev.keyboard;
const heap = root.heap;
const pmem = root.pmem;
const mouse = root.dev.mouse;
const pit = arch.pit;
const scheduler = root.proc.scheduler;
const Shell = root.Shell;
const TTY = root.dev.TTY;

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
    const vmem = paging.init(mb);
    heap.init();
    heap.addRegions();

    paging.addKernelRegions(vmem, mb);

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

    root.dev.pci.emunerate();

    screen.use_double_buffer = true;
    screen.createDoubleBuffer() catch |err| {
        log.err("Failed to create double buffer: {s}", .{@errorName(err)});
        screen.use_double_buffer = false; // fall back to dirrect rendering
    };
    if (screen.use_double_buffer) {
        console.clear();
    }

    blk: {
        const ahci = root.dev.disks.ahci;
        var ports_buf: [32]?ahci.Port = undefined;
        const ports = ahci.init(allocator, &ports_buf) catch |err| {
            log.warn("Failed to init ahci: {s}", .{@errorName(err)}); // on legacy systems we don't have ahci, but that's ok (somtimes)
            break :blk;
        };
        Disk.loadAHCIPorts(&ports_buf, ports.len);
    }

    Disk.loadDisks();

    const disk = Disk.get(0);
    if (disk) |d| {
        root.dev.disks.gpt.parse(d, allocator) catch |err| {
            log.err("Failed to parse GPT: {s}", .{@errorName(err)});
        };
    }

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
    if (disk) |d| blk: {
        const fs = FileSystem.init(d) catch |err| {
            log.err("Failed to init file system: {s}", .{@errorName(err)});
            break :blk;
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
            acpi.shutdown();
            return error.ShutdownFailed;
        }
    }

    if (kb.getKeyDown(.esc)) {
        return error.Exit;
    }
}
