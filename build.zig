const std = @import("std");

const iso_path = "zig-out/lazyos.iso";

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "lazyos",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the assembly boot file
    kernel.addAssemblyFile(b.path("src/kernel/boot.s"));

    // Use our custom linker script
    kernel.setLinkerScript(b.path("linker.ld"));

    // Disable strip for debugging
    kernel.root_module.strip = false;

    // Disable red zone for kernel mode
    kernel.root_module.red_zone = false;

    b.installArtifact(kernel);

    const iso_step = createIsoStep(b) catch return;
    createRunStep(b, iso_step, iso_path);
}

fn createIsoStep(b: *std.Build) !*std.Build.Step {
    // ISO creation step
    const iso_step = b.step("iso", "Create bootable ISO image");

    const iso_root = "iso_root";
    b.cache_root.handle.makePath(iso_root ++ "/boot/grub") catch |err| errblk: {
        if (err == error.PathAlreadyExists) break :errblk;

        std.log.err("Failed to create ISO root directory: {}", .{err});
        const fail = b.addFail("Failed to create ISO root directory");
        iso_step.dependOn(&fail.step);
        return error.Return;
    };

    const kernel_path = b.pathJoin(&.{ iso_root, "boot/kernel" });
    const grub_cfg_path = b.pathJoin(&.{ iso_root, "boot/grub/grub.cfg" });

    const copy_kernel = b.addSystemCommand(&[_][]const u8{
        "cp",
        b.getInstallPath(.bin, "lazyos"),
        kernel_path,
    });
    copy_kernel.step.dependOn(b.getInstallStep());

    const copy_cfg = b.addSystemCommand(&[_][]const u8{
        "cp",
        "src/bootloader/grub.cfg",
        grub_cfg_path,
    });
    copy_cfg.step.dependOn(&copy_kernel.step);

    const make_iso = b.addSystemCommand(&[_][]const u8{ "grub-mkrescue", "-o", iso_path, iso_root });
    make_iso.step.dependOn(&copy_cfg.step);

    iso_step.dependOn(&make_iso.step);

    return iso_step;
}

fn createRunStep(b: *std.Build, iso_step: *std.Build.Step, iso_file: []const u8) void {
    const run_step = b.step("run", "Run the os");

    const run = b.addSystemCommand(&[_][]const u8{ "qemu-system-x86_64", "-cdrom", iso_file, "-m", "512M" });
    run.step.dependOn(iso_step);
    run_step.dependOn(&run.step);
}

fn checkRequiredTools(b: *std.Build) void {
    const output = b.run(&.{"scripts/check_required.sh"});
    std.debug.print("{s}", .{output});
}
