const std = @import("std");
const root = @import("root");

const FS = root.fs.FileSystem;
const FileHandle = FS.Handle;

const mem = std.mem;
const Parition = root.dev.Partition;

const Disk = root.dev.Disk;

const Self = @This();

const log = std.log.scoped(._ext2);

pub const EXT2_SIGNATURE = 0xEF53;

// Permissions
pub const OTHER_EXE_PERM = 0x001;
pub const OTHER_WRITE_PERM = 0x002;
pub const OTHER_READ_PERM = 0x004;
pub const GROUP_EXE_PERM = 0x008;
pub const GROUP_WRITE_PERM = 0x010;
pub const GROUP_READ_PERM = 0x020;
pub const USER_EXE_PERM = 0x040;
pub const USER_WRITE_PERM = 0x080;
pub const USER_READ_PERM = 0x100;
pub const STICKY_BIT_PERM = 0x200;
pub const SET_GROUP_ID_PERM = 0x400;
pub const SET_USER_ID_PERM = 0x800;

// Type
pub const TYPE_FIFO = 0x1000;
pub const TYPE_CHR_DEV = 0x2000;
pub const TYPE_DIR = 0x4000;
pub const TYPE_BLK_DEV = 0x6000;
pub const TYPE_REG = 0x8000;
pub const TYPE_SYMLINK = 0xA000;
pub const TYPE_SOCK = 0xC000;

// Inode flags
pub const SECURE_DELETE = 0x0001;
pub const COPY_DATA_ON_DELETE = 0x0002;
pub const FILE_COMPRESSION = 0x0004;
pub const SYNC_UPDATES = 0x0008; // new data is written to disk immediately
pub const IMMUTABLE = 0x0010;
pub const APPEND_ONLY = 0x0020;
pub const NO_INCLUDE_DUMP = 0x0040; // File is not included in 'dump' command
pub const NO_UPDATE_LAST_ACCESS = 0x0080;
// .. reserved
pub const HASH_INDEXED_DIRECTORY = 0x00010000;
pub const AFS_DIRECTORY = 0x00020000;
pub const JOURNAL_DATA = 0x00040000;

pub const ROOT_INODE = 2;

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
    fs_state: u16, // 1: clean, 2: errors
    error_handling: ErrorHandlingMethod,
    version_minor: u16,
    last_fsck_time: u32,
    interval_between_fcks: u32,
    osid: OperatingSystemId,
    version_major: u32,
    userid: u16,
    groupid: u16,
};

pub const ExtendedSuperBlock = extern struct {
    first_non_reserved_inode: u32,
    size_of_inode: u16,
    this_block_group: u16,
    optional_features: u32,
    required_features: u32,
    readonly_features: u32,
    file_system_id: [16]u8,
    volume_name: [16]u8,
    last_mount_path: [64]u8,
    compression_algorithm_used: u32,
    /// number of blocks to preallocate for files
    file_prealloc: u8,
    /// number of blocks to preallocate for directories
    dir_prealloc: u8,
    __unused: u16,
    journal_id: [16]u8,
    journal_inode: u32,
    journal_device: u32,
    head_orphan_inode_list: u32,
};

pub const BlockGroupDescriptor = extern struct {
    block_bitmap: u32,
    inode_bitmap: u32,
    inode_table: u32,

    free_blocks_count: u16,
    free_inodes_count: u16,
    used_dirs_count: u16,

    pad: u16,

    reserved: [3]u32,
};

pub const Inode = extern struct {
    type_and_perms: u16,
    userid: u16,
    size_low: u32,
    last_access_time: u32,
    creation_time: u32,
    last_modification_time: u32,
    deletion_time: u32,
    groupid: u16,
    /// Count of hard links (directory entries) to this inode. When this reaches 0, the data blocks are marked as unallocated.
    hard_links_count: u16,
    /// Count of disk sectors (not Ext2 blocks) in use by this inode, not counting the actual inode structure nor directory entries linking to the inode.
    sector_count: u32,
    flags: u32,
    os_specific1: u32,
    direct_ptr0: u32,
    direct_ptr1: u32,
    direct_ptr2: u32,
    direct_ptr3: u32,
    direct_ptr4: u32,
    direct_ptr5: u32,
    direct_ptr6: u32,
    direct_ptr7: u32,
    direct_ptr8: u32,
    direct_ptr9: u32,
    direct_ptr10: u32,
    direct_ptr11: u32,
    singly_indirect_ptr: u32,
    doubly_indirect_ptr: u32,
    triply_indirect_ptr: u32,
    generation: u32,
    extended_attr_block: u32,
    size_high: u32,
    fragment_address: u32,
    os_specific2: [3]u32,

    pub fn isDir(self: *const Inode) bool {
        return self.type_and_perms & 0xF000 == TYPE_DIR;
    }

    pub fn isFile(self: *const Inode) bool {
        return self.type_and_perms & 0xF000 == TYPE_REG;
    }

    pub fn size(self: *const Inode) u64 {
        return @as(u64, self.size_high) << 32 | self.size_low;
    }
};

pub const DirEntry = extern struct {
    inode: u32,
    total_size: u16,
    name_length: u8,
    file_type: u8,
    // name follows immediately after this
};

pub const ErrorHandlingMethod = enum(u16) { ignore = 1, remount_readonly = 2, panic = 3 };
pub const OperatingSystemId = enum(u32) {
    linux = 0,
    hurd = 1,
    masix = 2,
    freebsd = 3,
    lites = 4,
};

comptime {
    std.debug.assert(@sizeOf(SuperBlock) == 84);
    std.debug.assert(@sizeOf(BlockGroupDescriptor) == 32);
    std.debug.assert(@sizeOf(Inode) == 128);
}

const InodeCacheObject = struct {
    inode: Inode,
    ref_count: u32,
};

const InodeWNumber = struct {
    inode: Inode,
    number: u32,
};

partition: *Parition,
superblock: SuperBlock,
ext_superblock: ?ExtendedSuperBlock = null,
block_size: u32,
inode_size: u32,
bgdt: []BlockGroupDescriptor,
root_inode: *const Inode,
allocator: mem.Allocator,
inode_cache: std.AutoHashMapUnmanaged(u32, InodeCacheObject),

// returns null if disk filesystem is not ext2
fn getSuperBlocks(partition: *Parition) ?struct { base: SuperBlock, extended: ?ExtendedSuperBlock } {
    var superblock: SuperBlock = undefined;
    partition.readAll(1024, std.mem.asBytes(&superblock)) catch {
        log.err("Failed to read superblock", .{});
        return null;
    };

    if (superblock.version_major < 1) return .{ .base = superblock, .extended = null };

    var extended: ExtendedSuperBlock = undefined;
    partition.readAll(1024 + @sizeOf(SuperBlock), std.mem.asBytes(&extended)) catch {
        log.err("Failed to read extended superblock", .{});
        return null;
    };

    return .{ .base = superblock, .extended = extended };
}

fn getRootPartition(disk: *Disk) ?*Parition {
    return disk.getPartitionFromGUID(.linux_root_x86_64, false) orelse blk: {
        log.warn("No root partition found, searching for generic filesystem", .{});
        const part = disk.getPartitionFromGUID(.linux_filesystem, true);
        if (part == null) {
            log.err("Can't find a filesystem that can be used (or their is more than one)", .{});
        }
        break :blk part;
    };
}

fn getBlockDescriptorTable(partition: *Parition, superblock: *const SuperBlock, allocator: mem.Allocator) ![]BlockGroupDescriptor {
    const block_size: u32 = @as(u32, 1024) << @intCast(superblock.log2_block_size);
    const bgdt_block: u32 = if (block_size == 1024) 2 else 1;

    const bgdt_offset = bgdt_block * block_size;
    const num_groups = blk: {
        const a = std.math.divCeil(u32, superblock.blocks_count, superblock.blocks_per_group) catch unreachable;
        const b = std.math.divCeil(u32, superblock.inodes_count, superblock.inodes_per_group) catch unreachable;
        // should be the same
        if (a != b) {
            log.warn("Block group count mismatch: blocks={d} inodes={d}", .{ a, b });
            return error.UnmatchedInodesAndBlocks;
        }
        break :blk a;
    };

    const desc_size = @sizeOf(BlockGroupDescriptor);
    const table_bytes = num_groups * desc_size;

    const table_blocks = try std.math.divCeil(u32, table_bytes, block_size);
    const read_size = table_blocks * block_size;

    var raw = try allocator.alloc(u8, read_size);
    defer allocator.free(raw);

    try partition.readAll(bgdt_offset, raw);

    const bgdt = try allocator.alloc(BlockGroupDescriptor, num_groups);
    @memcpy(std.mem.sliceAsBytes(bgdt), raw[0..table_bytes]);

    return bgdt;
}

fn readBlock(self: *Self, block: u32, buf: []u8) !void {
    const offset = block * self.block_size;

    try self.partition.readAll(offset, buf);
}

pub fn init(disk: *Disk) !Self {
    const part = getRootPartition(disk) orelse {
        log.err("No root partition found", .{});
        return error.NoRootPartition;
    };
    log.info("Found filesystem: {f} <{f}>", .{ part.name, part.partuuid });

    const superblock = getSuperBlocks(part) orelse {
        log.err("No superblock found", .{});
        return error.NoSuperBlock;
    };

    if (superblock.base.signature != EXT2_SIGNATURE) return error.InvalidExt2;

    const allocator = root.heap.allocator();
    const bgdt = try getBlockDescriptorTable(part, &superblock.base, allocator);
    errdefer allocator.free(bgdt);

    var self = Self{
        .partition = part,
        .superblock = superblock.base,
        .ext_superblock = superblock.extended,
        .block_size = @as(u32, 1024) << @intCast(superblock.base.log2_block_size),
        .inode_size = if (superblock.extended) |ext| ext.size_of_inode else 128,
        .bgdt = bgdt,
        .allocator = allocator,
        .root_inode = undefined,
        .inode_cache = .{},
    };

    const inode = try self.getInodePartition(ROOT_INODE);
    const root_inode = try self.allocator.create(Inode);
    root_inode.* = inode;
    self.root_inode = root_inode;

    return self;
}

pub fn deinit(self: *Self) void {
    self.inode_cache.deinit(self.allocator);
    self.allocator.destroy(self.root_inode);
    self.allocator.free(self.bgdt);
}

/// This function always get the inode from the partition, it will never check cache inodes, will always fetch inode from disk, aka partition, it doesn't cache the inode either
fn getInodePartition(self: *Self, number: u32) !Inode {
    const block_group = (number - 1) / self.superblock.inodes_per_group;
    const index = (number - 1) % self.superblock.inodes_per_group;

    const bgdt = self.bgdt[block_group];

    const table_offset = bgdt.inode_table * self.block_size;
    const inode_offset = table_offset + (index * self.inode_size);

    var inode: Inode = undefined;

    try self.partition.readAll(inode_offset, std.mem.asBytes(&inode));
    return inode;
}

fn getInode(self: *Self, number: u32) !Inode {
    if (number == ROOT_INODE) return self.root_inode.*;

    const get_or_put = try self.inode_cache.getOrPut(self.allocator, number);
    if (get_or_put.found_existing) {
        get_or_put.value_ptr.ref_count += 1;
        return get_or_put.value_ptr.inode;
    }

    const inode = try self.getInodePartition(number);
    get_or_put.value_ptr = InodeCacheObject{
        .inode = inode,
        .ref_count = 1,
    };

    return inode;
}

// gets the inode, if in cache, gets it (don't increment ref count) if not in cache, gets it from the partition
fn getInodeNoRef(self: *Self, number: u32) !Inode {
    if (number == ROOT_INODE) return self.root_inode.*;

    if (self.inode_cache.get(number)) |inode| return inode.inode;

    const inode = try self.getInodePartition(number);
    return inode;
}

// Maybe make a wrapper around inode that will store the inode data and the inode number??
pub fn freeInode(self: *Self, number: u32) void {
    if (number == ROOT_INODE) return; // Can't free root inode
    const inode = self.inode_cache.getPtr(number) orelse return;

    if (inode.ref_count == 1) {
        _ = self.inode_cache.remove(number);
    } else {
        inode.ref_count -= 1;
    }
}

fn cacheInode(self: *Self, number: u32, inode: Inode) void {
    const get_or_put = self.inode_cache.getOrPut(self.allocator, number) catch unreachable;
    if (get_or_put.found_existing) {
        get_or_put.value_ptr.ref_count += 1;
        get_or_put.value_ptr.inode = inode; // the newest inode
    } else {
        get_or_put.value_ptr.* = InodeCacheObject{
            .inode = inode,
            .ref_count = 1,
        };
    }
}

pub fn detectExt2(disk: *Disk) bool {
    const part = getRootPartition(disk) orelse {
        log.err("No root partition found", .{});
        return false;
    };

    const superblocks = getSuperBlocks(part) orelse {
        return false;
    };

    if (superblocks.base.signature != EXT2_SIGNATURE) return false;
    return true;
}

// ============= IO  functions =============
// this functions tries to fill buffer with as much data as possible from disk and returns the number of bytes read from disk
// this function starts reading from the start
pub fn readFile(self: *Self, inode: *const Inode, buf: []u8) !usize {
    var remaining = buf;
    var bytes_read: usize = 0;
    const file_size = inode.size();

    const direct_ptrs = [12]u32{
        inode.direct_ptr0, inode.direct_ptr1,  inode.direct_ptr2,
        inode.direct_ptr3, inode.direct_ptr4,  inode.direct_ptr5,
        inode.direct_ptr6, inode.direct_ptr7,  inode.direct_ptr8,
        inode.direct_ptr9, inode.direct_ptr10, inode.direct_ptr11,
    };

    for (direct_ptrs) |ptr| {
        if (bytes_read >= file_size) break;
        if (ptr == 0) break; // sparse block

        const to_read = @min(self.block_size, remaining.len);
        try self.readBlock(ptr, remaining[0..to_read]);

        remaining = remaining[to_read..];
        bytes_read += to_read;
    }

    if (bytes_read < file_size and inode.singly_indirect_ptr != 0) {
        try self.readSinglyIndirect(inode.singly_indirect_ptr, &remaining, &bytes_read, file_size);
    }

    if (bytes_read < file_size and inode.doubly_indirect_ptr != 0) {
        try self.readDoublyIndirect(inode.doubly_indirect_ptr, &remaining, &bytes_read, file_size);
    }

    if (bytes_read < file_size and inode.triply_indirect_ptr != 0) {
        try self.readTriplyIndirect(inode.triply_indirect_ptr, &remaining, &bytes_read, file_size);
    }

    return bytes_read;
}

fn readSinglyIndirect(self: *Self, block_ptr: u32, remaining: *[]u8, bytes_read: *usize, file_size: u64) !void {
    const ptrs_per_block = self.block_size / @sizeOf(u32);

    const indirect_block = try self.allocator.alloc(u32, ptrs_per_block);
    defer self.allocator.free(indirect_block);

    try self.readBlock(block_ptr, std.mem.sliceAsBytes(indirect_block));

    for (indirect_block) |ptr| {
        if (bytes_read.* >= file_size) break;
        if (ptr == 0) break;

        const to_read: usize = @min(self.block_size, remaining.*.len);
        try self.readBlock(ptr, remaining.*[0..to_read]);

        remaining.* = remaining.*[to_read..];
        bytes_read.* += to_read;
    }
}

fn readDoublyIndirect(self: *Self, block_ptr: u32, remaining: *[]u8, bytes_read: *usize, file_size: u64) !void {
    const ptrs_per_block = self.block_size / @sizeOf(u32);

    const indirect_block = try self.allocator.alloc(u32, ptrs_per_block);
    defer self.allocator.free(indirect_block);

    try self.readBlock(block_ptr, std.mem.sliceAsBytes(indirect_block));

    for (indirect_block) |ptr| {
        if (bytes_read.* >= file_size) break;
        if (ptr == 0) break;

        try self.readSinglyIndirect(ptr, remaining, bytes_read, file_size);
    }
}

fn readTriplyIndirect(self: *Self, block_ptr: u32, remaining: *[]u8, bytes_read: *usize, file_size: u64) !void {
    const ptrs_per_block = self.block_size / @sizeOf(u32);

    const indirect_block = try self.allocator.alloc(u32, ptrs_per_block);
    defer self.allocator.free(indirect_block);

    try self.readBlock(block_ptr, std.mem.sliceAsBytes(indirect_block));

    for (indirect_block) |ptr| {
        if (bytes_read.* >= file_size) break;
        if (ptr == 0) break;

        try self.readDoublyIndirect(ptr, remaining, bytes_read, file_size);
    }
}

fn getBlockPtr(self: *Self, inode: *const Inode, index: u32) !u32 {
    const ptrs_per_block = self.block_size / @sizeOf(u32);

    // direct blocks 0-11
    if (index < 12) {
        const direct_ptrs = [12]u32{
            inode.direct_ptr0, inode.direct_ptr1,  inode.direct_ptr2,
            inode.direct_ptr3, inode.direct_ptr4,  inode.direct_ptr5,
            inode.direct_ptr6, inode.direct_ptr7,  inode.direct_ptr8,
            inode.direct_ptr9, inode.direct_ptr10, inode.direct_ptr11,
        };
        return direct_ptrs[index];
    }

    // singly indirect
    const si_base = 12;
    if (index < si_base + ptrs_per_block) {
        return self.readIndirectPtr(inode.singly_indirect_ptr, index - si_base);
    }

    // doubly indirect
    const di_base = si_base + ptrs_per_block;
    if (index < di_base + ptrs_per_block * ptrs_per_block) {
        const di_index = index - di_base;
        const si_block = try self.readIndirectPtr(inode.doubly_indirect_ptr, di_index / ptrs_per_block);
        return self.readIndirectPtr(si_block, di_index % ptrs_per_block);
    }

    // triply indirect
    const ti_base = di_base + ptrs_per_block * ptrs_per_block;
    const ti_index = index - ti_base;
    const di_block = try self.readIndirectPtr(inode.triply_indirect_ptr, ti_index / (ptrs_per_block * ptrs_per_block));
    const si_block = try self.readIndirectPtr(di_block, (ti_index / ptrs_per_block) % ptrs_per_block);
    return self.readIndirectPtr(si_block, ti_index % ptrs_per_block);
}

fn readIndirectPtr(self: *Self, block: u32, index: u32) !u32 {
    const offset = block * self.block_size + index * @sizeOf(u32);
    var ptr: u32 = undefined;
    try self.partition.readAll(offset, std.mem.asBytes(&ptr));
    return ptr;
}

fn findInDir(self: *Self, dir_inode: *const Inode, name: []const u8) !?u32 {
    const dir_size = dir_inode.size();
    const buf = try self.allocator.alloc(u8, dir_size);
    defer self.allocator.free(buf);

    const n = try self.readFile(dir_inode, buf);
    std.debug.assert(n == buf.len);

    var offset: usize = 0;
    while (offset < buf.len) {
        const entry: *const DirEntry = @ptrCast(@alignCast(&buf[offset]));
        if (entry.inode != 0) {
            const entry_name = buf[offset + @sizeOf(DirEntry) ..][0..entry.name_length];
            if (std.mem.eql(u8, entry_name, name)) return entry.inode;
        }
        if (entry.total_size == 0) break;
        offset += entry.total_size;
    }

    return null;
}

fn find(self: *Self, path: []const u8) !?InodeWNumber {
    var current_inode = self.root_inode.*;
    var inode_num: u32 = 2;
    var it = std.mem.splitScalar(u8, path, '/');

    while (it.next()) |component| {
        if (component.len == 0) continue;
        if (!current_inode.isDir()) {
            log.warn("Not a directory", .{});
            return null;
        }
        inode_num = try self.findInDir(&current_inode, component) orelse {
            log.warn("File not found", .{});
            return null;
        };
        current_inode = try self.getInodeNoRef(inode_num);
    }

    if (inode_num == ROOT_INODE) log.warn("Root inode found", .{});

    return InodeWNumber{
        .inode = current_inode,
        .number = inode_num,
    };
}

pub fn openFile(self: *Self, path: []const u8) !FileHandle {
    if (try self.find(path)) |inode| {
        if (inode.number != ROOT_INODE) self.cacheInode(inode.number, inode.inode);
        return FileHandle{
            .size = inode.inode.size(),
            .pos = 0,
            .ctx = inode.number,
            .flags = .{ .readable = true, .executable = true, .writable = true, .seekable = true },
            .opened = true,
        };
    }

    return error.FileNotFound;
}

pub fn closeFile(self: *Self, handle: *FileHandle) void {
    self.freeInode(@intCast(handle.ctx));
}

// ============= VFS interface =============
pub const VfsDirIterCtx = struct {
    data: []const u8, // full directory data read from disk
    offset: usize,
    allocator: mem.Allocator,
    fs: *Self,

    pub const vtable = FS.DirIterator.VTable{
        .next = &next,
        .reset = &reset,
        .deinit = &VfsDirIterCtx.deinit,
    };

    pub fn init(self: *Self, allocator: mem.Allocator, inode: *const Inode) !VfsDirIterCtx {
        // read directory data from disk...
        const dir_size = inode.size();
        const data = try allocator.alloc(u8, dir_size);
        const n = try self.readFile(inode, data);
        std.debug.assert(n == dir_size);

        return VfsDirIterCtx{
            .data = data,
            .offset = 0,
            .allocator = allocator,
            .fs = self,
        };
    }

    pub fn deinit(ctx: *anyopaque) void {
        const self: *VfsDirIterCtx = @ptrCast(@alignCast(ctx));
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    pub fn next(ctx: *anyopaque) anyerror!?FS.DirIterator.Entry {
        const self: *VfsDirIterCtx = @ptrCast(@alignCast(ctx));

        while (self.offset < self.data.len) {
            const entry: *const DirEntry = @ptrCast(@alignCast(&self.data[self.offset]));
            if (entry.total_size == 0) return error.CorruptFileSystem;
            self.offset += entry.total_size;

            if (entry.inode == 0) continue; // deleted entry, skip

            const name = self.data[self.offset - entry.total_size + @sizeOf(DirEntry) ..][0..entry.name_length];
            const inode = try self.fs.getInodeNoRef(entry.inode);
            return FS.DirIterator.Entry{
                .name = name,
                .info = .{ .size = inode.size(), .type = if (inode.isDir()) .directory else .file },
            };
        }
        return null;
    }

    pub fn reset(ctx: *anyopaque) void {
        const self: *VfsDirIterCtx = @ptrCast(@alignCast(ctx));
        self.offset = 0;
    }
};

pub fn mount(disk: *Disk) !FS.AnyFs {
    var ext2 = try init(disk);
    var anyfs = FS.AnyFs{ .vtable = .{
        .read_file = &vfsReadFile,
        .open_file = &vfsOpenFile,
        .close_file = &vfsCloseFile,
        .stat = &vfsStat,
        .iter_dir = &vfsIterDir,
    }, .fs_type = .ext2 };
    const bytes = std.mem.asBytes(&ext2);
    @memcpy(anyfs.state[0..bytes.len], bytes);
    return anyfs;
}

comptime {
    std.debug.assert(@sizeOf(Self) <= FS.AnyFs.state_size);
}

fn vfsReadFile(fs: *FS.AnyFs, handle: *FS.Handle, buf: []u8) !usize {
    const self: *Self = @ptrCast(@alignCast(&fs.state));
    if (handle.pos >= handle.size) return 0; // EOF

    const inode = try self.getInodeNoRef(@intCast(handle.ctx));
    const remaining = handle.size - handle.pos;
    const to_read = @min(remaining, @as(u32, @intCast(buf.len)));

    var block_buf = try self.allocator.alloc(u8, self.block_size);
    defer self.allocator.free(block_buf);

    var done: u32 = 0;
    while (done < to_read) {
        const abs_pos = handle.pos + done;
        const block_index = abs_pos / self.block_size;
        const byte_off = abs_pos % self.block_size;

        const block_ptr = try self.getBlockPtr(&inode, block_index);
        if (block_ptr == 0) break; // sparse block

        try self.readBlock(block_ptr, block_buf);

        const chunk = @min(self.block_size - byte_off, to_read - done);
        @memcpy(buf[done..][0..chunk], block_buf[byte_off..][0..chunk]);
        done += chunk;
    }

    handle.pos += done;
    return done;
}

fn vfsOpenFile(fs: *FS.AnyFs, path: []const u8) !FS.Handle {
    const self: *Self = @ptrCast(@alignCast(&fs.state));
    return self.openFile(path);
}

fn vfsCloseFile(fs: *FS.AnyFs, handle: *FS.Handle) void {
    const self: *Self = @ptrCast(@alignCast(&fs.state));
    self.closeFile(handle);
}

fn vfsStat(fs: *FS.AnyFs, path: []const u8) !FS.FileInfo {
    const self: *Self = @ptrCast(@alignCast(&fs.state));

    const inode = try self.find(path) orelse return error.FileNotFound;

    return .{
        .size = inode.inode.size(),
        .type = if (inode.inode.isDir()) .directory else .file,
    };
}

fn vfsIterDir(fs: *FS.AnyFs, path: []const u8) !FS.DirIterator {
    const self: *Self = @ptrCast(@alignCast(&fs.state));
    const inode = try self.find(path) orelse return error.FileNotFound;

    const iter_ctx = self.allocator.create(VfsDirIterCtx) catch return error.OutOfMemory;
    iter_ctx.* = try .init(self, self.allocator, &inode.inode);
    const iter = FS.DirIterator{
        .fs = fs,
        .vtable = &VfsDirIterCtx.vtable,
        .ctx = iter_ctx,
    };
    return iter;
}
