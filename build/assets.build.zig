const std = @import("std");

// build/assets.zig
pub const ConvertedAssets = struct {
    step: *std.Build.Step,
    dir: std.Build.LazyPath,
};

pub fn convert(b: *std.Build) ConvertedAssets {
    const cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "mkdir -p zig-out/ui && for f in assets/*.png; do " ++
            "magick \"$f\" \"zig-out/ui/$(basename ${f%.png}).tga\"; done",
    });
    return .{
        .step = &cmd.step,
        .dir = b.path("zig-out/ui"),
    };
}
