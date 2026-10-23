const root = @import("root");
const std = @import("std");

const Frame = root.arch.syscall.SyscallFrame;
const errno = @import("errno.zig");
const scheduler = root.proc.scheduler;
const saftey = @import("safety.zig");

const signals = root.proc.signals;

pub fn rt_sigaction(frame: *Frame) i64 {
    const sig = frame.rdi;
    const act_addr = frame.rsi;
    const old_act_addr = frame.rdx;
    const sig_set_size = frame.r10; // must be 8

    if (sig_set_size != 8) {
        return errno.EINVAL;
    }

    if (sig == 0 or sig > 64) return errno.EINVAL;

    // SIGKILL and SIGSTOP cannot have their actions changed.
    if (act_addr != 0 and (sig == 9 or sig == 19))
        return errno.EINVAL;

    const process = scheduler.getCurrentProcess().?;
    const index = sig - 1;

    if (act_addr != 0 and !saftey.validateUserRange(act_addr, @sizeOf(signals.SignalAction), .read)) return errno.EFAULT;
    if (old_act_addr != 0 and !saftey.validateUserRange(old_act_addr, @sizeOf(signals.SignalAction), .write)) return errno.EFAULT;

    const action_ptr: ?*align(1) const signals.SignalAction = if (act_addr != 0) @ptrFromInt(act_addr) else null;
    const old_action_ptr: ?*align(1) signals.SignalAction = if (old_act_addr != 0) @ptrFromInt(old_act_addr) else null;

    const old = process.signal_actions[index];

    if (action_ptr) |ptr| {
        var action = ptr.*;

        if (action.handler > 1 or action.flags != 0) {
            return errno.EINVAL; // TODO: add process handler support
        }

        action.mask &= ~((@as(u64, 1) << (9 - 1)) |
            (@as(u64, 1) << (19 - 1)));

        process.signal_actions[index] = action;
    }

    if (old_action_ptr) |ptr| {
        ptr.* = old;
    }

    return 0;
}
