const std = @import("std");
const root = @import("root");
const Command = @import("Command.zig");
const console = root.console;
const acpi = root.acpi;
const Shell = root.Shell;
const bootinfo = root.arch.bootinfo;
const scheduler = root.proc.scheduler;
const Process = root.proc.Process;

pub const commands = &[_]Command{ Command{
    .name = "echo",
    .help = "Prints to the screen",
    .handler = echo,
}, Command{
    .name = "clear",
    .help = "Clears the screen",
    .handler = clear,
}, Command{
    .name = "help",
    .help = "Prints this help message",
    .handler = help,
}, Command{
    .name = "restart",
    .help = "Restarts the system",
    .handler = restart,
}, Command{
    .name = "shutdown",
    .help = "Shuts down the system",
    .handler = shutdown,
}, Command{
    .name = "pwd",
    .help = "Prints the current working directory",
    .handler = pwd,
}, Command{
    .name = "cd",
    .help = "Changes the current working directory",
    .handler = cd,
}, Command{
    .name = "ls",
    .help = "Lists the contents of the current working directory",
    .handler = ls,
}, Command{
    .name = "cat",
    .help = "Prints the contents of a file",
    .handler = cat,
}, Command{
    .name = "gfx",
    .help = "Open the graphical gui",
    .handler = gfx,
}, Command{
    .name = "run",
    .help = "Run a program",
    .handler = run,
}, Command{
    .name = "disk",
    .help = "Disk commands",
    .handler = diskCmd,
} };

// *const fn (cwd: []const u8, args: []const []const u8) anyerror!void,

pub fn echo(_: *Shell, args: []const []const u8) anyerror!void {
    for (args) |arg| {
        console.print("{s} ", .{arg});
    }
    console.print("\n", .{});
}

pub fn clear(_: *Shell, _: []const []const u8) anyerror!void {
    console.clear();
}

pub fn help(_: *Shell, _: []const []const u8) anyerror!void {
    for (commands) |cmd| {
        console.print("{s}: {s}\n", .{ cmd.name, cmd.help });
    }
}

pub fn restart(_: *Shell, _: []const []const u8) anyerror!void {
    console.print("restarting...\n", .{});
    acpi.reboot();
    std.log.warn("reboot failed", .{});
}

pub fn shutdown(_: *Shell, _: []const []const u8) anyerror!void {
    console.print("shutting down...\n", .{});
    acpi.shutdown();
    std.log.warn("shutdown failed", .{});
}

pub fn pwd(s: *Shell, _: []const []const u8) anyerror!void {
    console.print("{s}\n", .{s.cwd});
}

pub fn cd(s: *Shell, args: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    const old = s.cwd;
    errdefer s.cwd = old;
    if (args.len == 0) {
        s.cwd = "/";
    } else {
        // combine the two using s.internal_cmd_buffer
        const cwd = try s.combinePath(args[0]);
        s.cwd = cwd;
    }

    _ = s.fs.?.stat(s.cwd) catch |err| {
        if (err == error.FileNotFound) {
            console.print("No such directory: {s}\n", .{s.cwd});
            s.cwd = old;
            return;
        } else {
            return err;
        }
    };

    s.allocator.free(old);
    s.cwd = try s.prettyCWD();
}

fn ls(s: *Shell, args: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    const path = if (args.len == 0) s.cwd else try s.combinePath(args[0]);

    const fs = s.fs.?;
    var it = try fs.it(path);
    while (try it.next()) |entry| {
        console.print("{s}\n", .{entry.name});
    }
}

fn cat(s: *Shell, args: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    if (args.len == 0) {
        console.print("Usage: cat <file>\n", .{});
        return;
    }
    const path = try s.combinePath(args[0]);

    const fs = s.fs.?;
    var file = try fs.open(path);
    defer file.close();

    var buf: [4096]u8 = undefined;
    const data = try file.readAll(&buf);
    console.write(data);
}

fn gfx(_: *Shell, _: []const []const u8) anyerror!void {
    const Screen = @import("../graphics/Screen.zig");
    const renderer = @import("../graphics/renderer.zig");
    if (!renderer.isInitialized()) return error.RendererNotInitialized;
    renderer.drawLoop(Screen.get());
}

fn run(s: *Shell, args: []const []const u8) anyerror!void {
    if (s.fs == null) return error.UnableToFetchFileSystem;
    const fs = s.fs.?;
    const name = args[0];

    std.log.debug("Running {s}", .{name});
    const path = try std.mem.join(s.allocator, "/", &[_][]const u8{ "/bin", name });
    defer s.allocator.free(path);

    var file = try fs.open(path);
    defer file.close();

    if (!file.handle.flags.executable) return error.NotExecutable;

    std.log.debug("File opened: {s}", .{path});
    const data = try file.readAlloc(s.allocator);
    defer s.allocator.free(data);

    std.log.debug("data read", .{});
    const process = try s.allocator.create(Process);
    errdefer s.allocator.destroy(process);

    std.log.debug("process created", .{});
    process.* = try Process.loadElf(data, s.allocator);
    errdefer process.deinit(s.allocator);

    std.log.debug("elf loaded", .{});
    const id = try scheduler.spawnProcess(process);
    std.log.debug("Spawned process with id {d}", .{id});

    const exit_code = scheduler.waitForTaskToExit(id);
    if (exit_code != 0) {
        console.print("Process exited with code {d}\n", .{exit_code});
    }
}

pub fn diskCmd(s: *Shell, args: []const []const u8) anyerror!void {
    const Disk = root.dev.Disk;

    var model: [40]u8 = undefined;
    var serial: [20]u8 = undefined;
    const disk_cmd = args[0];
    if (std.mem.eql(u8, "list", disk_cmd)) {
        for (0..Disk.disks.len) |i| {
            const disk = Disk.get(@intCast(i)) orelse continue;
            const model_str = disk.getModelNumber(&model);
            const serial_str = disk.getSerialNumber(&serial);
            const size_bytes = disk.getTotalSize();
            const size_gb = size_bytes;
            console.print(
                \\Disk {d}:
                \\  Model: {s}
                \\  Serial: {s}
                \\  Size: {d} B
                \\
            , .{ i, model_str, serial_str, size_gb });
        }
        return;
    }
    if (std.mem.eql(u8, "drive", disk_cmd)) {
        const drive = std.fmt.parseInt(u8, args[1], 10) catch return error.InvalidDisk;
        const disk = Disk.get(drive) orelse return error.InvalidDisk;

        const drive_cmd = args[2];
        if (std.mem.eql(u8, "info", drive_cmd)) {
            const model_str = disk.getModelNumber(&model);
            const serial_str = disk.getSerialNumber(&serial);
            const size_bytes = disk.getTotalSize();
            console.print(
                \\Disk {d}:
                \\  Model: {s}
                \\  Serial: {s}
                \\  Size: {d} B
                \\
            , .{ drive, model_str, serial_str, size_bytes });
            return;
        }

        if (std.mem.eql(u8, "part", drive_cmd)) {
            return partSubcmd(disk, args[3..]);
        }

        if (std.mem.eql(u8, "write", drive_cmd)) {
            const sector = std.fmt.parseInt(u32, args[3], 10) catch return error.InvalidDisk;
            const data = try std.mem.join(s.allocator, "", args[4..]);
            defer s.allocator.free(data);

            try disk.writeAll(sector, data);
            std.log.debug("Write {d} bytes to sector {d}", .{ data.len, sector });
            return;
        }

        if (std.mem.eql(u8, "read", drive_cmd)) {
            const sector = std.fmt.parseInt(u32, args[3], 10) catch return error.InvalidDisk;
            const size = std.fmt.parseInt(u32, args[4], 10) catch return error.InvalidDisk;

            const buf = try s.allocator.alloc(u8, size);
            defer s.allocator.free(buf);

            try disk.readAll(sector, buf);
            console.write(buf);
            std.log.debug("Read {d} bytes from sector {d}", .{ size, sector });
            return;
        }
    }

    std.log.err("Invalid disk command", .{});
    return error.InvalidDisk;
}

fn partSubcmd(disk: *root.dev.Disk, args: []const []const u8) anyerror!void {
    const part_cmd = args[0];
    if (std.mem.eql(u8, "list", part_cmd)) {
        const what = if (args.len > 1) args[1] else "default";
        for (disk.partitions) |maybe_part| {
            const part = maybe_part orelse continue;
            if (std.mem.eql(u8, what, "default")) {
                console.print("{f} <{f}>\n", .{ part.name, part.partuuid });
            } else {
                var spl = std.mem.tokenizeScalar(u8, what, ',');
                var name: bool = false;
                var uuid: bool = false;
                var guid: bool = false;
                var size: bool = false;

                while (spl.next()) |token| {
                    if (std.mem.eql(u8, token, "name")) name = true;
                    if (std.mem.eql(u8, token, "uuid")) uuid = true;
                    if (std.mem.eql(u8, token, "guid")) guid = true;
                    if (std.mem.eql(u8, token, "size")) size = true;
                }
                if (name) console.print("{f} ", .{part.name});
                if (guid) console.print("is {s}", .{part.guid.asString()});
                if (uuid) console.print("<{f}>", .{part.partuuid});
                if (size) console.print("size: {d} B", .{part.size_lba * disk.sectorSize()});
                console.putchar('\n');
            }
        }
        return;
    }

    if (std.mem.eql(u8, "set", part_cmd)) {
        if (args.len < 3) {
            std.log.err("Usage: disk drive part set [id: -n{{name}} -u{{uuid}} -i{{index}}] [root,filesystem]", .{});
            return;
        }
        const identifier = args[1];
        const partition = getPart(disk, identifier) orelse {
            std.log.err("No such partition", .{});
            return;
        };

        const what = args[2];
        if (std.mem.eql(u8, what, "root")) {
            partition.guid = .linux_root_x86_64;
            disk.savePartitions(); // writes to disk
        } else {
            std.log.err("Invalid partition flag!", .{});
        }
        return;
    }

    std.log.err("Invalid partition command: {s}", .{part_cmd});
}

fn getPart(disk: *root.dev.Disk, identifier: []const u8) ?*root.dev.Partition {
    if (std.mem.startsWith(u8, identifier, "-n")) {
        const name = identifier[2..];
        for (disk.partitions) |*maybe_part| {
            const part = maybe_part.* orelse continue;
            if (std.mem.eql(u8, name, part.name.slice())) return &maybe_part.*.?;
        }
        return null;
    }

    if (std.mem.startsWith(u8, identifier, "-u")) {
        std.log.err("UUID seraching not implemented", .{});
        return null;
    }

    if (std.mem.startsWith(u8, identifier, "-i")) {
        const index = std.fmt.parseInt(u8, identifier[2..], 10) catch return null;
        if (index >= disk.partitions.len) return null;
        if (disk.partitions[index] == null) return null;
        return &disk.partitions[index].?;
    }

    return null;
}
