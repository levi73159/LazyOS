const std = @import("std");
const exit = std.process.exit;

const uacpi = @import("build/uacpi.build.zig");
const assets = @import("build/assets.build.zig");
const image = @import("build/image.build.zig");
const qemu = @import("build/qemu.build.zig");
const prgs = @import("build/programs.build.zig");

const Options = @import("build/Options.build.zig");

// const kernel_dep = b.dependency("kernel", .{
//     .optimize = optimize_mode,
//     .uacpi = b.path("vendor/uACPI/include/"),
// });
//
// const kernel = kernel_dep.artifact("kernel");
// const kernel_mod = kernel_dep.module("kernel");
//
// addUACPI(b, kernel_mod);

pub fn build(b: *std.Build) void {
    const options = Options.parse(b);

    const kernel_dep = b.dependency("kernel", .{
        .optimize = options.optimize,
        .uacpi = b.path("vendor/uACPI/include/"),
    });
    const kernel_mod = kernel_dep.module("kernel");
    const kernel_exe = kernel_dep.artifact("kernel");

    uacpi.link(b, kernel_mod);

    const converted = assets.convert(b);
    const programs = prgs.makePrograms(b);
    const img = image.make(b, kernel_exe, programs, converted);

    qemu.addSteps(b, options, img);
}
