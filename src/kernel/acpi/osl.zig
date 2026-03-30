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
const pci = @import("../pci.zig");

const log = std.log.scoped(.acpi_osl);

const c = @cImport({
    @cInclude("uacpi/types.h");
    @cInclude("uacpi/kernel_api.h");
});

export var rsdp_address_request: limine.RSDPRequest linksection(".limine_requests") = .{};

export fn uacpi_kernel_get_rsdp(phys_out: *c.uacpi_phys_addr) c.uacpi_status {
    if (rsdp_address_request.response) |response| {
        phys_out.* = bootinfo.toPhysical(response.address); // we don't know if it from the kernel (different mapping) or the HHDM
        return c.UACPI_STATUS_OK;
    }

    log.err("Failed to get RSDP address, limine rsponse was null", .{});
    return c.UACPI_STATUS_INTERNAL_ERROR;
}

export fn uacpi_kernel_map(addr: c.uacpi_phys_addr, _: c.uacpi_size) ?*anyopaque {
    const virt = bootinfo.toVirtualHHDM(addr);
    return @ptrFromInt(virt);
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

fn encodePciHandle(bus: u8, slot: u8, function: u8) c.uacpi_handle {
    return @ptrFromInt(@as(usize, bus) << 16 | @as(usize, slot) << 8 | @as(usize, function));
}

fn getPciInfo(handle: c.uacpi_handle) struct { u8, u8, u8 } {
    const data = @intFromPtr(handle);
    const bus: u8 = @truncate(data >> 16);
    const slot: u8 = @truncate(data >> 8);
    const function: u8 = @truncate(data);

    return .{ bus, slot, function };
}

export fn uacpi_kernel_pci_device_open(
    address: c.uacpi_pci_address,
    out_handle: *c.uacpi_handle,
) c.uacpi_status {
    out_handle.* = encodePciHandle(address.bus, address.device, address.function);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_pci_device_close(handle: c.uacpi_handle) void {
    _ = handle;
}

export fn uacpi_kernel_pci_read8(handle: c.uacpi_handle, offset: c.uacpi_size, out: *u8) c.uacpi_status {
    const bus, const slot, const func = getPciInfo(handle);
    const data = pci.configRead(u8, bus, slot, func, @intCast(offset));
    out.* = data;
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_pci_read16(handle: c.uacpi_handle, offset: c.uacpi_size, out: *u16) c.uacpi_status {
    const bus, const slot, const func = getPciInfo(handle);
    const data = pci.configRead(u16, bus, slot, func, @intCast(offset));
    out.* = data;
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_pci_read32(handle: c.uacpi_handle, offset: c.uacpi_size, out: *u32) c.uacpi_status {
    const bus, const slot, const func = getPciInfo(handle);
    const data = pci.configRead(u32, bus, slot, func, @intCast(offset));
    out.* = data;
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_pci_write8(handle: c.uacpi_handle, offset: c.uacpi_size, val: u8) c.uacpi_status {
    const bus, const slot, const func = getPciInfo(handle);
    pci.configWrite(u8, bus, slot, func, @intCast(offset), val);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_pci_write16(handle: c.uacpi_handle, offset: c.uacpi_size, val: u16) c.uacpi_status {
    const bus, const slot, const func = getPciInfo(handle);
    pci.configWrite(u16, bus, slot, func, @intCast(offset), val);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_pci_write32(handle: c.uacpi_handle, offset: c.uacpi_size, val: u32) c.uacpi_status {
    const bus, const slot, const func = getPciInfo(handle);
    pci.configWrite(u32, bus, slot, func, @intCast(offset), val);
    return c.UACPI_STATUS_OK;
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
    const data = heap.malloc(heap.get_acpi(), size);
    if (data == null) {
        log.err("Out of memory, alloc({d})", .{size});
        return null;
    }
    const slice = @as([*]u8, @ptrCast(data))[0..size];
    @memset(slice, 0);

    const addr = @intFromPtr(data);
    if (addr & 7 != 0) {
        log.err("MISALIGNED alloc({d}) = 0x{x}", .{ size, addr });
    }
    return data;
}

export fn uacpi_kernel_free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    heap.free(heap.get_acpi(), ptr);
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
    const allocator = heap.acpi_allocator();
    const mutex = allocator.create(sync.Mutex) catch return null;
    mutex.* = .init(allocator);
    return @ptrCast(@alignCast(mutex));
}

export fn uacpi_kernel_free_mutex(handle: c.uacpi_handle) void {
    const mutex: *sync.Mutex = @ptrCast(@alignCast(handle));
    mutex.deinit();
    mutex.allocator.destroy(mutex);
}

export fn uacpi_kernel_acquire_mutex(handle: c.uacpi_handle, timeout: c.uacpi_u16) c.uacpi_status {
    _ = timeout; // TODO: implement lock with a timeout
    const mutex: *sync.Mutex = @ptrCast(@alignCast(handle));
    mutex.lock();
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_release_mutex(handle: c.uacpi_handle) void {
    const mutex: *sync.Mutex = @ptrCast(@alignCast(handle));
    mutex.unlock();
}

// ── Events (semaphore-like) ───────────────────────────────────────────────

const Event = struct {
    count: std.atomic.Value(u32),
};

export fn uacpi_kernel_create_event() c.uacpi_handle {
    const event = heap.acpi_allocator().create(Event) catch return null;
    event.* = .{ .count = .init(0) };
    return @ptrCast(@alignCast(event));
}

export fn uacpi_kernel_signal_event(handle: c.uacpi_handle) void {
    const event: *Event = @ptrCast(@alignCast(handle));
    _ = event.count.fetchAdd(1, .release);
}

export fn uacpi_kernel_wait_for_event(handle: c.uacpi_handle, timeout: c.uacpi_u16) c.uacpi_bool {
    const event: *Event = @ptrCast(@alignCast(handle));
    var tries: u32 = 0;
    const limit = if (timeout == 0xFFFF) std.math.maxInt(u32) else @as(u32, timeout) * 100;
    while (tries < limit) : (tries += 1) {
        if (event.count.load(.acquire) > 0) {
            _ = event.count.fetchSub(1, .release);
            return true;
        }
        pit.sleep(1);
    }
    return false;
}

export fn uacpi_kernel_reset_event(handle: c.uacpi_handle) void {
    const event: *Event = @ptrCast(@alignCast(handle));
    event.count.store(0, .release);
}

export fn uacpi_kernel_free_event(handle: c.uacpi_handle) void {
    const event: *Event = @ptrCast(@alignCast(handle));
    heap.acpi_allocator().destroy(event);
}

// ── Spinlocks ─────────────────────────────────────────────────────────────
export fn uacpi_kernel_create_spinlock() c.uacpi_handle {
    const lock = heap.acpi_allocator().create(sync.SpinLock) catch return null;
    lock.* = .init();
    return @ptrCast(@alignCast(lock));
}

export fn uacpi_kernel_free_spinlock(handle: c.uacpi_handle) void {
    const lock: *sync.SpinLock = @ptrCast(@alignCast(handle));
    heap.acpi_allocator().destroy(lock);
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
    const number: u8 = @truncate(frame.interrupt_number - arch.pic.REMAP_OFFSET);
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
    const h = handler orelse return c.UACPI_STATUS_INVALID_ARGUMENT;
    const id = scheduler.addTask(h, .{@intFromPtr(ctx)});
    work_ids.append(heap.acpi_allocator(), id) catch return c.UACPI_STATUS_OUT_OF_MEMORY;
    log.debug("Spawned task: {d}", .{id});
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_wait_for_work_completion() c.uacpi_status {
    for (work_ids.items) |id| {
        log.debug("Waiting for task {d}", .{id});
        scheduler.waitForTaskToExit(id);
    }
    work_ids.clearRetainingCapacity();
    log.debug("Completed work", .{});
    return c.UACPI_STATUS_OK;
}
