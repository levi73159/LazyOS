//! src/kernel/debug/dwarf_lines.zig
//!
//! Minimal DWARF line-number program interpreter.
//! Supports DWARF versions 2–5, little-endian, 64-bit target.
//! Zero heap allocations — streams through .debug_line on every lookup.
//!
//! Call init() once with the raw section bytes from the ELF.
//! Call findLine(addr) from the panic / stack-trace printer.

const std = @import("std");

pub const SourceLocation = struct {
    directory: []const u8, // may be empty if no directory info
    filename: []const u8,
    line: u32,
};

// ─── Section data (populated by init) ────────────────────────────────────────

var s_debug_line: []const u8 = &.{};
var s_debug_str: []const u8 = &.{};
var s_debug_line_str: []const u8 = &.{}; // DWARF 5 only

pub fn init(
    debug_line: []const u8,
    debug_str: []const u8,
    debug_line_str: []const u8,
) void {
    s_debug_line = debug_line;
    s_debug_str = debug_str;
    s_debug_line_str = debug_line_str;
}

/// Map an instruction address to its source location.
/// Returns null if data is unavailable or the address isn't found.
pub fn findLine(addr: u64) ?SourceLocation {
    if (s_debug_line.len == 0) return null;
    return searchAll(addr) catch null;
}

// ─── Primitive readers ────────────────────────────────────────────────────────

const E = error{ OutOfBounds, Overflow, UnsupportedDwarf };

fn r8(d: []const u8, o: *usize) E!u8 {
    if (o.* >= d.len) return error.OutOfBounds;
    defer o.* += 1;
    return d[o.*];
}
fn r16(d: []const u8, o: *usize) E!u16 {
    if (o.* + 2 > d.len) return error.OutOfBounds;
    defer o.* += 2;
    return std.mem.readInt(u16, d[o.*..][0..2], .little);
}
fn r32(d: []const u8, o: *usize) E!u32 {
    if (o.* + 4 > d.len) return error.OutOfBounds;
    defer o.* += 4;
    return std.mem.readInt(u32, d[o.*..][0..4], .little);
}
fn r64(d: []const u8, o: *usize) E!u64 {
    if (o.* + 8 > d.len) return error.OutOfBounds;
    defer o.* += 8;
    return std.mem.readInt(u64, d[o.*..][0..8], .little);
}
fn uleb(d: []const u8, o: *usize) E!u64 {
    var v: u64 = 0;
    var s: u6 = 0;
    while (true) {
        const b = try r8(d, o);
        v |= @as(u64, b & 0x7f) << s;
        if (b & 0x80 == 0) return v;
        s += 7;
        if (s >= 64) return error.Overflow;
    }
}
fn sleb(d: []const u8, o: *usize) E!i64 {
    var v: i64 = 0;
    var s: u6 = 0;
    var b: u8 = 0;
    while (true) {
        b = try r8(d, o);
        v |= @as(i64, b & 0x7f) << s;
        s += 7;
        if (b & 0x80 == 0) break;
        if (s >= 64) return error.Overflow;
    }
    if (s < 64 and b & 0x40 != 0) v |= ~@as(i64, 0) << s;
    return v;
}
fn cstr(d: []const u8, o: *usize) E![]const u8 {
    const start = o.*;
    while (o.* < d.len and d[o.*] != 0) o.* += 1;
    if (o.* >= d.len) return error.OutOfBounds;
    defer o.* += 1; // skip null terminator
    return d[start..o.*];
}

// ─── DWARF form values ────────────────────────────────────────────────────────

const DW_FORM_string: u64 = 0x08; // inline null-terminated string
const DW_FORM_strp: u64 = 0x0e; // offset into .debug_str
const DW_FORM_line_strp: u64 = 0x1f; // offset into .debug_line_str (DWARF 5)
const DW_FORM_udata: u64 = 0x0f; // unsigned LEB128
const DW_FORM_data1: u64 = 0x0a;
const DW_FORM_data2: u64 = 0x05;
const DW_FORM_data4: u64 = 0x06;
const DW_FORM_data8: u64 = 0x07;
const DW_FORM_data16: u64 = 0x1e; // 16 raw bytes (MD5)
const DW_FORM_block: u64 = 0x09; // uleb128 length + data

const FormVal = union(enum) { str: []const u8, uint: u64, none };

fn readForm(form: u64, d: []const u8, o: *usize, dw64: bool) E!FormVal {
    switch (form) {
        DW_FORM_string => return .{ .str = try cstr(d, o) },
        DW_FORM_strp => {
            const idx: u64 = if (dw64) try r64(d, o) else try r32(d, o);
            if (idx >= s_debug_str.len) return .none;
            var oo: usize = @intCast(idx);
            return .{ .str = try cstr(s_debug_str, &oo) };
        },
        DW_FORM_line_strp => {
            const idx: u64 = if (dw64) try r64(d, o) else try r32(d, o);
            if (idx >= s_debug_line_str.len) return .none;
            var oo: usize = @intCast(idx);
            return .{ .str = try cstr(s_debug_line_str, &oo) };
        },
        DW_FORM_udata => return .{ .uint = try uleb(d, o) },
        DW_FORM_data1 => return .{ .uint = try r8(d, o) },
        DW_FORM_data2 => return .{ .uint = try r16(d, o) },
        DW_FORM_data4 => return .{ .uint = try r32(d, o) },
        DW_FORM_data8 => return .{ .uint = try r64(d, o) },
        DW_FORM_data16 => {
            if (o.* + 16 > d.len) return error.OutOfBounds;
            o.* += 16;
            return .none;
        },
        DW_FORM_block => {
            const len = try uleb(d, o);
            if (o.* + len > d.len) return error.OutOfBounds;
            o.* += @intCast(len);
            return .none;
        },
        else => return error.UnsupportedDwarf,
    }
}

// ─── Compilation unit header ──────────────────────────────────────────────────

const MAX_DIRS = 64;
const MAX_FILES = 128;

const FileEntry = struct { name: []const u8, dir: u32 };

const CuHeader = struct {
    version: u8,
    dw64: bool,
    min_insn_len: u8,
    max_ops: u8,
    def_is_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    dirs: [MAX_DIRS][]const u8,
    ndirs: usize,
    files: [MAX_FILES]FileEntry,
    nfiles: usize,
    prog_start: usize,
    prog_end: usize,
};

/// Parse one CU header from s_debug_line at offset `o`, advance `o` to next CU.
fn parseCu(o: *usize) E!CuHeader {
    const d = s_debug_line;
    var h: CuHeader = undefined;
    h.ndirs = 0;
    h.nfiles = 0;

    // Initial length — determines 32-bit vs 64-bit DWARF offset form
    const first4 = try r32(d, o);
    h.dw64 = (first4 == 0xffff_ffff);
    const unit_len: u64 = if (h.dw64) try r64(d, o) else first4;
    const unit_end: usize = o.* + @as(usize, unit_len);

    const ver = try r16(d, o);
    if (ver < 2 or ver > 5) return error.UnsupportedDwarf;
    h.version = @intCast(ver);

    // DWARF 5 adds two extra bytes before header_length
    if (ver >= 5) {
        _ = try r8(d, o); // address_size
        _ = try r8(d, o); // segment_selector_size
    }

    // header_length: we skip it (already know the layout)
    if (h.dw64) _ = try r64(d, o) else _ = try r32(d, o);

    h.min_insn_len = try r8(d, o);
    h.max_ops = if (ver >= 4) try r8(d, o) else 1;
    h.def_is_stmt = (try r8(d, o)) != 0;
    h.line_base = @bitCast(try r8(d, o));
    h.line_range = try r8(d, o);
    h.opcode_base = try r8(d, o);
    for (1..h.opcode_base) |_| _ = try r8(d, o); // standard opcode lengths table

    if (ver <= 4) {
        try parseDirs4(&h, o);
        try parseFiles4(&h, o);
    } else {
        try parseDirs5(&h, o);
        try parseFiles5(&h, o);
    }

    h.prog_start = o.*;
    h.prog_end = unit_end;
    o.* = unit_end;

    std.log.debug("CU: files={d}, dirs={d}", .{ h.nfiles, h.ndirs });
    for (0..h.nfiles) |i| {
        std.log.debug("  file[{d}] = {s}", .{ i, h.files[i].name });
    }
    return h;
}

// DWARF 2–4: null-terminated list of directory strings, then null entry
fn parseDirs4(h: *CuHeader, o: *usize) E!void {
    const d = s_debug_line;
    while (o.* < d.len and d[o.*] != 0) {
        const s = try cstr(d, o);
        if (h.ndirs < MAX_DIRS) {
            h.dirs[h.ndirs] = s;
            h.ndirs += 1;
        }
    }
    o.* += 1; // skip null terminator
}

// DWARF 2–4: {name, dir_idx uleb, mtime uleb, size uleb} repeated, then null entry
fn parseFiles4(h: *CuHeader, o: *usize) E!void {
    const d = s_debug_line;
    while (o.* < d.len and d[o.*] != 0) {
        const name = try cstr(d, o);
        const di: u32 = @intCast(try uleb(d, o));
        _ = try uleb(d, o); // mtime
        _ = try uleb(d, o); // size
        if (h.nfiles < MAX_FILES) {
            h.files[h.nfiles] = .{ .name = name, .dir = di };
            h.nfiles += 1;
        }
    }
    o.* += 1;
}

const DW_LNCT_PATH: u64 = 1;
const DW_LNCT_DIRECTORY_INDEX: u64 = 2;

// DWARF 5: format-descriptor driven directory table
fn parseDirs5(h: *CuHeader, o: *usize) E!void {
    const d = s_debug_line;
    const nfmt = try r8(d, o);
    var fmts: [8]struct { ct: u64, form: u64 } = undefined;
    const nf = @min(nfmt, 8);
    for (fmts[0..nf]) |*f| {
        f.ct = try uleb(d, o);
        f.form = try uleb(d, o);
    }
    for (nf..nfmt) |_| {
        _ = try uleb(d, o);
        _ = try uleb(d, o);
    } // skip extras

    const count = try uleb(d, o);
    for (0..count) |_| {
        var path: []const u8 = "";
        for (fmts[0..nf]) |f| {
            const v = try readForm(f.form, d, o, h.dw64);
            if (f.ct == DW_LNCT_PATH) path = switch (v) {
                .str => |s| s,
                else => "",
            };
        }
        if (h.ndirs < MAX_DIRS) {
            h.dirs[h.ndirs] = path;
            h.ndirs += 1;
        }
    }
}

// DWARF 5: format-descriptor driven file table
fn parseFiles5(h: *CuHeader, o: *usize) E!void {
    const d = s_debug_line;
    const nfmt = try r8(d, o);
    var fmts: [8]struct { ct: u64, form: u64 } = undefined;
    const nf = @min(nfmt, 8);
    for (fmts[0..nf]) |*f| {
        f.ct = try uleb(d, o);
        f.form = try uleb(d, o);
    }
    for (nf..nfmt) |_| {
        _ = try uleb(d, o);
        _ = try uleb(d, o);
    }

    const count = try uleb(d, o);
    for (0..count) |_| {
        var name: []const u8 = "";
        var di: u32 = 0;
        for (fmts[0..nf]) |f| {
            const v = try readForm(f.form, d, o, h.dw64);
            switch (f.ct) {
                DW_LNCT_PATH => name = switch (v) {
                    .str => |s| s,
                    else => "",
                },
                DW_LNCT_DIRECTORY_INDEX => di = @intCast(switch (v) {
                    .uint => |u| u,
                    else => 0,
                }),
                else => {},
            }
        }
        if (h.nfiles < MAX_FILES) {
            h.files[h.nfiles] = .{ .name = name, .dir = di };
            h.nfiles += 1;
        }
    }
}

// ─── Line number state machine ────────────────────────────────────────────────

const DW_LNS_copy: u8 = 1;
const DW_LNS_advance_pc: u8 = 2;
const DW_LNS_advance_line: u8 = 3;
const DW_LNS_set_file: u8 = 4;
const DW_LNS_set_column: u8 = 5;
const DW_LNS_negate_stmt: u8 = 6;
const DW_LNS_set_basic_block: u8 = 7;
const DW_LNS_const_add_pc: u8 = 8;
const DW_LNS_fixed_advance_pc: u8 = 9;
const DW_LNS_set_prologue_end: u8 = 10;
const DW_LNS_set_epilogue_begin: u8 = 11;
const DW_LNS_set_isa: u8 = 12;

const DW_LNE_end_sequence: u8 = 1;
const DW_LNE_set_address: u8 = 2;
const DW_LNE_define_file: u8 = 3; // DWARF <=4 only
const DW_LNE_set_discriminator: u8 = 4;

const SM = struct {
    addr: u64 = 0,
    file: u32 = 1, // 1-based in DWARF 2–4, 0-based in DWARF 5
    line: u32 = 1,
    column: u32 = 0,
    is_stmt: bool = true,
    basic_block: bool = false,
    end_sequence: bool = false,
};

/// Run the line-number program for one CU and return the best source location
/// for `target`. "Best" = highest address that is still <= target.
fn runProgram(h: *const CuHeader, target: u64) ?SourceLocation {
    const prog = s_debug_line[h.prog_start..h.prog_end];
    var o: usize = 0;

    var sm = SM{ .is_stmt = h.def_is_stmt };
    if (h.version >= 5) sm.file = 0; // DWARF 5 is 0-indexed

    // Track the row that best covers `target`
    var best_addr: u64 = 0;
    var best_file: u32 = sm.file;
    var best_line: u32 = 1;
    var found = false;

    var prev_addr: u64 = 0;
    var prev_file: u32 = sm.file;
    var prev_line: u32 = sm.line;
    var have_prev = false;

    // Emit a row: update best match if this row covers target
    const emitRow = struct {
        fn f(s: *const SM, ba: *u64, bf: *u32, bl: *u32, fd: *bool, tgt: u64, pa: *u64, pf: *u32, pl: *u32, hp: *bool) void {
            if (hp.*) {
                if (pa.* <= tgt and tgt < s.addr) {
                    ba.* = pa.*;
                    bf.* = pf.*;
                    bl.* = pl.*;
                    fd.* = true;
                }
            }

            pa.* = s.addr;
            pf.* = s.file;
            pl.* = s.line;
            hp.* = true;
        }
    }.f;

    while (o < prog.len) {
        const op = prog[o];
        o += 1;

        if (op == 0) {
            // Extended opcode:
            //   0x00  |  LEB128 ext_len  |  ext_opcode  |  data (ext_len-1 bytes)
            const ext_len = uleb(prog, &o) catch return null;
            const ext_start = o; // start of ext_opcode byte
            const ext_op = prog[o];
            o += 1;

            switch (ext_op) {
                DW_LNE_end_sequence => {
                    emitRow(&sm, &best_addr, &best_file, &best_line, &found, target, &prev_addr, &prev_file, &prev_line, &have_prev);
                    sm = SM{ .is_stmt = h.def_is_stmt };
                    if (h.version >= 5) sm.file = 0;
                },
                DW_LNE_set_address => {
                    // Always 8 bytes for our 64-bit kernel
                    sm.addr = std.mem.readInt(u64, prog[o..][0..8], .little);
                },
                DW_LNE_define_file => {
                    // DWARF <=4: dynamically add a file — we skip it for simplicity
                    // since it's uncommon in Zig output
                },
                DW_LNE_set_discriminator => {
                    _ = uleb(prog, &o) catch {};
                },
                else => {},
            }

            // Always jump to exactly the end of this extended opcode
            o = ext_start + @as(usize, ext_len);
        } else if (op < h.opcode_base) {
            // Standard opcode
            switch (op) {
                DW_LNS_copy => {
                    emitRow(&sm, &best_addr, &best_file, &best_line, &found, target, &prev_addr, &prev_file, &prev_line, &have_prev);
                    sm.basic_block = false;
                },
                DW_LNS_advance_pc => {
                    const delta = uleb(prog, &o) catch return null;
                    sm.addr += delta * h.min_insn_len;
                },
                DW_LNS_advance_line => {
                    const delta = sleb(prog, &o) catch return null;
                    sm.line = @intCast(@as(i64, sm.line) + delta);
                },
                DW_LNS_set_file => sm.file = @intCast(uleb(prog, &o) catch return null),
                DW_LNS_set_column => sm.column = @intCast(uleb(prog, &o) catch return null),
                DW_LNS_negate_stmt => sm.is_stmt = !sm.is_stmt,
                DW_LNS_set_basic_block => sm.basic_block = true,
                DW_LNS_const_add_pc => {
                    const adj: u64 = 255 - h.opcode_base;
                    sm.addr += (adj / h.line_range) * h.min_insn_len;
                },
                DW_LNS_fixed_advance_pc => {
                    sm.addr += std.mem.readInt(u16, prog[o..][0..2], .little);
                    o += 2;
                },
                DW_LNS_set_prologue_end => {},
                DW_LNS_set_epilogue_begin => {},
                DW_LNS_set_isa => {
                    _ = uleb(prog, &o) catch return null;
                },
                else => {}, // unknown standard opcode — already skipped by opcode_base check
            }
        } else {
            // Special opcode — encodes both address and line advance in a single byte
            const adj = op - h.opcode_base;
            const line_delta: i8 = @intCast(h.line_base + @as(i8, @intCast(adj % h.line_range)));
            const addr_delta: u64 = (adj / h.line_range) * h.min_insn_len;
            sm.addr += addr_delta;
            sm.line = @intCast(@as(i64, sm.line) + line_delta);
            emitRow(&sm, &best_addr, &best_file, &best_line, &found, target, &prev_addr, &prev_file, &prev_line, &have_prev);
            sm.basic_block = false;
        }
    }

    if (!found and have_prev and prev_addr <= target) {
        best_addr = prev_addr;
        best_file = prev_file;
        best_line = prev_line;
        found = true;
    }
    if (!found) return null;
    return fileToLoc(h, best_file, best_line);
}

fn fileToLoc(h: *const CuHeader, file_idx: u32, line: u32) ?SourceLocation {
    // DWARF 2–4: file register is 1-based (1 = first file in the table)
    // DWARF 5:   file register is 0-based
    const idx: usize = if (h.version <= 4) blk: {
        if (file_idx == 0) return null; // 0 means "no file" in DWARF 2–4
        break :blk file_idx - 1;
    } else file_idx;

    if (idx >= h.nfiles) return null;
    const fe = h.files[idx];

    // Resolve directory
    var dir: []const u8 = "";
    if (h.version <= 4) {
        // dir_idx 0 = current compilation directory (not in our table)
        if (fe.dir > 0 and fe.dir - 1 < h.ndirs)
            dir = h.dirs[fe.dir - 1];
    } else {
        if (fe.dir < h.ndirs)
            dir = h.dirs[fe.dir];
    }

    return SourceLocation{ .directory = dir, .filename = fe.name, .line = line };
}

// ─── Top-level search ─────────────────────────────────────────────────────────

fn searchAll(target: u64) E!?SourceLocation {
    var o: usize = 0;
    while (o < s_debug_line.len) {
        const h = parseCu(&o) catch |err| {
            if (err == error.UnsupportedDwarf) continue; // skip unknown CU versions
            return err;
        };
        if (runProgram(&h, target)) |loc| return loc;
    }
    return null;
}
