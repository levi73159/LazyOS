const std = @import("std");
const arch = @import("../arch.zig");
const heap = @import("../memory/heap.zig");
const scheduler = @import("../scheduler.zig");
const bootinfo = arch.bootinfo;
const limine = arch.limine;
const paging = arch.paging;
const io = arch.io;
const pit = @import("../pit.zig");
const InterruptFrame = arch.registers.InterruptFrame;
const irq = arch.irq;
const sync = @import("../sync.zig");

const log = std.log.scoped(.acpi_osl);

const c = @cImport({
    @cInclude("uacpi/types.h");
    @cInclude("uacpi/kernel_api.h");
});

export var rsdp_address_request: limine.RSDPRequest linksection(".limine_requests") = .{};

export fn uacpi_kernel_get_rsdp(phys_out: *c.uacpi_phys_addr) c.uacpi_status {
    if (rsdp_address_request.response) |response| {
        phys_out.* = bootinfo.toPhysicalHHDM(response.address);
        return c.UACPI_STATUS_OK;
    }

    log.err("Failed to get RSDP address, limine rsponse was null", .{});
    return c.UACPI_STATUS_INTERNAL_ERROR;
}

export fn uacpi_kernel_map(addr: c.uacpi_phys_addr, _: c.uacpi_size) ?*anyopaque {
    return @ptrFromInt(bootinfo.toVirtualHHDM(addr));
}

export fn uacpi_kernel_unmap(addr: ?*anyopaque, _: c.uacpi_size) c.uacpi_status {
    _ = addr;
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_log(level: c.uacpi_log_level, message: [*c]c.uacpi_char) void {
    var msg = std.mem.span(message);
    msg[msg.len - 1] = 0; // ignore the new line

    const logger = std.log.scoped(.acpi);

    switch (level) {
        c.UACPI_LOG_DEBUG => logger.debug("{s}", .{msg}),
        c.UACPI_LOG_INFO => logger.info("{s}", .{msg}),
        c.UACPI_LOG_WARN => logger.warn("{s}", .{msg}),
        c.UACPI_LOG_ERROR => logger.err("{s}", .{msg}),
        else => {
            log.warn("Invalid log level {d}", .{level});
            logger.debug("{s}", .{msg});
        },
    }
}

export fn uacpi_kernel_initialize(_: c.uacpi_init_level) c.uacpi_status {
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_deinitialize() void {}

export fn uacpi_kernel_pci_device_open(
    address: c.uacpi_pci_address,
    out_handle: *c.uacpi_handle,
) c.uacpi_status {
    _ = .{ address, out_handle };
    return c.UACPI_STATUS_COMPILED_OUT;
}

export fn uacpi_kernel_pci_device_close(handle: c.uacpi_handle) void {
    _ = handle;
}

export fn uacpi_kernel_pci_read8(handle: c.uacpi_handle, offset: usize, out: *u8) c.uacpi_status {
    _ = .{ handle, offset, out };
    return c.UACPI_STATUS_COMPILED_OUT;
}

export fn uacpi_kernel_pci_read16(handle: c.uacpi_handle, offset: usize, out: *u16) c.uacpi_status {
    _ = .{ handle, offset, out };
    return c.UACPI_STATUS_COMPILED_OUT;
}

export fn uacpi_kernel_pci_read32(handle: c.uacpi_handle, offset: usize, out: *u32) c.uacpi_status {
    _ = .{ handle, offset, out };
    return c.UACPI_STATUS_COMPILED_OUT;
}

export fn uacpi_kernel_pci_write8(handle: c.uacpi_handle, offset: usize, val: u8) c.uacpi_status {
    _ = .{ handle, offset, val };
    return c.UACPI_STATUS_COMPILED_OUT;
}

export fn uacpi_kernel_pci_write16(handle: c.uacpi_handle, offset: usize, val: u16) c.uacpi_status {
    _ = .{ handle, offset, val };
    return c.UACPI_STATUS_COMPILED_OUT;
}

export fn uacpi_kernel_pci_write32(handle: c.uacpi_handle, offset: usize, val: u32) c.uacpi_status {
    _ = .{ handle, offset, val };
    return c.UACPI_STATUS_COMPILED_OUT;
}

export fn uacpi_kernel_io_map(
    base: c.uacpi_io_addr,
    len: c.uacpi_size,
    out_handle: *c.uacpi_handle,
) c.uacpi_status {
    _ = len; // no actual mapping needed on x86
    out_handle.* = @ptrFromInt(base); // store base address as handle
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_unmap(handle: c.uacpi_handle) void {
    _ = handle; // nothing to unmap
}

export fn uacpi_kernel_io_read8(handle: c.uacpi_handle, offset: usize, out: *u8) c.uacpi_status {
    const port: u16 = @truncate(@intFromPtr(handle) + offset);
    out.* = io.inb(port);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_read16(handle: c.uacpi_handle, offset: usize, out: *u16) c.uacpi_status {
    const port: u16 = @truncate(@intFromPtr(handle) + offset);
    out.* = io.inw(port);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_read32(handle: c.uacpi_handle, offset: usize, out: *u32) c.uacpi_status {
    const port: u16 = @truncate(@intFromPtr(handle) + offset);
    out.* = io.inl(port);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_write8(handle: c.uacpi_handle, offset: usize, val: u8) c.uacpi_status {
    const port: u16 = @truncate(@intFromPtr(handle) + offset);
    io.outb(port, val);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_write16(handle: c.uacpi_handle, offset: usize, val: u16) c.uacpi_status {
    const port: u16 = @truncate(@intFromPtr(handle) + offset);
    io.outw(port, val);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_write32(handle: c.uacpi_handle, offset: usize, val: u32) c.uacpi_status {
    const port: u16 = @truncate(@intFromPtr(handle) + offset);
    io.outl(port, val);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_alloc(size: c.uacpi_size) ?*anyopaque {
    return heap.malloc(size);
}

export fn uacpi_kernel_free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    heap.free(ptr);
}

export fn uacpi_kernel_get_nanoseconds_since_boot() c.uacpi_u64 {
    // PIT at 100Hz — each tick is 10ms = 10,000,000 ns
    return pit.ticks() * 10_000_000;
}

export fn uacpi_kernel_stall(usec: c.uacpi_u8) void {
    // PIT resolution is 10ms so we can't do sub-10ms accuracy
    // round up to nearest ms then sleep
    const ms = (@as(u32, usec) + 999) / 1000;
    if (ms > 0) pit.sleep(ms);
}

export fn uacpi_kernel_sleep(msec: c.uacpi_u64) void {
    pit.sleep(@truncate(msec));
}

// ── Mutex ─────────────────────────────────────────────────────────────────

export fn uacpi_kernel_create_mutex() c.uacpi_handle {
    return @ptrFromInt(1); // stub — no real mutex yet
}

export fn uacpi_kernel_free_mutex(handle: c.uacpi_handle) void {
    _ = handle;
}

export fn uacpi_kernel_acquire_mutex(handle: c.uacpi_handle, timeout: c.uacpi_u16) c.uacpi_status {
    _ = .{ handle, timeout };
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_release_mutex(handle: c.uacpi_handle) void {
    _ = handle;
}

// ── Events (semaphore-like) ───────────────────────────────────────────────

export fn uacpi_kernel_create_event() c.uacpi_handle {
    return @ptrFromInt(1); // stub
}

export fn uacpi_kernel_free_event(handle: c.uacpi_handle) void {
    _ = handle;
}

export fn uacpi_kernel_wait_for_event(handle: c.uacpi_handle, timeout: c.uacpi_u16) c.uacpi_bool {
    _ = .{ handle, timeout };
    return true; // always succeed
}

export fn uacpi_kernel_signal_event(handle: c.uacpi_handle) void {
    _ = handle;
}

export fn uacpi_kernel_reset_event(handle: c.uacpi_handle) void {
    _ = handle;
}

// ── Spinlocks ─────────────────────────────────────────────────────────────
export fn uacpi_kernel_create_spinlock() c.uacpi_handle {
    const lock = heap.allocator().create(sync.SpinLock) catch return null;
    lock.* = .init();
    return @ptrCast(@alignCast(lock));
}

export fn uacpi_kernel_free_spinlock(handle: c.uacpi_handle) void {
    const lock: *sync.SpinLock = @ptrCast(@alignCast(handle));
    heap.allocator().destroy(lock);
}

export fn uacpi_kernel_lock_spinlock(handle: c.uacpi_handle) c.uacpi_cpu_flags {
    const lock: *sync.SpinLock = @ptrCast(@alignCast(handle));
    return @intCast(lock.lock());
}

export fn uacpi_kernel_unlock_spinlock(handle: c.uacpi_handle, flags: c.uacpi_cpu_flags) void {
    const lock: *sync.SpinLock = @ptrCast(@alignCast(handle));
    lock.unlock(flags);
}

// ── Interrupts ────────────────────────────────────────────────────────────

export fn uacpi_kernel_disable_interrupts() c.uacpi_interrupt_state {
    const flags = io.getFlags();
    io.cli();
    return flags;
}

export fn uacpi_kernel_restore_interrupts(state: c.uacpi_interrupt_state) void {
    io.restoreFlags(state);
}

const IrqHandler = struct {
    handler: c.uacpi_interrupt_handler,
    ctx: c.uacpi_handle,
};

var uacpi_irq_handlers: [16]?IrqHandler = [_]?IrqHandler{null} ** 16;

fn wrapper(frame: *arch.registers.InterruptFrame) void {
    const number: u8 = @truncate(frame.interrupt_number - 1);
    log.debug("IRQ {d}", .{number});
    if (number >= 16) {
        log.err("Invalid interrupt number: {d}", .{number});
        return;
    }
    if (uacpi_irq_handlers[number]) |h| {
        _ = h.handler.?(h.ctx);
    }
}

export fn uacpi_kernel_install_interrupt_handler(
    irq_num: c.uacpi_u32,
    handler: c.uacpi_interrupt_handler,
    ctx: c.uacpi_handle,
    out_handle: *c.uacpi_handle,
) c.uacpi_status {
    if (irq_num >= 16) return c.UACPI_STATUS_INVALID_ARGUMENT;
    const i: u8 = @truncate(irq_num);

    if (uacpi_irq_handlers[i] != null) return c.UACPI_STATUS_ALREADY_EXISTS;

    uacpi_irq_handlers[i] = .{ .handler = handler, .ctx = ctx };
    irq.register(i, &wrapper);
    irq.enable(i);

    out_handle.* = @ptrFromInt(irq_num + 1); // non-null unique handle
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_uninstall_interrupt_handler(
    handler: c.uacpi_interrupt_handler,
    irq_handle: c.uacpi_handle,
) c.uacpi_status {
    _ = handler;
    const irq_num: u8 = @truncate(@intFromPtr(irq_handle) - 1);
    if (irq_num >= 16) return c.UACPI_STATUS_INVALID_ARGUMENT;

    uacpi_irq_handlers[irq_num] = null;
    irq.unregister(irq_num);
    return c.UACPI_STATUS_OK;
}

// ── Thread ID ─────────────────────────────────────────────────────────────

export fn uacpi_kernel_get_thread_id() c.uacpi_thread_id {
    return @ptrFromInt(1); // single thread stub
}

// ── Firmware requests ─────────────────────────────────────────────────────

export fn uacpi_kernel_handle_firmware_request(req: *c.uacpi_firmware_request) c.uacpi_status {
    switch (req.type) {
        c.UACPI_FIRMWARE_REQUEST_TYPE_BREAKPOINT => {
            @breakpoint();
        },
        c.UACPI_FIRMWARE_REQUEST_TYPE_FATAL => {
            log.err("ACPI fatal firmware request", .{});
            @panic("ACPI fatal");
        },
        else => {},
    }
    return c.UACPI_STATUS_OK;
}

// ── Work scheduling ───────────────────────────────────────────────────────
var work_ids: std.ArrayList(u32) = .empty;

export fn uacpi_kernel_schedule_work(
    work_type: c.uacpi_work_type,
    handler: c.uacpi_work_handler,
    ctx: c.uacpi_handle,
) c.uacpi_status {
    _ = work_type;
    // call directly until we have a scheduler
    const h = handler orelse return c.UACPI_STATUS_INVALID_ARGUMENT;
    const id = scheduler.addTask(h, .{@intFromPtr(ctx)});
    work_ids.append(heap.allocator(), id) catch return c.UACPI_STATUS_OUT_OF_MEMORY;
    log.debug("Spawned task: {d}", .{id});
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_wait_for_work_completion() c.uacpi_status {
    for (work_ids.items) |id| {
        log.debug("Waiting for task {d}", .{id});
        scheduler.waitForTask(id);
    }
    work_ids.clearRetainingCapacity();
    log.debug("Completed work", .{});
    return c.UACPI_STATUS_OK; // no-op, work runs synchronously above
}
