const std = @import("std");
const exit = std.process.exit;

pub const Programs = struct {
    step: *std.Build.Step,
    dir: std.Build.LazyPath,
};

pub fn makePrograms(b: *std.Build) Programs {
    const programs = "userland/programs";

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
