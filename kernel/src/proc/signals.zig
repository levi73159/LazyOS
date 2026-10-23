const std = @import("std");
const Process = @import("Process.zig");
const scheduler = @import("scheduler.zig");

pub const SIGHUP: u8 = 1;
pub const SIGINT: u8 = 2;
pub const SIGQUIT: u8 = 3;
pub const SIGILL: u8 = 4;
pub const SIGTRAP: u8 = 5;
pub const SIGABRT: u8 = 6;
pub const SIGIOT: u8 = SIGABRT;
pub const SIGBUS: u8 = 7;
pub const SIGFPE: u8 = 8;
pub const SIGKILL: u8 = 9;
pub const SIGUSR1: u8 = 10;
pub const SIGSEGV: u8 = 11;
pub const SIGUSR2: u8 = 12;
pub const SIGPIPE: u8 = 13;
pub const SIGALRM: u8 = 14;
pub const SIGTERM: u8 = 15;
pub const SIGSTKFLT: u8 = 16;
pub const SIGCHLD: u8 = 17;
pub const SIGCONT: u8 = 18;
pub const SIGSTOP: u8 = 19;
pub const SIGTSTP: u8 = 20;
pub const SIGTTIN: u8 = 21;
pub const SIGTTOU: u8 = 22;
pub const SIGURG: u8 = 23;
pub const SIGXCPU: u8 = 24;
pub const SIGXFSZ: u8 = 25;
pub const SIGVTALRM: u8 = 26;
pub const SIGPROF: u8 = 27;
pub const SIGWINCH: u8 = 28;
pub const SIGIO: u8 = 29;
pub const SIGPOLL: u8 = SIGIO;
pub const SIGPWR: u8 = 30;
pub const SIGSYS: u8 = 31;

// Kernel real-time range; libc may reserve some internally.
pub const SIGRTMIN: u8 = 32;
pub const SIGRTMAX: u8 = 64;

pub const SignalAction = extern struct {
    handler: u64 = 0, // 0 = SIG_DFL, 1 = SIG_IGN, otherwise user address
    flags: u64 = 0,
    restorer: u64 = 0,
    mask: u64 = 0,
};

/// returns: new_rip
/// NOTE: should never be called inside interrupt since it contains taskKill
pub fn checkPendingSignals(old_rip: u64) u64 {
    const current_process = scheduler.getCurrentProcess() orelse return old_rip;
    const ready = current_process.pending_signals & ~current_process.blocked_signals;

    if (ready == 0) return old_rip; // no ready signals

    const index: u6 = @intCast(@ctz(ready));
    const sig = @as(u8, index) + 1;
    const bit = @as(u64, 1) << index;

    const action = current_process.signal_actions[index];
    if (action.handler > 1) @panic("undefined behavior, todo"); // TODO: add custom handler support

    if (action.handler == 1) {
        current_process.pending_signals &= ~bit;
    } else {
        defaultHandle(sig);
    }

    return old_rip;
}

pub fn handleInterruptReturn(
    frame: *@import("../arch/registers.zig").InterruptFrame,
) void {
    while ((frame.cs & 3) == 3) {
        const process = scheduler.getCurrentProcess() orelse return;
        const ready = process.pending_signals & ~process.blocked_signals;
        if (ready == 0) return;

        const index: u6 = @intCast(@ctz(ready));
        const sig: u8 = @as(u8, index) + 1;
        const bit = @as(u64, 1) << index;
        const action = process.signal_actions[index];

        if (action.handler == 1) {
            process.pending_signals &= ~bit;
            continue;
        }

        switch (sig) {
            SIGINT, SIGKILL, SIGTERM => {
                process.pending_signals &= ~bit;

                // Mark dead; don't halt inside the interrupt handler.
                scheduler.getCurrentTask().state = .{
                    .dead = @as(u64, 128) + sig,
                };

                // Replace frame with another task's saved context.
                scheduler.schedule(frame);
            },
            else => return, // Other default actions aren't implemented yet.
        }
    }
}

fn defaultHandle(sig: u8) void {
    switch (sig) {
        SIGINT, SIGKILL, SIGTERM => {
            scheduler.taskExit(128 + sig);
        },
        else => {
            // TODO: implement other default
        },
    }
}
