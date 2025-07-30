//! Directory entry for the fat 12 filesystem
const std = @import("std");

const Self = @This();

name: [11]u8,
attributes: u8,
__reserved: u8, // reserve for use by windows nt
creation_time_tenths: u8,
creation_time: u16,
creation_date: u16,
last_access_date: u16,
cluster_high: u16,
last_modified_time: u16,
last_modified_date: u16,
cluster_low: u16,
size: u32,

pub fn fromReader(reader: anytype) !Self {
    var self: Self = undefined;
    self.name = try reader.readBytesNoEof(11);
    self.attributes = try reader.readByte();
    self.__reserved = try reader.readByte();
    self.creation_time_tenths = try reader.readByte();
    self.creation_time = try reader.readInt(u16, .little);
    self.creation_date = try reader.readInt(u16, .little);
    self.last_access_date = try reader.readInt(u16, .little);
    self.cluster_high = try reader.readInt(u16, .little);
    self.last_modified_time = try reader.readInt(u16, .little);
    self.last_modified_date = try reader.readInt(u16, .little);
    self.cluster_low = try reader.readInt(u16, .little);
    self.size = try reader.readInt(u32, .little);
    return self;
}

pub fn getSizeOf() comptime_int {
    var size: comptime_int = 0;

    const info = @typeInfo(Self);

    inline for (info.@"struct".fields) |field| {
        const field_info = @typeInfo(field.type);
        if (field_info == .array) {
            size += field_info.array.len;
        } else {
            size += field_info.int.bits / 8;
        }
    }
    return size;
}
