const std = @import("std");
const root = @import("root");
const Disk = root.dev.Disk;
const Partition = root.dev.Partition;

const log = std.log.scoped(._gpt);

const ProtectiveMasterBootRecrod = packed struct {
    boot_indicator: u8, // set to zero to indicate a non bootable partition
    starting_chs: u24, // Set to 0x000200, corresponding to the Starting LBA field.
    os_type: u8, // Set to 0xEE (GPT Protective)
    ending_chs: u24, // Set to the CHS address of the last logical block on the disk. Set to 0xFFFFFF if the value cannot be represented in this field.
    starting_lba: u32, // Set to 0x00000001 (LBA of GPT Partition Header)
    ending_lba: u32, // Set to the size in logical blocks of the disk, minus one. Set to 0xFFFFFFFF if the size of the disk is too large to be represented in this field.
};

const PartitionTableHeader = extern struct {
    signature: [8]u8,
    gpt_revision: u32,
    header_size: u32,
    header_crc: u32,
    __reserved: u32,
    containing_lba: u64, // LBA containing this header
    alternate_lba: u64, // The lba of the alternate header
    first_usable_lba: u64, // first usable block
    last_usable_lba: u64, // last usable block
    guid: [16]u8,
    starting_lba: u64,
    num_partitions: u32,
    // Size (in bytes) of each entry in the Partition Entry array - must be a value of 128×2ⁿ where n ≥ 0 (in the past, multiples of 8 were acceptable)
    partition_entry_size: u32,
    crc32_of_partition_entry_array: u32,
};

const PartitionEntry = extern struct {
    guid: [16]u8,
    unique_guid: [16]u8,
    starting_lba: u64,
    ending_lba: u64,
    attributes: u64,
    name: [72]u8,
};

pub fn parse(disk: *Disk, allocator: std.mem.Allocator) !void {
    var header: PartitionTableHeader = undefined;
    try disk.readAll(1, std.mem.asBytes(&header));

    if (!std.mem.eql(u8, &header.signature, "EFI PART")) {
        log.err("Not a GPT disk", .{});
        return error.InvalidGPT;
    }

    disk.partitions = try allocator.alloc(?Partition, header.num_partitions);
    errdefer allocator.free(disk.partitions);

    const entry_start = header.starting_lba;
    for (0..header.num_partitions) |i| {
        var entry: PartitionEntry = undefined;
        const offset = (entry_start * disk.sectorSize()) + (i * header.partition_entry_size);
        try disk.readOffsetAll(offset, std.mem.asBytes(&entry));

        if (std.mem.allEqual(u8, &entry.guid, 0)) {
            disk.partitions[i] = null;
            continue;
        }

        var name_buf: [36]u8 = undefined;
        const utf16_in = std.mem.bytesAsSlice(u16, &entry.name);

        // find null terminator in utf16
        var utf16_len: usize = 0;
        while (utf16_len < utf16_in.len and utf16_in[utf16_len] != 0) : (utf16_len += 1) {}

        const n = std.unicode.utf16LeToUtf8(
            &name_buf,
            utf16_in[0..utf16_len],
        ) catch blk: {
            // fallback for non-unicode: strip the high byte
            var len: usize = 0;
            for (utf16_in[0..utf16_len]) |c| {
                name_buf[len] = @truncate(c);
                len += 1;
            }
            break :blk utf16_len;
        };

        const partition = Partition{
            .disk = disk,
            .name = .{
                .buf = name_buf,
                .len = @intCast(n),
            },
            .partuuid = .fromBytes(&entry.unique_guid),
            .guid = .fromBytes(&entry.guid),
            .start_lba = entry.starting_lba,
            .size_lba = entry.ending_lba - entry.starting_lba,
        };
        disk.partitions[i] = partition;

        log.info("Partion {f} is {s} <{f}>", .{ partition.name, partition.guid.asString(), partition.partuuid });
    }
}

pub fn savePartitions(disk: *Disk, allocator: std.mem.Allocator) !void {
    // read existing primary header so we preserve guid, alternate_lba, etc.
    var header: PartitionTableHeader = undefined;
    try disk.readAll(1, std.mem.asBytes(&header));

    if (!std.mem.eql(u8, &header.signature, "EFI PART")) {
        log.err("Cannot save: not a GPT disk", .{});
        return error.InvalidGPT;
    }

    const num_parts: u32 = @intCast(disk.partitions.len);
    const entry_size: u32 = @sizeOf(PartitionEntry);
    const entries_bytes = num_parts * entry_size;

    // build partition entry array
    const entry_buf = try allocator.alloc(u8, entries_bytes);
    defer allocator.free(entry_buf);
    @memset(entry_buf, 0);

    for (disk.partitions, 0..) |maybe_part, i| {
        const offset = i * entry_size;
        const entry_slice = entry_buf[offset..][0..entry_size];
        const entry: *PartitionEntry = @ptrCast(@alignCast(entry_slice));

        if (maybe_part) |part| {
            @memcpy(&entry.guid, &part.guid.toBytes());
            @memcpy(&entry.unique_guid, &part.partuuid.toBytes());
            entry.starting_lba = part.start_lba;
            entry.ending_lba = part.start_lba + part.size_lba;
            entry.attributes = 0;
            @memset(&entry.name, 0); // zero first so unused bytes are null
            const name_slice = part.name.slice();
            const utf16_out = std.mem.bytesAsSlice(u16, &entry.name);
            _ = std.unicode.utf8ToUtf16Le(utf16_out, name_slice) catch {
                log.warn("Partition name is not valid UTF-8, writing raw bytes", .{});
                // fallback: just copy bytes into low byte of each u16
                for (name_slice, 0..) |c, _i| {
                    utf16_out[_i] = c;
                }
            };
        }
        // null partition stays zeroed = unused entry
    }

    // update header fields
    header.num_partitions = num_parts;
    header.partition_entry_size = entry_size;
    header.crc32_of_partition_entry_array = std.hash.Crc32.hash(entry_buf);

    // clear header crc before computing it
    header.header_crc = 0;
    header.header_crc = std.hash.Crc32.hash(
        std.mem.asBytes(&header)[0..header.header_size],
    );

    // write primary header at LBA 1
    try disk.writeAll(1, std.mem.asBytes(&header));

    // write partition entries starting at header.starting_lba
    const sector_size = disk.sectorSize();
    const entry_offset = header.starting_lba * sector_size;
    // entries must be written sector-aligned; pad to sector boundary
    const padded_size = std.mem.alignForward(usize, entries_bytes, sector_size);
    const write_buf = try allocator.alloc(u8, padded_size);
    defer allocator.free(write_buf);
    @memset(write_buf, 0);
    @memcpy(write_buf[0..entries_bytes], entry_buf);
    try disk.writeAll(@intCast(entry_offset / sector_size), write_buf);

    // update backup header at alternate_lba
    header.containing_lba = header.alternate_lba;
    header.alternate_lba = 1;
    header.header_crc = 0;
    header.header_crc = std.hash.Crc32.hash(
        std.mem.asBytes(&header)[0..header.header_size],
    );
    try disk.writeAll(@intCast(header.containing_lba), std.mem.asBytes(&header));

    log.info("GPT saved: {d} partitions written", .{num_parts});
}

// convert GPT UTF-16LE name to a printable ASCII/latin1 buffer
fn gptNameToStr(name: [72]u8, buf: []u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i + 1 < name.len and len < buf.len) : (i += 2) {
        const lo = name[i];
        const hi = name[i + 1];
        if (lo == 0 and hi == 0) break; // null terminator
        // drop any non-ASCII code point, replace with '?'
        buf[len] = if (hi == 0 and lo >= 0x20 and lo < 0x7F) lo else '?';
        len += 1;
    }
    return buf[0..len];
}
