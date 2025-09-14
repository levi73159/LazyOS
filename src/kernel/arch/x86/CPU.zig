//! generate a struct that represents a CPU
const std = @import("std");

const Self = @This();

const Error = error{
    NotCompatible,
};

const log = std.log.scoped(.CPU);

const CpuidResults = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

const CpuidInfoHolder = struct {
    basic: [32]CpuidResults,
    extended: [32]CpuidResults,
};

const CpuFlags = struct {
    sse: bool,
    sse2: bool,
    sse3: bool,
    sse4_1: bool,
    sse4_2: bool,
    avx: bool,
    avx2: bool,
};

const CpuVendor = enum {
    intel,
    amd,
    unknown,
};

pub const unknown = Self{
    .vendor_str = .{0} ** 12,
    .vendor = .unknown,
    .brand_str = .{0} ** 48,
    .flags = .{
        .sse = false,
        .sse2 = false,
        .sse3 = false,
        .sse4_1 = false,
        .sse4_2 = false,
        .avx = false,
        .avx2 = false,
    },
};

vendor_str: [12:0]u8,
vendor: CpuVendor,
brand_str: [48:0]u8,
// TODO: add info about TLB/caches and so on and features

fn checkCompatibility() bool {
    const ID_BIT: u32 = 1 << 21;

    // get current EFLAGS
    const eflags = asm volatile (
        \\ pushfd
        \\ pop %[out]
        : [out] "=r" (-> u32),
    );

    // Invert the ID bit
    const modified = eflags ^ ID_BIT;

    // write modified EFLAGS
    asm volatile (
        \\ push %[in]
        \\ popfd
        :
        : [in] "r" (modified),
    );

    const updated = asm volatile (
        \\ pushfd
        \\ pop %[out]
        : [out] "=r" (-> u32),
    );

    // Restore the original flags (to avoid messing up system state)
    asm volatile (
        \\ push %[in]
        \\ popfd
        :
        : [in] "r" (eflags),
    );

    // If the ID bit changed, CPUID is supported
    return (updated ^ eflags) & ID_BIT != 0;
}

fn cpuid(leaf: u32, subleaf: u32) CpuidResults {
    var eax: u32 = leaf;
    var ebx: u32 = 0;
    var ecx: u32 = subleaf;
    var edx: u32 = 0;
    asm volatile (
        \\ cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

pub fn init() Error!Self {
    if (!checkCompatibility()) {
        return error.NotCompatible;
    }

    var self = std.mem.zeroes(Self);
    var rawinfo = std.mem.zeroes(CpuidInfoHolder);

    fillRawInfo(&rawinfo);
    fillCpuInfo(&rawinfo, &self);

    return self;
}

fn fillRawInfo(info: *CpuidInfoHolder) void {
    for (0..info.basic.len) |i| {
        info.basic[i] = cpuid(i, 0);
        info.extended[i] = cpuid(0x8000_0000 + i, 0);
    }
}

fn fillCpuInfo(info: *const CpuidInfoHolder, self: *Self) void {
    const vendor_info = info.basic[0];
    @memcpy(self.vendor_str[0..][0..4], @as([*]const u8, @ptrCast(&vendor_info.ebx)));
    @memcpy(self.vendor_str[4..][0..4], @as([*]const u8, @ptrCast(&vendor_info.edx)));
    @memcpy(self.vendor_str[8..][0..4], @as([*]const u8, @ptrCast(&vendor_info.ecx)));
    self.vendor_str[12] = 0;

    const VendorMatchTable = struct { key: []const u8, vendor: CpuVendor };
    const vendor_matches = [_]VendorMatchTable{
        .{ .key = "GenuineIntel", .vendor = .intel },
        .{ .key = "AuthenticAMD", .vendor = .amd },
    };

    inline for (vendor_matches) |match| {
        if (std.mem.eql(u8, self.vendor_str[0..], match.key)) {
            self.vendor = match.vendor;
            break;
        }
    } else {
        log.warn("Unknown CPU vendor: {s}", .{self.vendor_str[0..]});
        self.vendor = .unknown;
    }

    log.info("vendor: {s} enum({s})", .{ self.vendor_str[0..], @tagName(self.vendor) });

    // brand string available in leaves 0x8000_0002 to 0x8000_0004
    if (info.extended[0].eax >= 0x8000_0004) {
        for (2..5) |index| {
            const leaf = info.extended[index];
            log.debug("inedx: {}", .{index});

            const offset = (index - 2) * @sizeOf(@TypeOf(leaf));

            @memcpy(self.brand_str[offset + 0 ..][0..4], @as([*]const u8, @ptrCast(&leaf.eax)));
            @memcpy(self.brand_str[offset + 4 ..][0..4], @as([*]const u8, @ptrCast(&leaf.ebx)));
            @memcpy(self.brand_str[offset + 8 ..][0..4], @as([*]const u8, @ptrCast(&leaf.ecx)));
            @memcpy(self.brand_str[offset + 12 ..][0..4], @as([*]const u8, @ptrCast(&leaf.edx)));
        }

        self.brand_str[48] = 0;
        log.info("brand: {s}", .{self.brand_str[0..]});
    } else {
        log.warn("brand: unknown", .{});
    }
}
