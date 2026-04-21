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

    const make_boot = b.addSystemCommand(&.{"scripts/make_boot.sh"});
    make_boot.addFileArg(kernel.getEmittedBin());
    const boot_fat = make_boot.addOutputFileArg("boot.fat");
    make_boot.step.dependOn(&kernel.step);

    const make_root = b.addSystemCommand(&.{"scripts/make_root.sh"});
    make_root.addDirectoryArg(files.getDirectory());
    const root_ext2 = make_root.addOutputFileArg("root.ext2");
    make_root.step.dependOn(&files.step);

    const make_img = b.addSystemCommand(&.{"scripts/make_img.sh"});
    make_img.addFileArg(boot_fat);
    make_img.addFileArg(root_ext2);
    const img_out = make_img.addOutputFileArg("lazyos.img");
    make_img.addArg("64"); // 64MB

    // install the tracked output file
    const install_img = b.addInstallFileWithDir(img_out, .bin, image_name);
    install_img.step.dependOn(&make_img.step);

    const install_kernel = b.addInstallArtifact(kernel, .{});
    install_img.step.dependOn(&install_kernel.step);

    const step = b.step("make-image", "Build the ISO image");
    b.getInstallStep().dependOn(step);
    step.dependOn(&install_img.step);

    return Image{ .path = img_out, .step = step };
}
