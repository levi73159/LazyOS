const std = @import("std");

pub fn build(b: *std.Build) void {
    const bootloader_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
        .ofmt = .coff,
    });

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });

    const optimize = b.standardOptimizeOption(.{});

    const bootloader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = b.path("src/bootloader/main.zig"),
        .target = bootloader_target,
        .optimize = optimize,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    kernel.entry = .disabled;
    kernel.setLinkerScript(b.path("linker.ld"));

    b.installArtifact(bootloader);
    b.installArtifact(kernel);

    const boot_dir = b.addWriteFiles();
    _ = boot_dir.addCopyFile(bootloader.getEmittedBin(), b.pathJoin(&.{ "efi/boot", bootloader.out_filename }));
    _ = boot_dir.addCopyFile(kernel.getEmittedBin(), b.pathJoin(&.{ "boot/", kernel.out_filename }));

    const qemu_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});

    qemu_cmd.addArg("-bios");
    qemu_cmd.addFileArg(b.path("OVMF.fd"));
    qemu_cmd.addArg("-hdd");
    qemu_cmd.addPrefixedDirectoryArg("fat:rw:", boot_dir.getDirectory());
    qemu_cmd.addArg("-debugcon");
    qemu_cmd.addArg("stdio");
    qemu_cmd.addArg("-serial");
    qemu_cmd.addArg("null");
    qemu_cmd.addArg("-display");
    qemu_cmd.addArg("gtk");
    qemu_cmd.addArg("-s");

    const run = b.step("run", "Run the operating system");
    run.dependOn(&qemu_cmd.step);
}
