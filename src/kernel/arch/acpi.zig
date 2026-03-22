const std = @import("std");
const io = @import("io.zig");

const c = @cImport({
    @cInclude("uacpi/uacpi.h");
    @cInclude("uacpi/sleep.h");
    @cInclude("uacpi/event.h");
});

const log = std.log.scoped(._acpi);

fn check(status: c.uacpi_status) !void {
    if (status != c.UACPI_STATUS_OK) {
        @branchHint(.unlikely);
        log.err("ACPI check failed: {s}({d})", .{ c.uacpi_status_to_string(status), status });
        return error.ACPIError;
    }
}

pub fn init() !void {
    try check(c.uacpi_initialize(0));
    try check(c.uacpi_namespace_load());
    try check(c.uacpi_namespace_initialize());
    try check(c.uacpi_finalize_gpe_initialization());
}

pub fn shutdown() void {
    io.cli();
    check(c.uacpi_prepare_for_sleep_state(c.UACPI_SLEEP_STATE_S5)) catch {
        log.err("ACPI shutdown failed: prepare_for_sleep_state", .{});
    };

    check(c.uacpi_enter_sleep_state(c.UACPI_SLEEP_STATE_S5)) catch {
        log.err("ACPI shutdown failed: enter_sleep_state", .{});
    };

    log.warn("ACPI shutdown failed", .{});
}

pub fn reboot() void {
    io.cli();
    check(c.uacpi_reboot()) catch {
        io.outb(0x64, 0xfe); // fallback on keyboard controller reset
    };
}
