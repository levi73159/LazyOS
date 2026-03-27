const std = @import("std");
const exit = std.process.exit;

const image_name = "lazyos.iso";

var io: std.Io = undefined;

const Image = struct {
    path: []const u8,
    step: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    // var threaded = std.Io.Threaded.init(b.allocator, .{});
    // io = threaded.io();
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });
    const debug_int = b.option(bool, "interrupt", "turn on interrupt logging for qemu using the -d int option") orelse false;
    const display = b.option([]const u8, "display", "choose display backend") orelse "sdl";

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/boot.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .sanitize_thread = false,
        .pic = false,
        .strip = false,
        .error_tracing = true,
        .omit_frame_pointer = false,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });

    kernel.use_llvm = true;
    kernel.use_lld = true;
    kernel.setLinkerScript(b.path("linker.ld"));
    kernel.pie = false;
    kernel.entry = .disabled;

    kernel_mod.addAssemblyFile(b.path("src/kernel/arch/arch.s"));

    kernel_mod.addIncludePath(b.path("src/kernel/c/headers"));
    kernel_mod.addIncludePath(b.path("vendor/uACPI/include/"));

    addUACPI(b, kernel_mod);

    std.log.debug("install path: {s}, prefix: {s}", .{ b.install_path, b.install_prefix });

    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    const install_kernel = b.addInstallArtifact(kernel, .{});

    const image = makeImage(b, kernel);
    image.step.dependOn(&install_kernel.step);

    // const run_qemu_cmd = b.addSystemCommand(&.{ "qemu-system-x86_64", "-hda", image.path, "-m", "32", "-debugcon", "stdio" });
    // run_qemu_cmd.step.dependOn(image.step);
    const run_qemu_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});
    run_qemu_cmd.addArg("-cdrom");
    run_qemu_cmd.addArg(image.path);
    run_qemu_cmd.addArgs(&.{
        "-machine", "q35", // closer to real hardware
        "-cpu",     "qemu64",
        "-s",       "-serial",
        "stdio",    "-display",
        display,
    });
    if (debug_int) {
        run_qemu_cmd.addArgs(&.{ "-d", "int" });
    }
    run_qemu_cmd.addArgs(&.{ "-bios", "/usr/share/ovmf/x64/OVMF.4m.fd" });

    run_qemu_cmd.step.dependOn(image.step);

    const debug_cmd = b.addSystemCommand(&.{ "scripts/debug.sh", image.path });
    debug_cmd.step.dependOn(image.step);

    const run = b.step("run", "Run the operating system");
    run.dependOn(&run_qemu_cmd.step);

    const debug = b.step("debug", "Debug the operating system");
    debug.dependOn(&debug_cmd.step);
}

pub fn makeImage(b: *std.Build, kernel: *std.Build.Step.Compile) Image {
    const img_root = "root";
    const out = b.getInstallPath(.bin, image_name);

    // Convert all PNGs to TGA into a staging directory, no originals leak in
    const convert = b.addSystemCommand(&.{
        "sh", "-c",
        "mkdir -p zig-out/ui && for f in assets/*.png; do " ++
            "magick \"$f\" \"zig-out/ui/$(basename ${f%.png}).tga\"; done",
    });

    const files = b.addWriteFiles();
    files.step.dependOn(&convert.step); // staging dir must exist before copy
    _ = files.addCopyFile(kernel.getEmittedBin(), "boot/kernel");
    _ = files.addCopyFile(b.path("src/bootloader/limine.conf"), "boot/limine.conf");
    _ = files.addCopyFile(b.path("limine/BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = files.addCopyFile(b.path("limine/limine-uefi-cd.bin"), "EFI/BOOT/limine-uefi-cd.bin");
    _ = files.addCopyFile(b.path("limine/limine-bios-cd.bin"), "boot/limine-bios-cd.bin");
    _ = files.addCopyFile(b.path("limine/limine-bios.sys"), "boot/limine-bios.sys");
    _ = files.addCopyDirectory(b.path(img_root), "", .{});
    _ = files.addCopyDirectory(b.path("zig-out/ui"), "ui", .{}); // TGAs go in /ui

    const make_iso = b.addSystemCommand(&.{
        "xorriso",                     "-as",              "mkisofs",
        "-o",                          out,                "-b",
        "boot/limine-bios-cd.bin",     "-no-emul-boot",    "-boot-load-size",
        "4",                           "-boot-info-table", "--efi-boot",
        "EFI/BOOT/limine-uefi-cd.bin", "-efi-boot-part",   "--efi-boot-image",
        "--protective-msdos-label",
    });
    make_iso.addDirectoryArg(files.getDirectory());
    make_iso.step.dependOn(&files.step);

    const step = b.step("make-image", "Build the ISO image");
    b.getInstallStep().dependOn(step);
    step.dependOn(&make_iso.step);
    return Image{ .path = out, .step = step };
}

fn addUACPI(b: *std.Build, mod: *std.Build.Module) void {
    const path = "vendor/uACPI/source/";
    const dir = b.build_root.handle.openDir(path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open {s}: {s}", .{ path, @errorName(err) });
        exit(1);
    };

    var walker = dir.walk(b.allocator) catch |err| {
        std.log.err("Failed to walk {s}: {s}", .{ path, @errorName(err) });
        exit(1);
    };
    defer walker.deinit();

    while (walker.next() catch |err| @panic(@errorName(err))) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".c")) {
            mod.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ path, entry.path })), .flags = &.{} });
        }
    }
}
