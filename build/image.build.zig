const std = @import("std");
const Programs = @import("programs.build.zig").Programs;
const ConvertedAssets = @import("assets.build.zig").ConvertedAssets;

const image_name = "lazyos.img";

pub const Image = struct {
    path: std.Build.LazyPath,
    step: *std.Build.Step,
};

pub fn make(b: *std.Build, kernel: *std.Build.Step.Compile, programs: Programs, converted: ConvertedAssets) Image {
    const img_root = "root";

    const files = b.addWriteFiles();
    files.step.dependOn(converted.step); // staging dir must exist before copy
    files.step.dependOn(programs.step);
    _ = files.addCopyDirectory(b.path(img_root), "", .{});
    _ = files.addCopyDirectory(b.path("zig-out/ui"), "ui", .{}); // TGAs go in /ui
    _ = files.addCopyDirectory(programs.dir, "bin", .{});

    const ask_sudo = b.addSystemCommand(&.{ "sudo", "-v" });
    ask_sudo.stdio = .inherit;

    const make_img = b.addSystemCommand(&.{ "bash", "scripts/make_img.sh" });
    make_img.step.dependOn(&ask_sudo.step);
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

    const step = b.step("make-image", "Build the ISO image");
    b.getInstallStep().dependOn(step);
    step.dependOn(&install_img.step);

    return Image{ .path = img_out, .step = step };
}
