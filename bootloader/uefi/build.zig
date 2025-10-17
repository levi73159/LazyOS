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

    const testing_target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = arch } });

    const bootloader_module = b.addModule("bootloader", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_module = b.addModule("bootloader.test", .{
        .root_source_file = b.path("src/main.zig"),
        .target = testing_target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "bootx64",
        .root_module = bootloader_module,
    });
    const exe_test = b.addTest(.{
        .name = "bootloader.test",
        .root_module = test_module,
        .test_runner = .{ .path = b.path("../../src/test_runner.zig"), .mode = .simple },
    });

    b.installArtifact(exe);
    b.installArtifact(exe_test);
}
