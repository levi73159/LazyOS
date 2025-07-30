const std = @import("std");
const process = std.process;

const os_name = "LAZYOS"; // all caps
const fat = "12"; // FAT12, FAT16, FAT32
const floppy_path = "zig-out/main_floppy.img";

pub fn handleError(msg: []const u8, err: anyerror) noreturn {
    std.debug.print("Error: {s}: {s}\n", .{ msg, @errorName(err) });
    process.exit(1);
}

pub fn build(b: *std.Build) void {
    make(b.allocator, "src/bootloader/") catch |err| handleError("Failed to make bootloader", err);
    make(b.allocator, "src/kernel/") catch |err| handleError("Failed to make kernel", err);

    const floppy_step = makeFloppyImage(b);

    const run = b.step("run", "Run the os (requires qemu)");
    const qemu_cmd = b.addSystemCommand(&.{ "qemu-system-i386", "-fda", floppy_path });

    run.dependOn(&qemu_cmd.step);

    qemu_cmd.step.dependOn(floppy_step);
    b.default_step.dependOn(floppy_step);

    tools(b) catch |err| handleError("Failed to build tools", err);
}

fn make(allocator: std.mem.Allocator, folder: []const u8) !void {
    std.log.info("Building {s}...", .{folder});
    var child = std.process.Child.init(&.{ "make", "-C", folder }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();

    if (term != .Exited) return error.MakeFailed;
    if (term.Exited != 0) return error.MakeFailed;
}

fn makeFloppyImage(b: *std.Build) *std.Build.Step {
    const floppy_step = b.step("floppy", "Make floppy image");

    const make_floppy = b.addSystemCommand(&.{ "dd", "if=/dev/zero", "of=" ++ floppy_path, "bs=512", "count=2880" });

    const make_fat = b.addSystemCommand(&.{ "mkfs.fat", "-F", fat, "-n", os_name, floppy_path });
    make_fat.step.dependOn(&make_floppy.step);

    // make floppy start with bootloader
    const copy_bootloader = b.addSystemCommand(&.{ "dd", "if=" ++ "zig-out/bin/bootloader.bin", "of=" ++ floppy_path, "conv=notrunc" });
    copy_bootloader.step.dependOn(&make_fat.step);

    // copy kernel to floppy
    const copy_kernel = b.addSystemCommand(&.{ "mcopy", "-i", floppy_path, "zig-out/bin/kernel.bin", "::kernel.bin" });
    copy_kernel.step.dependOn(&copy_bootloader.step);

    var root = std.fs.cwd().openDir("root", .{ .iterate = true }) catch |err| handleError("Failed to open root folder", err);
    defer root.close();

    var it = root.iterate();

    while (it.next() catch |err| handleError("Failed to iterate root folder", err)) |entry| {
        if (entry.kind != .file) {
            std.log.warn("Not a file: {s}", .{entry.name});
            continue;
        }

        const copy_file = b.addSystemCommand(&.{ "mcopy", "-i", floppy_path, b.pathJoin(&.{ "root", entry.name }), b.fmt("::{s}", .{entry.name}) });
        copy_file.step.dependOn(&copy_kernel.step);
        floppy_step.dependOn(&copy_file.step);
    }

    return floppy_step;
}

/// a function that will build everything in the tools folder
/// and install them if the `tools` step is run
/// and add a run step for each that will be the name of the tool
/// every tool must have a main.zig file in it
fn tools(b: *std.Build) !void {
    // get all folders in tools folder
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    var tools_folder = std.fs.cwd().openDir("tools", .{ .iterate = true }) catch |err| handleError("Failed to open tools folder", err);
    defer tools_folder.close();

    var tools_iter = tools_folder.iterate();

    const tools_step = b.step("tools", "Build all tools");

    while (try tools_iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const name = b.allocator.dupe(u8, entry.name) catch @panic("OOM");

        // create an executable
        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.pathJoin(&.{ "tools", name, "main.zig" })),
            .target = target,
            .optimize = optimize,
        });

        // get the install step
        const install_step = b.addInstallArtifact(exe, .{ .dest_sub_path = b.fmt("tools/{s}", .{name}) });
        tools_step.dependOn(&install_step.step); // tools step depends on install step of each tool

        // get a run command and step
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&install_step.step);

        const run_step = b.step(name, b.fmt("Run {s} tool", .{name}));
        run_step.dependOn(&run_cmd.step);

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
}
