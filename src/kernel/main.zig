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
const pmem = @import("memory/pmem.zig");
const paging = @import("arch/paging.zig");
const commands = @import("commands.zig");
const acpi = arch.acpi;
const scheduler = @import("scheduler.zig");
const serial = @import("arch/serial.zig");

const acpi_oslevel = @import("acpi/osl.zig"); // NOTE: MUST BE IMPORTED FIRST FOR ACPI TO WORK
comptime {
    _ = acpi_oslevel; // force import
}

const c = @cImport({
    @cInclude("uacpi/acpi.h");
});

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
    pmem.init(mb.memory_map, mb.hhdm_offset);
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

    console.init(screen);
    console.clear();
    console.echoToHost(true); // echo all prints to the host

    // init hardware
    // pit timer 100Hz
    kb.init();

    const cpu = arch.CPU.init() catch |err| blk: {
        log.err("Failed to get the CPU: {s}", .{@errorName(err)});
        break :blk arch.CPU.unknown;
    };
    _ = cpu;

    console.echoToHost(false);

    scheduler.init();
    scheduler.addTask(&mainWrapper);
    // mainWrapper();
    io.sti();
    while (true) {}
    std.log.debug("HALTING", .{});
    io.hlt();
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

pub fn testHeap() void {
    var linked_list = heap.LinkedList.init();
    defer linked_list.deinit();
    const allocator = linked_list.allocator();
    var passed: u32 = 0;
    var failed: u32 = 0;

    // helper to report results
    const pass = struct {
        fn f(name: []const u8, p: *u32) void {
            console.print("[PASS] {s}\n", .{name});
            p.* += 1;
        }
    }.f;
    const fail = struct {
        fn f(name: []const u8, p: *u32) void {
            console.print("[FAIL] {s}\n", .{name});
            p.* += 1;
        }
    }.f;

    // ── test 1: basic alloc and free ─────────────────────────────────────────
    {
        log.debug("testing basic alloc and free", .{});
        const ptr = allocator.create(u32) catch {
            fail("basic alloc", &failed);
            return;
        };
        ptr.* = 0xDEADBEEF;
        if (ptr.* == 0xDEADBEEF) pass("basic alloc/write/read", &passed) else fail("basic alloc/write/read", &failed);
        allocator.destroy(ptr);
        pass("basic free", &passed);
    }

    // ── test 2: multiple allocs ───────────────────────────────────────────────
    {
        log.debug("testing multiple allocs", .{});
        const a = allocator.create(u32) catch {
            fail("multi alloc a", &failed);
            return;
        };
        const b = allocator.create(u32) catch {
            fail("multi alloc b", &failed);
            return;
        };
        const cc = allocator.create(u32) catch {
            fail("multi alloc c", &failed);
            return;
        };
        a.* = 1;
        b.* = 2;
        cc.* = 3;
        if (a.* == 1 and b.* == 2 and cc.* == 3)
            pass("multiple allocs", &passed)
        else
            fail("multiple allocs", &failed);
        // make sure they don't overlap
        if (@intFromPtr(a) != @intFromPtr(b) and
            @intFromPtr(b) != @intFromPtr(cc) and
            @intFromPtr(a) != @intFromPtr(cc))
            pass("no overlap", &passed)
        else
            fail("no overlap", &failed);
        allocator.destroy(a);
        allocator.destroy(b);
        allocator.destroy(cc);
    }

    // ── test 3: free and realloc ──────────────────────────────────────────────
    {
        log.debug("testing free and realloc", .{});
        const a = allocator.create(u32) catch {
            fail("realloc test", &failed);
            return;
        };
        const addr_a = @intFromPtr(a);
        allocator.destroy(a);
        const b = allocator.create(u32) catch {
            fail("realloc test", &failed);
            return;
        };
        // after freeing a, allocating again should reuse that block
        if (@intFromPtr(b) == addr_a)
            pass("reuse freed block", &passed)
        else
            fail("reuse freed block (may be ok if roving pointer)", &failed);
        allocator.destroy(b);
    }

    // ── test 4: alignment ─────────────────────────────────────────────────────
    {
        log.debug("testing alignment", .{});
        log.debug("align of u8: {d}", .{@alignOf(u8)});
        const a = allocator.create(u8) catch {
            fail("align u8", &failed);
            return;
        };
        log.debug("align of u16: {d}", .{@alignOf(u16)});
        const b = allocator.create(u16) catch {
            fail("align u16", &failed);
            return;
        };
        log.debug("align of u32: {d}", .{@alignOf(u32)});
        const cc = allocator.create(u32) catch {
            fail("align u32", &failed);
            return;
        };
        log.debug("align of u64: {d}", .{@alignOf(u64)});
        const d = allocator.create(u64) catch {
            fail("align u64", &failed);
            return;
        };
        log.debug("align of u128: {d}", .{@alignOf(u128)});
        const e = allocator.create(u128) catch {
            fail("align u128", &failed);
            return;
        };

        const ok =
            std.mem.isAligned(@intFromPtr(a), @alignOf(u8)) and
            std.mem.isAligned(@intFromPtr(b), @alignOf(u16)) and
            std.mem.isAligned(@intFromPtr(cc), @alignOf(u32)) and
            std.mem.isAligned(@intFromPtr(d), @alignOf(u64)) and
            std.mem.isAligned(@intFromPtr(e), @alignOf(u128));

        if (ok) pass("alignment", &passed) else fail("alignment", &failed);
        allocator.destroy(a);
        allocator.destroy(b);
        allocator.destroy(cc);
        allocator.destroy(d);
        allocator.destroy(e);
    }

    // ── test 5: slice alloc ───────────────────────────────────────────────────
    {
        log.debug("testing size alloc", .{});
        const slice = allocator.alloc(u32, 16) catch {
            fail("slice alloc", &failed);
            return;
        };
        for (slice, 0..) |*v, i| v.* = @intCast(i);
        var ok = true;
        for (slice, 0..) |v, i| if (v != @as(u32, @intCast(i))) {
            ok = false;
            break;
        };
        if (ok) pass("slice alloc/write/read", &passed) else fail("slice alloc/write/read", &failed);
        allocator.free(slice);
    }

    // ── test 6: large alloc (forces multiple pages) ───────────────────────────
    {
        log.debug("testing large alloc", .{});
        const large = allocator.alloc(u8, 8192) catch {
            fail("large alloc", &failed);
            return;
        };
        log.debug("large range: {x} - {x}", .{ @intFromPtr(large.ptr), @intFromPtr(large.ptr) + large.len });
        log.debug("1", .{});

        const screen = Screen.get();
        log.debug("console buffer: {x} - {x}", .{ @intFromPtr(screen.buffer.ptr), @intFromPtr(screen.buffer.ptr) + screen.buffer.len });
        log.debug("double buffer: {x} - {x}", .{ @intFromPtr(screen.double_buffer.?.ptr), @intFromPtr(screen.double_buffer.?.ptr) + screen.double_buffer.?.len });

        if (large.len == 8192) {
            pass("large alloc size", &passed);
        } else {
            fail("large alloc size", &failed);
        }
        log.debug("1.2", .{});
        // write and verify
        for (large, 0..) |*v, i| {
            v.* = @truncate(i);
        }
        var ok = true;
        for (large, 0..) |v, i| if (v != @as(u8, @truncate(i))) {
            ok = false;
            break;
        };
        log.debug("1.5", .{});
        if (ok) pass("large alloc write/read", &passed) else fail("large alloc write/read", &failed);
        log.debug("2", .{});

        allocator.free(large);
        log.debug("3", .{});
    }

    // ── test 7: stress test ───────────────────────────────────────────────────
    {
        log.debug("testing stress test", .{});
        var ptrs: [32]*u64 = undefined;
        var ok = true;

        // alloc all
        for (&ptrs, 0..) |*p, i| {
            p.* = allocator.create(u64) catch {
                ok = false;
                break;
            };
            p.*.* = i;
        }

        // verify all
        if (ok) {
            for (ptrs, 0..) |p, i| {
                if (p.* != i) {
                    ok = false;
                    break;
                }
            }
        }

        // free all
        if (ok) for (ptrs) |p| allocator.destroy(p);

        if (ok) pass("stress test 32 allocs", &passed) else fail("stress test 32 allocs", &failed);
    }

    // ── test 8: merging (coalescing) ──────────────────────────────────────────
    {
        log.debug("testing merging", .{});
        const a = allocator.create(u64) catch {
            fail("coalesce", &failed);
            return;
        };
        const b = allocator.create(u64) catch {
            fail("coalesce", &failed);
            return;
        };
        const cc = allocator.create(u64) catch {
            fail("coalesce", &failed);
            return;
        };
        allocator.destroy(a);
        allocator.destroy(b);
        allocator.destroy(cc);
        // now try to alloc something big — should fit in coalesced space
        const big = allocator.alloc(u64, 3) catch {
            fail("coalesce alloc after free", &failed);
            return;
        };
        pass("coalesce", &passed);
        allocator.free(big);
    }

    // ── results ───────────────────────────────────────────────────────────────
    console.print("\nHeap test results: {d} passed, {d} failed\n", .{ passed, failed });
    if (failed == 0) {
        console.print("ALL HEAP TESTS PASSED\n", .{});
    }
}

fn mainWrapper() noreturn {
    const screen = Screen.get();
    main(screen) catch |err| {
        std.log.scoped(.host).err("Main failed: {s}", .{@errorName(err)});
    };
    std.log.scoped(.host).err("Shutting down", .{});
    acpi.shutdown();
    while (true) {
        asm volatile ("hlt");
    }
}

fn main(screen: *Screen) !void {
    std.log.debug("main", .{});
    log.debug("shutting down", .{});
    const is64bit = builtin.target.cpu.arch == .x86_64;
    if (is64bit) {
        console.print("Welcome to LazyOS 64-bit\n", .{});
    } else {
        console.print("Welcome to LazyOS 32-bit\n", .{});
    }
    console.print("Type 'help' for a list of commands\n", .{});

    var buf: [256]u8 = undefined;
    while (true) {
        console.write("> ");
        const line = console.readline(&buf, true) catch |err| switch (err) {
            error.BufferOverflow => {
                console.print("Err: Command too long\n", .{});
                continue;
            },
        };
        console.write("\n");

        if (std.mem.eql(u8, line, "draw")) {
            console.clear(); // clears the console
            drawLoop(screen);
            continue;
        }

        const cmd_name = line[0 .. std.mem.indexOf(u8, line, " ") orelse line.len];

        for (commands.commands) |cmd| {
            if (std.mem.eql(u8, cmd_name, cmd.name)) {
                cmd.handler(line) catch |err| {
                    log.err("Command failed: {s}", .{@errorName(err)});
                };
                break;
            }
        } else {
            log.err("Unknown command: {s}", .{line});
            log.info("Try 'help'", .{});
        }
    }
}

fn drawLoop(screen: *Screen) void {
    screen.use_double_buffer = true;
    defer screen.use_double_buffer = false;

    defer kb.flush();

    var x: u32 = 0;
    var y: u32 = 0;

    while (true) {
        screen.clear(Color.white());
        screen.drawRectWithBorder(x, y, 600, 500, Color.green(), 5, Color.blue());
        screen.drawRect(x + 5, y + 5, 600 - 10, 30, Color.gray()); // draw window bar
        screen.drawText(x + 16, y + 5, "Test window", 2, Color.white());

        screen.drawRect(@intCast(mouse.x()), @intCast(mouse.y()), 10, 10, Color.red());

        screen.swapBuffers();

        if (kb.getKeyDown(.w)) y -|= 5;
        if (kb.getKeyDown(.s)) y += 5;
        if (kb.getKeyDown(.a)) x -|= 5;
        if (kb.getKeyDown(.d)) x += 5;
        if (kb.getKeyDown(.q))
            break;
    }
}
