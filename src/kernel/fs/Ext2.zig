const std = @import("std");
const root = @import("root");

const Disk = root.dev.Disk;

const log = std.log.scoped(._ext2);

pub const EXT2_SIGNATURE = 0xEF53;

/// located at byte 1024 and length 1024
/// Everything is little endian
pub const SuperBlock = extern struct {
    inodes_count: u32,
    blocks_count: u32,
    superuser_blocks: u32, // aka blocks reserved for superuser
    free_blocks_count: u32,
    free_inodes_count: u32,
    first_data_block: u32, // NOT ALWAYS 0
    log2_block_size: u32,
    log2_fragment_size: u32,
    blocks_per_group: u32,
    fragments_per_group: u32,
    inodes_per_group: u32,
    last_mount_time: u32,
    last_write_time: u32,
    mount_count: u16,
    max_mount_count: u16,
    signature: u16, // 0xEF53
    fs_state: u16,
    error_handling: u16,
    version_minor: u16,
    last_fsck_time: u32,
    interval_between_fcks: u32,
    osid: u32,
    version_major: u32,
    userid: u16,
    groupid: u16,
};

comptime {
    std.debug.assert(@sizeOf(SuperBlock) == 84);
}

// returns null if disk filesystem is not ext2
fn getSuperBlock(disk: *Disk) ?*SuperBlock {
    disk.read
}
