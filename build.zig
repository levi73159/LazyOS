const std = @import("std");
const exit = std.process.exit;

const image_name = "lazyos.img";

const Image = struct {
    path: std.Build.LazyPath,
    step: *std.Build.Step,
};

const Program = struct {
    path: std.Build.LazyPath,
    build_step: *std.Build.Step,
};

pub const Programs = struct {
    step: *std.Build.Step,
    dir: std.Build.LazyPath,
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

    const debug_int = b.option(bool, "int", "turn on interrupt logging for qemu using the -d int option") orelse false;
    const stal = b.option(bool, "stal", "doesn't shutdown or reboot") orelse false;
    const display = b.option([]const u8, "display", "choose display backend") orelse "sdl,gl=on";
    const optimize_mode: std.builtin.OptimizeMode = b.option(std.builtin.OptimizeMode, "optimize", "set the optimization mode") orelse switch (b.release_mode) {
        .off => std.builtin.OptimizeMode.ReleaseSafe,
        .any => std.builtin.OptimizeMode.ReleaseSafe,
        .fast => std.builtin.OptimizeMode.ReleaseFast,
        .safe => std.builtin.OptimizeMode.ReleaseSafe,
        .small => std.builtin.OptimizeMode.ReleaseSmall,
    };

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/root.zig"),
        .target = kernel_target,
        .optimize = optimize_mode,
        .code_model = .kernel,
        .red_zone = false,
        .sanitize_thread = false,
        .dwarf_format = .@"64",
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

    const programs = makePrograms(b);

    const image = makeImage(b, kernel, programs);
    image.step.dependOn(&install_kernel.step);

    // const run_qemu_cmd = b.addSystemCommand(&.{ "qemu-system-x86_64", "-hda", image.path, "-m", "32", "-debugcon", "stdio" });
    // run_qemu_cmd.step.dependOn(image.step);
    const run_qemu_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});
    run_qemu_cmd.addArg("-hda");
    run_qemu_cmd.addFileArg(image.path);
    run_qemu_cmd.addArgs(&.{
        "-machine", "q35,accel=kvm",
        "-cpu",     "host",
        "-display", display,
        "-serial",  "stdio",
    });

    if (stal) {
        run_qemu_cmd.addArgs(&.{ "-no-reboot", "-no-shutdown" });
    }
    if (debug_int) {
        run_qemu_cmd.addArgs(&.{ "-d", "int" });
    }
    run_qemu_cmd.addArgs(&.{ "-bios", "/usr/share/ovmf/x64/OVMF.4m.fd" });

    run_qemu_cmd.step.dependOn(image.step);

    const debug_cmd = b.addSystemCommand(&.{"scripts/debug.sh"});
    debug_cmd.addFileArg(image.path);
    debug_cmd.step.dependOn(image.step);

    const run = b.step("run", "Run the operating system");
    run.dependOn(&run_qemu_cmd.step);

    const debug = b.step("debug", "Debug the operating system");
    debug.dependOn(&debug_cmd.step);
}

pub fn makePrograms(b: *std.Build) Programs {
    const programs = "src/programs";

    var dir = b.build_root.handle.openDir(programs, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open {s}: {s}", .{ programs, @errorName(err) });
        exit(1);
    };
    defer dir.close();

    const step = b.step("make-programs", "Build all programs");

    var it = dir.iterate();
    while (it.next() catch |err| @panic(@errorName(err))) |entry| {
        if (entry.kind != .directory) continue;

        const name = entry.name;
        const path = b.pathJoin(&.{ programs, name });

        const cmd = b.addSystemCommand(&.{ "make", "-C" });
        cmd.addDirectoryArg(b.path(path));

        // iterate contents and add it as input to cmd args
        var program_dir = dir.openDir(name, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open {s}: {s}", .{ name, @errorName(err) });
            exit(1);
        };
        defer program_dir.close();

        var program_it = program_dir.iterate();
        while (program_it.next() catch |err| @panic(@errorName(err))) |program_entry| {
            if (program_entry.kind != .file) continue;
            cmd.addFileInput(b.path(b.pathJoin(&.{ path, program_entry.name })));
        }

        const dupe_name = b.dupe(name);
        const output_file = cmd.addPrefixedOutputFileArg("OUT=", name);
        _ = cmd.addPrefixedOutputDirectoryArg("OBJ_DIR=", "cache");

        const install_file = b.addInstallFileWithDir(output_file, .{ .custom = "programs" }, dupe_name);
        install_file.step.dependOn(&cmd.step);

        step.dependOn(&install_file.step);
    }

    return .{
        .step = step,
        .dir = b.path("zig-out/programs"),
    };
}

pub fn makeImage(b: *std.Build, kernel: *std.Build.Step.Compile, programs: Programs) Image {
    const img_root = "root";

    // Convert all PNGs to TGA into a staging directory, no originals leak in
    const convert = b.addSystemCommand(&.{
        "sh", "-c",
        "mkdir -p zig-out/ui && for f in assets/*.png; do " ++
            "magick \"$f\" \"zig-out/ui/$(basename ${f%.png}).tga\"; done",
    });

    const files = b.addWriteFiles();
    files.step.dependOn(&convert.step); // staging dir must exist before copy
    files.step.dependOn(programs.step);
    _ = files.addCopyDirectory(b.path(img_root), "", .{});
    _ = files.addCopyDirectory(b.path("zig-out/ui"), "ui", .{}); // TGAs go in /ui
    _ = files.addCopyDirectory(programs.dir, "bin", .{});

    const make_img = b.addSystemCommand(&.{ "bash", "scripts/make_img.sh" });
    // output declared first so Zig tracks it
    const img_out = make_img.addOutputFileArg(image_name);
    make_img.addArg("64");
    make_img.addDirectoryArg(files.getDirectory());
    make_img.addFileArg(kernel.getEmittedBin());
    make_img.step.dependOn(&files.step);
    make_img.step.dependOn(&kernel.step);

    // install the tracked output file
    const install_img = b.addInstallFileWithDir(img_out, .bin, image_name);
    install_img.step.dependOn(&make_img.step);
    b.getInstallStep().dependOn(&install_img.step);

    const step = b.step("make-image", "Build the ISO image");
    b.getInstallStep().dependOn(step);
    step.dependOn(&make_img.step);

    return Image{ .path = img_out, .step = step };
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
