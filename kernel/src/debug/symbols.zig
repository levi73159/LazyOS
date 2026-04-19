//! src/kernel/debug/symbols.zig
//!
//! ELF symbol table lookup + RBP frame-pointer stack walking.
//! Call `init()` early in boot once you have the raw ELF bytes,
//! then `printStackTrace()` from the panic handler.

const std = @import("std");
const root = @import("root");
const console = root.console;
const elf = std.elf;

const Ehdr = elf.Elf64_Ehdr;
const Shdr = elf.Elf64_Shdr;
const Sym = elf.Elf64_Sym;
const SHT_SYMTAB = elf.SHT_SYMTAB;
const ELF_MAGIC = elf.MAGIC;

// ─── Module state ─────────────────────────────────────────────────────────────

var symtab: []const Sym = &.{};
var strtab: []const u8 = &.{};
var initialized = false;

// ─── Init ─────────────────────────────────────────────────────────────────────

/// Parse the kernel's own ELF file to find .symtab and .strtab.
/// `elf` must be the complete ELF bytes (from Limine's executable file response).
/// Safe to call before the heap is ready — no allocation happens.
pub fn init(_elf: []const u8) void {
    parseElf(_elf) catch |err| {
        console.dbgPrint("symbols.init failed: {s}\n", .{@errorName(err)});
        return;
    };
    initialized = true;
    console.dbgPrint("symbols: loaded {d} symbols\n", .{symtab.len});
}

fn parseElf(_elf: []const u8) !void {
    if (_elf.len < @sizeOf(Ehdr)) return error.TooSmall;

    const ehdr: *const Ehdr = @ptrCast(@alignCast(_elf.ptr));
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], ELF_MAGIC)) return error.NotElf;

    const shoff = ehdr.e_shoff;
    const shnum = ehdr.e_shnum;
    const shentsz = ehdr.e_shentsize;

    if (shoff == 0 or shnum == 0 or shentsz < @sizeOf(Shdr))
        return error.NoSections;
    if (shoff + @as(u64, shnum) * shentsz > _elf.len)
        return error.Truncated;

    for (0..shnum) |i| {
        const off: usize = @intCast(shoff + i * shentsz);
        const shdr: *const Shdr = @ptrCast(@alignCast(_elf[off..].ptr));
        if (shdr.sh_type != SHT_SYMTAB) continue;

        // Validate symtab range
        const sym_end: usize = @intCast(shdr.sh_offset + shdr.sh_size);
        if (sym_end > _elf.len) return error.Truncated;
        const n = shdr.sh_size / @sizeOf(Sym);
        symtab = @as([*]const Sym, @ptrCast(@alignCast(_elf[shdr.sh_offset..].ptr)))[0..n];

        // Associated strtab via sh_link
        const str_idx = shdr.sh_link;
        if (str_idx >= shnum) return error.BadLink;
        const str_off: usize = @intCast(shoff + @as(u64, str_idx) * shentsz);
        const str_shdr: *const Shdr = @ptrCast(@alignCast(_elf[str_off..].ptr));
        const str_end: usize = @intCast(str_shdr.sh_offset + str_shdr.sh_size);
        if (str_end > _elf.len) return error.Truncated;
        strtab = _elf[str_shdr.sh_offset..str_end];

        return; // found it, done
    }

    return error.NoSymtab;
}

// ─── Symbol lookup ────────────────────────────────────────────────────────────

/// Return the name of the function that contains `addr`, if known.
/// Picks the symbol with the smallest non-negative offset from `addr`.
pub fn resolve(addr: u64) ?[]const u8 {
    if (!initialized or symtab.len == 0) return null;

    var best: ?*const Sym = null;
    var best_diff: u64 = std.math.maxInt(u64);

    for (symtab) |*sym| {
        // Skip undefined / absolute symbols
        if (sym.st_value == 0 or sym.st_shndx == 0) continue;
        if (addr < sym.st_value) continue;

        const diff = addr - sym.st_value;
        if (diff < best_diff) {
            best_diff = diff;
            best = sym;
        }
    }

    const sym = best orelse return null;
    if (sym.st_name >= strtab.len) return null;
    const name = std.mem.sliceTo(strtab[sym.st_name..], 0);
    return if (name.len > 0) name else null;
}

// ─── Stack walking ────────────────────────────────────────────────────────────

/// Walk the RBP frame-pointer chain starting from `rbp` and print each frame.
/// Requires that the kernel was compiled with frame pointers (the default for
/// debug/safe builds; set `omit_frame_pointer = false` in build.zig for release).
pub fn printStackTrace(rbp: usize, writer: *std.Io.Writer) !void {
    try writer.writeAll("\n--- stack trace ---\n");

    var frame = rbp;
    var depth: usize = 0;

    while (depth < 64) : (depth += 1) {
        // Alignment + canonical-address sanity checks (kernel upper half)
        if (frame == 0) break;
        if (frame & 0x7 != 0) break;
        if (frame < 0xffff_0000_0000_0000) break;

        // [rbp+0]  = previous rbp
        // [rbp+8]  = return address (one past the call instruction)
        const ret_addr = @as(*const usize, @ptrFromInt(frame + 8)).*;
        if (ret_addr == 0 or ret_addr < 0xffff_0000_0000_0000) break;

        // Subtract 1 so we point at the call instruction, not the next one.
        // This matters for symbol lookup and addr2line.
        const call_site = ret_addr - 1;

        if (resolve(call_site)) |name| {
            try writer.print("  #{d:2}  0x{x:0>16}  {s} (+0x{x})\n", .{
                depth,
                call_site,
                name,
                call_site - (symtab[findSymIdx(call_site) orelse 0].st_value),
            });
        } else {
            try writer.print("  #{d:2}  0x{x:0>16}  ???\n", .{ depth, call_site });
        }

        frame = @as(*const usize, @ptrFromInt(frame)).*;
    }

    try writer.writeAll("--- end of trace ---\n");
    try writer.writeAll("Tip: addr2line -e kernel.elf -fp 0x<ADDR> for source lines\n\n");
}

// helper: find index of the best-matching symbol (for +offset display)
fn findSymIdx(addr: u64) ?usize {
    var best_idx: ?usize = null;
    var best_diff: u64 = std.math.maxInt(u64);
    for (symtab, 0..) |*sym, i| {
        if (sym.st_value == 0 or sym.st_shndx == 0) continue;
        if (addr < sym.st_value) continue;
        const diff = addr - sym.st_value;
        if (diff < best_diff) {
            best_diff = diff;
            best_idx = i;
        }
    }
    return best_idx;
}
