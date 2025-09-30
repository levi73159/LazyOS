const std = @import("std");

const disk_img = "disk.img";

const Bootloader = enum {
    uefi, // boot in UEFI
    disabled,
    // bios, // boot in BIOS
};

var bootloader_type: Bootloader = .uefi;
var bootloader_exe: ?*std.Build.Step.Compile = null;

pub fn build(b: *std.Build) void {
    var disabled_features = std.Target.Cpu.Feature.Set.empty;
    var enabled_features = std.Target.Cpu.Feature.Set.empty;

    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture") orelse .x86_64;
    bootloader_type = b.option(Bootloader, "bootloader", "Bootloader") orelse bootloader_type;

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

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const uefi_dep = if (bootloader_type != .disabled)
        b.dependency("uefi_bootloader", .{ .arch = arch })
    else
        null;

    bootloader_exe = if (uefi_dep) |dep| dep.artifact("bootx64") else null;

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/boot.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = if (arch == .x86_64) .default else .kernel,
        .red_zone = false,
        .sanitize_thread = false,
        .pic = true,
        .dwarf_format = if (arch == .x86_64) .@"64" else .@"32",
    });
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
        .use_llvm = true,
    });
    kernel.entry = .disabled;

    kernel.addIncludePath(b.path("src/kernel/headers"));

    std.log.debug("install path: {s}, prefix: {s}", .{ b.install_path, b.install_prefix });

    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    const image = makeImage(b, kernel, uefi_dep);

    const run_qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-hda",
    });
    run_qemu_cmd.addFileArg(image.path);
    run_qemu_cmd.addArgs(&.{
        "-m",
        "2G",
        "-serial",
        "stdio",
        "-s",
    });
    if (bootloader_type == .uefi) {
        run_qemu_cmd.addArgs(&.{ "-bios", "/usr/share/ovmf/x64/OVMF.4m.fd" });
    }

    run_qemu_cmd.step.dependOn(image.step);

    const debug_cmd = b.addSystemCommand(&.{"scripts/debug.sh"});
    debug_cmd.addFileArg(image.path);
    debug_cmd.step.dependOn(image.step);

    const run_step = b.step("run", "Run the operating system");
    run_step.dependOn(&run_qemu_cmd.step);

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

const Image = struct {
    step: *std.Build.Step,
    path: std.Build.LazyPath,
};
pub fn makeImage(b: *std.Build, kernel: *std.Build.Step.Compile, bootloader: ?*std.Build.Dependency) Image {
    const boot_exe = if (bootloader) |bld| bld.artifact("bootx64") else null;

    const create_img_file = b.addSystemCommand(&.{"scripts/make_img.sh"});
    const install_path = b.getInstallPath(.prefix, disk_img);
    std.log.debug("install path: {s}", .{install_path});
    const img_path = create_img_file.addOutputFileArg("disk.img");
    create_img_file.addFileArg(boot_exe.?.getEmittedBin());

    create_img_file.step.dependOn(&boot_exe.?.step);
    create_img_file.step.dependOn(&kernel.step);

    const img_install = b.addInstallFile(img_path, "disk.img");

    const step = b.step("make-image", "Build the ISO image");
    step.dependOn(&img_install.step);

    b.installArtifact(boot_exe.?);
    b.getInstallStep().dependOn(step);

    return .{
        .step = step,
        .path = img_path,
    };
}
