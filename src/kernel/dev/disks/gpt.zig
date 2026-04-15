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

        const partition = Partition{
            .disk = disk,
            .name = entry.name,
            .partuuid = .fromBytes(&entry.unique_guid),
            .guid = .fromBytes(&entry.guid),
            .start_lba = entry.starting_lba,
            .size_lba = entry.ending_lba - entry.starting_lba,
        };
        disk.partitions[i] = partition;

        log.info("Partion {s} is {s} <{f}>", .{ partition.name, partition.guid.asString(), partition.partuuid });
    }
}
