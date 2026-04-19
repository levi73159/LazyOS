const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });

    const optimize = b.standardOptimizeOption(.{});

    const uacpi_include = b.option(std.Build.LazyPath, "uacpi", "Path to uACPI include directory") orelse {
        std.log.err("Missing uACPI include directory", .{});
        std.process.exit(1);
    };

    const kernel_mod = b.addModule("kernel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .sanitize_thread = false,
        .dwarf_format = .@"64",
        .pic = false,
        .strip = false,
        .omit_frame_pointer = false,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });

    b.installArtifact(kernel);

    kernel.use_llvm = true;
    kernel.use_lld = true;
    kernel.setLinkerScript(b.path("linker.ld"));
    kernel.pie = false;
    kernel.entry = .disabled;

    kernel_mod.addAssemblyFile(b.path("src/arch/arch.s"));
    kernel_mod.addIncludePath(uacpi_include);
}
