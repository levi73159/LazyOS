const std = @import("std");

const disk_img = "disk.img";

const Image = struct {
    path: []const u8,
    step: *std.Build.Step,
};

const Bootloader = enum {
    uefi, // boot in UEFI
    // bios, // boot in BIOS
    grub, // boot using Grub
};

pub fn build(b: *std.Build) void {
    var disabled_features = std.Target.Cpu.Feature.Set.empty;
    var enabled_features = std.Target.Cpu.Feature.Set.empty;

    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture") orelse .x86;
    const bootloader = b.option(Bootloader, "bootloader", "Bootloader") orelse .grub;

    if (arch == .x86) {
        disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.mmx));
        disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.sse));
        disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.sse2));
        disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
        disabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
        enabled_features.addFeature(@intFromEnum(std.Target.x86.Feature.soft_float));
    }

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
        .cpu_features_add = enabled_features,
        .cpu_features_sub = disabled_features,
    });

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const bootloader_deb: ?*std.Build.Dependency = switch (bootloader) {
        .uefi => b.dependency("uefi_bootloader", .{ .arch = arch }),
        .grub => null,
    };

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/boot.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .sanitize_thread = false,
        .pic = true,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });
    kernel.entry = .disabled;
    kernel.root_module.code_model = .kernel;
    kernel.root_module.red_zone = false;
    kernel.root_module.pic = true;

    kernel.addIncludePath(b.path("src/kernel/headers"));

    std.log.debug("install path: {s}, prefix: {s}", .{ b.install_path, b.install_prefix });

    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    const image = makeImage(b, null, bootloader_deb);
    image.dependOn(&kernel.step);

    const image_path = b.getInstallPath(.prefix, disk_img);

    const run_qemu_cmd = b.addSystemCommand(&.{ "qemu-system-i386", "-hda", image_path, "-m", "32", "-debugcon", "stdio" });
    run_qemu_cmd.step.dependOn(image);

    const debug_cmd = b.addSystemCommand(&.{ "scripts/debug.sh", image_path });
    debug_cmd.step.dependOn(image);

    // const run = b.step("run", "Run the operating system");
    // run.dependOn(&run_qemu_cmd.step);

    const debug = b.step("debug", "Debug the operating system");
    debug.dependOn(&debug_cmd.step);
}

const bs = 1048576;
const count = 10;
const len = bs * count;

fn run(b: *std.Build, args: []const []const u8) anyerror!void {
    var child = std.process.Child.init(args, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();

    switch (term) {
        .Exited => |code| if (code != 0) return error.ExitCode,
        .Signal => |sig| {
            std.log.err("child process terminated by signal {}", .{sig});
            return error.Signal;
        },
        .Stopped => return error.Stopped,
        else => return error.UnexpectedTermination,
    }
}

pub fn createDiskFile(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    const b = step.owner;

    const img_path = b.getInstallPath(.prefix, disk_img);
    std.log.info("creating disk image {s}, may need to enter sudo password", .{img_path});
    try run(b, &.{ "sudo", "scripts/make_img.sh", img_path });
}

pub fn makeImage(b: *std.Build, _: ?*std.Build.Step.Compile, bootloader: ?*std.Build.Dependency) *std.Build.Step {
    const boot_exe = if (bootloader) |bld| bld.artifact("boot") else null;
    _ = boot_exe;

    const create_img_file = b.step("create-disk-file", "Create the disk image file");
    create_img_file.makeFn = createDiskFile;

    // const files = b.addWriteFiles();
    // _ = files.addCopyFile(kernel.getEmittedBin(), "boot/kernel");
    // _ = files.addCopyFile(b.path("bootloader/grub/grub.cfg"), "boot/grub/grub.cfg");
    // _ = files.addCopyDirectory(b.path(img_root), ".", .{});
    //
    // const make_iso = b.addSystemCommand(&.{
    //     "grub-mkrescue",
    //     "-o",
    //     out,
    // });
    // make_iso.step.dependOn(boot_exe.step);
    // make_iso.addFileArg(files.getDirectory());
    //
    // make_iso.step.dependOn(&files.step);

    const step = b.step("make-image", "Build the ISO image");
    step.dependOn(create_img_file);

    b.default_step.dependOn(step);

    // step.dependOn(&make_iso.step);
    return create_img_file;
}
