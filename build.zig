const std = @import("std");
const process = std.process;

const os_name = "LAZYOS"; // all caps
const fat = "12"; // FAT12, FAT16, FAT32
const floppy_path = "zig-out/main_floppy.img";

pub fn build(b: *std.Build) void {
    make(b.allocator, "src/bootloader/") catch |err| {
        std.debug.print("Error: Failed to make bootloader: {s}\n", .{
            @errorName(err),
        });
        process.exit(1);
    };

    make(b.allocator, "src/kernel/") catch |err| {
        std.debug.print("Error: Failed to make kernel: {s}\n", .{
            @errorName(err),
        });
        process.exit(1);
    };

    const floppy_step = makeFloppyImage(b);

    const run = b.step("run", "Run the os (requires qemu)");
    const qemu_cmd = b.addSystemCommand(&.{ "qemu-system-i386", "-fda", floppy_path });

    run.dependOn(&qemu_cmd.step);

    qemu_cmd.step.dependOn(floppy_step);
    b.default_step.dependOn(floppy_step);
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

    floppy_step.dependOn(&copy_kernel.step);

    return floppy_step;
}
