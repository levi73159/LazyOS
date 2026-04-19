const std = @import("std");
const Options = @import("Options.build.zig");

const Image = @import("image.build.zig").Image;

pub fn addSteps(b: *std.Build, opts: Options, img: Image) void {
    const run_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});
    run_cmd.addArg("-hda");
    run_cmd.addFileArg(img.path);
    run_cmd.addArgs(&.{
        "-machine", "q35,accel=kvm",
        "-cpu",     "host",
        "-display", opts.display,
        "-serial",  "stdio",
        "-bios",    "/usr/share/ovmf/x64/OVMF.4m.fd",
    });
    if (opts.stal) {
        run_cmd.addArgs(&.{ "-no-reboot", "-no-shutdown" });
    }
    if (opts.debug_int) {
        run_cmd.addArgs(&.{ "-d", "int" });
    }
    run_cmd.step.dependOn(img.step);

    const debug_cmd = b.addSystemCommand(&.{"scripts/debug.sh"});
    debug_cmd.addFileArg(img.path);
    debug_cmd.step.dependOn(img.step);

    b.step("run", "Run the operating system").dependOn(&run_cmd.step);
    b.step("debug", "Debug the operating system").dependOn(&debug_cmd.step);
}
