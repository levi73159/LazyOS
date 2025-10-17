const std = @import("std");
const uefi = std.os.uefi;
const elf = std.elf;
const mem = @import("mem.zig");
const Address = @import("AddressSpace.zig").Address;
const constants = @import("constants.zig");

const log = std.log.scoped(.loader);

const SegmentMapping = struct {
    vaddr: Address = .{ .phys = 0 },
    paddr: Address = .{ .virt = .zero },
    len: u64 = 0,
};

const AdressBindings = struct {
    framebuffer: ?Address = null,
    bootinfo: ?Address = null,
    env: ?Address = null,
};

const KernelInfo = struct {
    entrypoint: u64,
    segment_mapping: SegmentMapping = .{},
    bindings: AdressBindings = .{},
};

const LoadError = error{
    InvalidFormat,
    InvalidElfClass,
    InvalidElfEndian,
    InvalidArch,
    KernelToLarge,
    OutOfMemory,

    Unexpected,
};

inline fn mb(size_in_bytes: comptime_int) comptime_int {
    return size_in_bytes * 1024 * 1024;
}

pub fn loadExe(data: []const u8) LoadError!KernelInfo {
    const kernel_sig = data[0..4];
    if (std.mem.eql(u8, kernel_sig, elf.MAGIC)) {
        log.info("Kernel detected as elf", .{});
        return loadElf(data);
    }
    log.err("Invalid kernel signature (must be elf!)", .{});
    return error.InvalidFormat;
}

fn loadElf(data: []const u8) LoadError!KernelInfo {
    const boot_services = uefi.system_table.boot_services.?;
    const ehdr: *align(1) const elf.Elf64_Ehdr = std.mem.bytesAsValue(elf.Elf64_Ehdr, data[0..@sizeOf(elf.Elf64_Ehdr)]);

    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) {
        std.log.err("Unsupported elf class: {} (expected ELFCLASS64)", .{ehdr.e_ident[elf.EI_CLASS]});
        return error.InvalidElfClass;
    }

    if (ehdr.e_ident[elf.EI_DATA] != elf.ELFDATA2LSB) {
        std.log.err("Unsupported elf endian: {} (expected LSB)", .{ehdr.e_ident[elf.ELFDATA2LSB]});
        return error.InvalidElfEndian;
    }

    if (ehdr.e_machine != .X86_64) {
        std.log.err("Unsupported arch: {s} (expected X86_64)", .{@tagName(ehdr.e_machine)});
        return error.InvalidArch;
    }

    if (ehdr.e_type != .EXEC) {
        std.log.err("Unsupported type: {s} (expected executable)", .{@tagName(ehdr.e_type)});
        return error.InvalidArch;
    }

    var kernel_info = KernelInfo{ .entrypoint = ehdr.e_entry, .segment_mapping = undefined };

    const phdrs: []align(1) const elf.Elf64_Phdr = std.mem.bytesAsSlice(elf.Elf64_Phdr, data[ehdr.e_phoff..][0 .. ehdr.e_phnum * ehdr.e_phentsize]);
    for (phdrs) |phdr| {
        if (phdr.p_type == elf.PT_LOAD) {
            continue;
        }

        const file_size = phdr.p_filesz;
        const mem_size = phdr.p_memsz;

        if (mem_size > mb(64)) {
            log.err("Kernel to big, consider splitting it into modules, mem_size > 64MB", .{});
            return error.KernelToLarge;
        }

        const pages_to_alloc = @divExact(std.mem.alignForward(u64, mem_size, 4096), 4096);
        const load_buffer_pages = boot_services.allocatePages(.any, .loader_data, pages_to_alloc) catch |err| switch (err) {
            error.OutOfResources => {
                log.err("Allocation failed, failed to load kernel buffer: reason out of memory", .{});
                log.debug("Needed pages: {d} ({d} bytes) memsize: {d}", .{ pages_to_alloc, pages_to_alloc * 4096, mem_size });
                return error.OutOfMemory;
            },
            error.NotFound, error.Unexpected => {
                log.err("Allocation failed: Not Found", .{});
                return error.Unexpected;
            },
            error.InvalidParameter => {
                log.err("allocate pages failed: Invalid Parameter", .{});
                @panic("Invalid Parameter");
            },
        };
        const load_buffer = mem.pagesToBytes(load_buffer_pages);
        @memcpy(load_buffer[0..file_size], data[phdr.p_offset..][0..file_size]);

        const bss_size = mem_size - file_size;
        if (bss_size > 0) {
            @memset(load_buffer[file_size..mem_size], 0);
        }

        kernel_info.segment_mapping.paddr = .{ .phys = phdr.p_paddr };
        kernel_info.segment_mapping.vaddr = .{ .virt = .from(phdr.p_vaddr) };
        kernel_info.segment_mapping.len = mem_size;

        log.debug("Finish loading program segment: paddr: {x}, vaddr: {x}, len: {x}", .{
            kernel_info.segment_mapping.paddr.raw(),
            kernel_info.segment_mapping.vaddr.raw(),
            kernel_info.segment_mapping.len,
        });
        break;
    }

    if (ehdr.e_shstrndx < ehdr.e_shnum) {
        const shdrs: []align(1) const elf.Elf64_Shdr = std.mem.bytesAsSlice(elf.Elf64_Shdr, data[ehdr.e_shoff..][0 .. ehdr.e_shnum * ehdr.e_shentsize]);

        const shstrtab_shdr = shdrs[ehdr.e_shstrndx];
        log.debug("shstrtab found at offset: {d}", .{shstrtab_shdr.sh_offset});

        const shstrtab = data[shstrtab_shdr.sh_offset..][0..shstrtab_shdr.sh_size];

        var symtab_shdr_opt: ?elf.Elf64_Shdr = null;
        var strtab_shdr_opt: ?elf.Elf64_Shdr = null;
        for (shdrs) |shdr| {
            const section_name = shstrtab[shdr.sh_name..]; // doesn't have end, because we don't care about it
            if (std.mem.eql(u8, section_name[0..7], ".symtab")) {
                log.debug("Found .symtab section", .{});
                symtab_shdr_opt = shdr;
            } else if (std.mem.eql(u8, section_name[0..7], ".strtab")) {
                log.debug("Found .strtab section", .{});
                strtab_shdr_opt = shdr;
            }
        }
        if (symtab_shdr_opt) |symtab_shdr| if (strtab_shdr_opt) |strtab_shdr| {
            const strtab = data[strtab_shdr.sh_offset..][0..strtab_shdr.sh_size];
            const symtab: []align(1) const elf.Elf64_Sym = std.mem.bytesAsSlice(elf.Elf64_Sym, data[symtab_shdr.sh_offset..][0..symtab_shdr.sh_size]);

            for (symtab) |symbol| {
                const symbol_name = strtab[symbol.st_name..];
                if (std.mem.eql(u8, symbol_name[0..2], "fb")) {
                    log.debug("Found framebuffer symbol with value: 0x{x}", .{symbol.st_value});
                    kernel_info.bindings.framebuffer = .{ .virt = .from(symbol.st_value) };
                } else if (std.mem.eql(u8, symbol_name[0..8], "bootinfo")) {
                    log.debug("Found bootinfo with value: 0x{x}", .{symbol.st_value});
                    kernel_info.bindings.bootinfo = .{ .virt = .from(symbol.st_value) };
                } else if (std.mem.eql(u8, symbol_name[0..3], "env")) {
                    log.debug("Found env with value: 0x{x}", .{symbol.st_value});
                    kernel_info.bindings.env = .{ .virt = .from(symbol.st_value) };
                }
            }
        };
    }

    return kernel_info;
}
