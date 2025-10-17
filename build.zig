const std = @import("std");

const disk_img = "disk.img";

const Bootloader = enum {
    uefi, // boot in UEFI
    disabled,
    // bios, // boot in BIOS
};

var bootloader_type: Bootloader = .uefi;
var bootloader_exe: ?*std.Build.Step.Compile = null;
var kernel_exe: *std.Build.Step.Compile = undefined;

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
    kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
        .use_llvm = true,
    });
    kernel_exe.entry = .disabled;

    kernel_exe.addIncludePath(b.path("src/kernel/headers"));

    std.log.debug("install path: {s}, prefix: {s}", .{ b.install_path, b.install_prefix });

    // ADD TESTS FOR BOOTLOADER AND KERNEL

    const test_step = b.step("test", "Run the tests (for bootloader and kernel)");
    if (uefi_dep) |dep| {
        const bootloader_test = dep.artifact("bootloader.test"); // bootloader tests
        test_step.dependOn(&bootloader_test.step);

        const run_test = b.addRunArtifact(bootloader_test);
        test_step.dependOn(&run_test.step);

        b.installArtifact(bootloader_test);
    }

    kernel_exe.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel_exe);

    const image = makeImage(b, kernel_exe, uefi_dep);

    const run_qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-hda",
    });
    run_qemu_cmd.addFileArg(image.path);
    run_qemu_cmd.addArgs(&.{
        "-cpu",
        "qemu64",
        "-m",
        "64M",
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

fn run(b: *std.Build, args: []const []const u8, print_output: bool) anyerror!void {
    std.debug.print("Running: ", .{});
    for (args) |arg| std.debug.print("{s} ", .{arg});
    std.debug.print("\n", .{});
    var child = std.process.Child.init(args, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = if (print_output) .Inherit else .Ignore;
    child.stderr_behavior = if (print_output) .Inherit else .Ignore;
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

var img_path: std.Build.LazyPath = undefined;

pub const GptHeader = packed struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    // disk_guid: [16]u8,
    // NOT ALLOW TO HAVE ARRAYS in packed structs
    disk_guid: u128,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    size_of_partition_entry: u32,
    partition_entry_array_crc32: u32,
};

pub const GptPartitionEntry = packed struct {
    type_guid: u128,
    unique_guid: u128,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    name: u576,
};

pub fn getOffset(b: *std.Build, path: []const u8, opt: std.Build.Step.MakeOptions) anyerror!u64 {
    const node = opt.progress_node.start("Get gpt header", 0);
    defer node.end();

    const sector_size = 512;

    // progress.start("Getting gpt header", 0);
    const file = try b.build_root.handle.openFile(path, .{ .mode = .read_only });
    defer file.close();

    var buf: [sector_size]u8 = undefined;
    var file_reader = file.reader(&buf);
    const reader = &file_reader.interface;

    try file_reader.seekTo(512);
    const header = try reader.takeStruct(GptHeader, .little);
    try file_reader.seekTo(header.partition_entry_lba * sector_size);
    const entry = try reader.takeStruct(GptPartitionEntry, .little);

    const offset = entry.first_lba * sector_size;
    return offset;
}

fn copy(b: *std.Build, location: []const u8, lazy_src: std.Build.LazyPath, dest: []const u8) anyerror!void {
    const prefixed_path = try std.fmt.allocPrint(b.allocator, "::{s}", .{dest});
    defer b.allocator.free(prefixed_path);

    const src = lazy_src.getPath(b);

    run(b, &.{ "mcopy", "-i", location, src, prefixed_path }, false) catch |err| switch (err) {
        error.ExitCode => {
            // make the directories with mmd then try again
            var split = std.mem.splitScalar(u8, dest, '/');
            var path = std.ArrayList(u8){};
            defer path.deinit(b.allocator);

            const slashes = std.mem.count(u8, dest, "/");
            var i: usize = 0;

            while (split.next()) |s| : (i += 1) {
                if (i == slashes) continue;
                try path.print(b.allocator, "/{s}", .{s});
                run(b, &.{ "mmd", "-i", location, path.items, "-D", "s" }, true) catch switch (err) {
                    error.ExitCode => continue, // ignore it if directory already exists
                    else => return err,
                };
            }
            try run(b, &.{ "mcopy", "-i", location, src, prefixed_path }, true);
        },
        else => return err,
    };
}

fn copyRoot(b: *std.Build, allocator: std.mem.Allocator, node: std.Progress.Node, location: []const u8, root: []const u8) anyerror!void {
    var dir = try b.build_root.handle.openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        defer node.completeOne();

        const prefixed_path = std.fmt.allocPrint(allocator, "::{s}", .{entry.path}) catch unreachable;

        if (entry.kind == .directory) {
            run(b, &.{ "mmd", "-i", location, prefixed_path, "-D", "s" }, true) catch |err| switch (err) {
                error.ExitCode => continue, // ignore it if directory already exists
                else => return err,
            };
        } else {
            const real_path = std.fs.path.join(allocator, &.{ root, entry.path }) catch unreachable;
            defer allocator.free(real_path);

            try run(b, &.{ "mcopy", "-i", location, real_path, prefixed_path }, true);
        }
    }
}

pub fn copyFiles(step: *std.Build.Step, opt: std.Build.Step.MakeOptions) anyerror!void {
    // const progress = options.progress_node;

    const b = step.owner;
    const path = img_path.getPath(b);
    std.log.debug("path: {s}", .{path});

    const offset = try getOffset(b, path, opt);

    const node = opt.progress_node.start("Copy All Files", 4);
    defer node.end();

    const location = std.fmt.allocPrint(opt.gpa, "{s}@@{d}", .{ path, offset }) catch unreachable;
    defer opt.gpa.free(location);

    try run(b, &.{ "mformat", "-i", location, "::" }, true);
    node.completeOne();

    // copy kernel and efi bootloader
    try copy(b, location, bootloader_exe.?.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    node.completeOne();
    try copy(b, location, kernel_exe.getEmittedBin(), "boot/kernel");
    node.completeOne();
    try copy(b, location, b.path("bootloader/config.cfg"), "boot/config.cfg");
    node.completeOne();

    const copy_root = node.start("Coping root files", 0);
    try copyRoot(b, opt.gpa, copy_root, location, "root");
    copy_root.end();
}

pub fn makeImage(b: *std.Build, kernel: *std.Build.Step.Compile, bootloader: ?*std.Build.Dependency) Image {
    const boot_exe = if (bootloader) |bld| bld.artifact("bootx64") else null;
    const install_path = b.getInstallPath(.prefix, disk_img);
    std.log.debug("install path: {s}", .{install_path});

    // make the disk image
    const create_img_file = b.addSystemCommand(&.{"scripts/make_img.sh"});
    img_path = create_img_file.addOutputFileArg("disk.img");
    create_img_file.addFileArg(boot_exe.?.getEmittedBin());
    create_img_file.addDirectoryArg(b.path("root"));

    // copy the files to the image
    const copy_files = b.step("copy-files", "Copy all files to the image");
    copy_files.dependOn(&create_img_file.step);
    copy_files.makeFn = copyFiles;

    copy_files.dependOn(&boot_exe.?.step);
    copy_files.dependOn(&kernel.step);

    // install the disk image to the install path
    const img_install = b.addInstallFile(img_path, "disk.img");
    img_install.step.dependOn(copy_files);

    const step = b.step("make-image", "Build the ISO image");
    step.dependOn(&img_install.step);

    b.installArtifact(boot_exe.?);
    b.getInstallStep().dependOn(step);

    return .{
        .step = step,
        .path = img_path,
    };
}
