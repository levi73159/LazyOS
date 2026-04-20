const std = @import("std");
const exit = std.process.exit;

const Options = @import("Options.build.zig");

pub const Programs = struct {
    step: *std.Build.Step,
    dir: std.Build.LazyPath,
};

pub fn make(b: *std.Build, opts: Options) Programs {
    const rel_path = "programs";

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .dynamic_linker = .none,
        .ofmt = .elf,
        .os_tag = .linux,
    });

    const optimize = opts.optimize;

    const step = b.step("build-userland", "Build userland programs");

    // pull the artifact into ROOT's builder and install it there
    const shell_dep = b.dependency("shell", .{
        .target = target,
        .optimize = optimize,
    });

    const shell_exe = shell_dep.artifact("shell");
    const install = b.addInstallArtifact(shell_exe, .{ .dest_dir = .{ .override = .{ .custom = "programs" } } });
    install.step.dependOn(&shell_exe.step);
    step.dependOn(&install.step);

    const c_step = buildC(b, rel_path);
    step.dependOn(c_step);

    return .{
        .step = step,
        .dir = b.path("zig-out/" ++ rel_path),
    };
}

fn buildC(b: *std.Build, out: []const u8) *std.Build.Step {
    const programs = "userland/programs";

    var dir = b.build_root.handle.openDir(programs, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to open {s}: {s}", .{ programs, @errorName(err) });
        exit(1);
    };
    defer dir.close();

    const step = b.step("make-c-programs", "Build all C programs (userland/programs)");

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

        const install_file = b.addInstallFileWithDir(output_file, .{ .custom = out }, dupe_name);
        install_file.step.dependOn(&cmd.step);

        step.dependOn(&install_file.step);
    }

    return step;
}
