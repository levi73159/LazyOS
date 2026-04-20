const std = @import("std");
const exit = std.process.exit;

const uacpi = @import("build/uacpi.build.zig");
const assets = @import("build/assets.build.zig");
const image = @import("build/image.build.zig");
const qemu = @import("build/qemu.build.zig");
const prgs = @import("build/programs.build.zig");

const Options = @import("build/Options.build.zig");

pub fn build(b: *std.Build) void {
    const options = Options.parse(b);

    const kernel_dep = b.dependency("kernel", .{
        .optimize = options.optimize,
        .uacpi = b.path("vendor/uACPI/include/"),
    });
    const kernel_mod = kernel_dep.module("kernel");
    const kernel_exe = kernel_dep.artifact("kernel");

    b.installArtifact(kernel_exe);

    uacpi.link(b, kernel_mod);

    const converted = assets.convert(b);
    const programs = prgs.make(b, options);
    const img = image.make(b, kernel_exe, programs, converted);

    qemu.addSteps(b, options, img);
}
