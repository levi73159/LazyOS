const std = @import("std");

const image_name = "lazyos.iso";

const Image = struct {
    path: []const u8,
    step: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    var disabled_features = std.Target.Cpu.Feature.Set.empty;
    var enabled_features = std.Target.Cpu.Feature.Set.empty;

    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.mmx));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.sse));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.sse2));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
    disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
    enabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.soft_float));

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
        .cpu_features_add = enabled_features,
        .cpu_features_sub = disabled_features,
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel.entry = .disabled;
    std.log.debug("install path: {s}, prefix: {s}", .{ b.install_path, b.install_prefix });

    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    kernel.root_module.red_zone = false;

    const image = makeImage(b, kernel);
    image.step.dependOn(&kernel.step);

    const qemu_cmd = b.addSystemCommand(&.{ "qemu-system-i386", "-cdrom", image.path, "-m", "512M", "-debugcon", "stdio" });
    qemu_cmd.step.dependOn(image.step);

    const run = b.step("run", "Run the operating system");
    run.dependOn(&qemu_cmd.step);
}

pub fn makeImage(b: *std.Build, kernel: *std.Build.Step.Compile) Image {
    const img_root = "root";
    const out = b.pathJoin(&.{ b.install_prefix, image_name });

    const files = b.addWriteFiles();
    _ = files.addCopyFile(kernel.getEmittedBin(), "boot/kernel");
    _ = files.addCopyFile(b.path("src/bootloader/x86/grub.cfg"), "boot/grub/grub.cfg");
    _ = files.addCopyDirectory(b.path(img_root), ".", .{});

    const make_iso = b.addSystemCommand(&.{
        "grub-mkrescue",
        "-o",
        out,
    });

    make_iso.addFileArg(files.getDirectory());
    make_iso.step.dependOn(&files.step);

    const step = b.step("make-image", "Build the ISO image");
    b.default_step.dependOn(step);

    step.dependOn(&make_iso.step);
    return Image{ .path = out, .step = step };
}
