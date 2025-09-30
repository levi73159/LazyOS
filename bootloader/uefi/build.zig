const std = @import("std");

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture") orelse .x86_64;
    if (arch != .x86_64) @panic("Only x86_64 is supported");

    std.log.debug("arch: {}", .{arch});

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .uefi,
        .abi = .msvc,
        .ofmt = .coff,
    });

    const bootloader_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "bootx64",
        .root_module = bootloader_module,
    });
    b.installArtifact(exe);
}
