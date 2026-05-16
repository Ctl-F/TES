/// TES Disassembler — restores a .tbf binary to readable .tes assembly.
/// If the binary contains debug symbols they are used for label/data names;
/// otherwise synthetic names (lbl_NNNN / data_PG_OOOO) are generated.
const std = @import("std");
const Io = std.Io;
const encoder = @import("encoder.zig");
const Format = encoder.Format;
const RegID = encoder.RegID;

pub const DisasmError = error{
    BadMagic,
    TruncatedFile,
    OutOfMemory,
};

// ── TBF reader ────────────────────────────────────────────────────────────────

const DataPage = struct {
    page:   u8,
    offset: u16,
    data:   []const u8,
};

const DebugSym = struct {
    address: u32,
    name:    []const u8,
};

const TBF = struct {
    instructions: []u32,
    data_pages:   []DataPage,
    debug_syms:   []DebugSym,
    allocator:    std.mem.Allocator,

    fn deinit(self: *@This()) void {
        self.allocator.free(self.instructions);
        for (self.data_pages) |dp| self.allocator.free(dp.data);
        self.allocator.free(self.data_pages);
        for (self.debug_syms) |ds| self.allocator.free(ds.name);
        self.allocator.free(self.debug_syms);
    }
};

fn readU8(buf: []const u8, pos: *usize) DisasmError!u8 {
    if (pos.* >= buf.len) return DisasmError.TruncatedFile;
    defer pos.* += 1;
    return buf[pos.*];
}
fn readU16(buf: []const u8, pos: *usize) DisasmError!u16 {
    if (pos.* + 2 > buf.len) return DisasmError.TruncatedFile;
    const v = std.mem.readInt(u16, buf[pos.*..][0..2], .little);
    pos.* += 2;
    return v;
}
fn readU32(buf: []const u8, pos: *usize) DisasmError!u32 {
    if (pos.* + 4 > buf.len) return DisasmError.TruncatedFile;
    const v = std.mem.readInt(u32, buf[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn parseTBF(allocator: std.mem.Allocator, raw: []const u8) DisasmError!TBF {
    var pos: usize = 0;

    // magic
    if (pos + 4 > raw.len or !std.mem.eql(u8, raw[0..4], "TESB"))
        return DisasmError.BadMagic;
    pos += 4;

    // instructions
    const n_instrs = try readU32(raw, &pos);
    const instrs = try allocator.alloc(u32, n_instrs);
    errdefer allocator.free(instrs);
    for (instrs) |*w| w.* = try readU32(raw, &pos);

    // data pages
    const n_pages = try readU8(raw, &pos);
    const pages = try allocator.alloc(DataPage, n_pages);
    errdefer {
        for (pages) |dp| allocator.free(dp.data);
        allocator.free(pages);
    }
    var pages_inited: usize = 0;
    for (pages) |*dp| {
        dp.page   = try readU8(raw, &pos);
        dp.offset = try readU16(raw, &pos);
        const sz  = try readU16(raw, &pos);
        if (pos + sz > raw.len) return DisasmError.TruncatedFile;
        dp.data = try allocator.dupe(u8, raw[pos .. pos + sz]);
        pos += sz;
        pages_inited += 1;
    }

    // extensions (skip)
    const n_ext = try readU16(raw, &pos);
    pos += @as(usize, n_ext) * 3; // u16 id + u8 enabled

    // debug symbols
    const n_syms = try readU32(raw, &pos);
    const syms = try allocator.alloc(DebugSym, n_syms);
    errdefer {
        for (syms) |ds| allocator.free(ds.name);
        allocator.free(syms);
    }
    var syms_inited: usize = 0;
    for (syms) |*ds| {
        ds.address = try readU32(raw, &pos);
        const nlen = try readU16(raw, &pos);
        if (pos + nlen > raw.len) return DisasmError.TruncatedFile;
        ds.name = try allocator.dupe(u8, raw[pos .. pos + nlen]);
        pos += nlen;
        syms_inited += 1;
    }

    return .{
        .instructions = instrs,
        .data_pages   = pages,
        .debug_syms   = syms,
        .allocator    = allocator,
    };
}

// ── Register name ─────────────────────────────────────────────────────────────

fn regName(id: u5) []const u8 {
    return switch (id) {
        0  => "r0",  1  => "r1",  2  => "r2",  3  => "r3",
        4  => "r4",  5  => "r5",  6  => "r6",  7  => "r7",
        8  => "r8",  9  => "r9",  10 => "ra",  11 => "rb",
        12 => "rc",  13 => "rd",  14 => "re",  15 => "rf",
        16 => "ip",  18 => "jr",
        20 => "fcl", 21 => "fch", 22 => "gcl", 23 => "gch",
        24 => "sh",  25 => "sb",  26 => "sp",
        else => "??",
    };
}

// ── Sign-extend helpers ───────────────────────────────────────────────────────

fn signExt9(v: u32) i32 {
    const u: u9 = @truncate(v);
    return @as(i32, @as(i9, @bitCast(u)));
}
fn signExt14(v: u32) i32 {
    const u: u14 = @truncate(v);
    return @as(i32, @as(i14, @bitCast(u)));
}

// ── Label map ─────────────────────────────────────────────────────────────────

const LabelMap = std.AutoHashMapUnmanaged(u32, []const u8);

/// Build instruction-index → label-name map.
/// Entries from debug_syms that look like instruction indices are used;
/// otherwise synthetic names are assigned to branch targets.
fn buildLabelMap(
    allocator: std.mem.Allocator,
    tbf:       *const TBF,
    /// set of instruction indices that are branch targets (filled here)
    targets:   *std.AutoHashMapUnmanaged(u32, void),
) DisasmError!LabelMap {
    var map: LabelMap = .{};
    errdefer map.deinit(allocator);

    const n = @as(u32, @intCast(tbf.instructions.len));

    // Populate from debug symbols: treat address as instruction index if < n
    for (tbf.debug_syms) |ds| {
        if (ds.address < n and (ds.address >> 16) == 0) {
            const name = try allocator.dupe(u8, ds.name);
            errdefer allocator.free(name);
            try map.put(allocator, ds.address, name);
        }
    }

    // Scan instructions for branch targets not already in the map
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const w = tbf.instructions[i];
        const op: u8 = @truncate(w & 0xFF);
        const info = findOpcodeByByte(op) orelse { i += skipCount(w); continue; };
        switch (info.format) {
            .BranchNear => {
                const off = signExt14((w >> 13) & 0x3FFF);
                const tgt = @as(i64, i) + off;
                if (tgt >= 0 and tgt < n) {
                    targets.put(allocator, @intCast(tgt), {}) catch return DisasmError.OutOfMemory;
                }
            },
            .BranchNearCond => {
                const off = signExt14((w >> 13) & 0x3FFF);
                const tgt = @as(i64, i) + off;
                if (tgt >= 0 and tgt < n) {
                    targets.put(allocator, @intCast(tgt), {}) catch return DisasmError.OutOfMemory;
                }
            },
            else => {},
        }
        i += extraWords(info.format);
    }

    // Assign synthetic names to targets that have no debug name
    var tit = targets.keyIterator();
    while (tit.next()) |idx| {
        if (!map.contains(idx.*)) {
            const name = std.fmt.allocPrint(allocator, "lbl_{d:0>4}", .{idx.*})
                catch return DisasmError.OutOfMemory;
            errdefer allocator.free(name);
            try map.put(allocator, idx.*, name);
        }
    }

    return map;
}

fn findOpcodeByByte(op: u8) ?encoder.OpcodeInfo {
    for (encoder.opcodes) |info| {
        if (info.opcode == op) return info;
    }
    return null;
}

/// Extra words consumed after the first word (not counting the first word itself).
fn extraWords(fmt: Format) u32 {
    return switch (fmt) {
        .LeaWide => 1,
        else     => 0,
    };
}

/// How many words to skip if we can't decode an instruction (treat as 1).
fn skipCount(_: u32) u32 { return 0; }

// ── Data symbol map ───────────────────────────────────────────────────────────

const DataSymMap = std.AutoHashMapUnmanaged(u32, []const u8); // key = (page<<16)|offset

fn buildDataSymMap(allocator: std.mem.Allocator, tbf: *const TBF) DisasmError!DataSymMap {
    var map: DataSymMap = .{};
    errdefer map.deinit(allocator);
    const n = @as(u32, @intCast(tbf.instructions.len));
    for (tbf.debug_syms) |ds| {
        // data sym: address >= instruction count OR high 16 bits non-zero
        if (ds.address >= n or (ds.address >> 16) != 0) {
            const name = try allocator.dupe(u8, ds.name);
            errdefer allocator.free(name);
            try map.put(allocator, ds.address, name);
        }
    }
    return map;
}

// ── Main disassembly entry point ──────────────────────────────────────────────

pub fn disassemble(
    allocator: std.mem.Allocator,
    io:        Io,
    tbf_path:  []const u8,
    writer:    *Io.Writer,
) !void {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, tbf_path, allocator, .limited(64 * 1024 * 1024)) catch |e| {
        std.debug.print("Error: cannot read '{s}': {}\n", .{ tbf_path, e });
        return e;
    };
    defer allocator.free(raw);

    var tbf = try parseTBF(allocator, raw);
    defer tbf.deinit();

    var targets: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer targets.deinit(allocator);

    var label_map = try buildLabelMap(allocator, &tbf, &targets);
    defer {
        var it = label_map.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        label_map.deinit(allocator);
    }

    var data_map = try buildDataSymMap(allocator, &tbf);
    defer {
        var it = data_map.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        data_map.deinit(allocator);
    }

    const has_debug = tbf.debug_syms.len > 0;

    // ── [Program] section ─────────────────────────────────────────────────
    try writer.writeAll("[Program]\n");

    const n = @as(u32, @intCast(tbf.instructions.len));
    var i: u32 = 0;
    while (i < n) {
        // Emit label if this instruction is a target or has a debug name
        if (label_map.get(i)) |lname| {
            try writer.print("{s}:\n", .{lname});
        } else if (!has_debug and targets.contains(i)) {
            try writer.print("lbl_{d:0>4}:\n", .{i});
        }

        const w = tbf.instructions[i];
        const op: u8 = @truncate(w & 0xFF);

        if (findOpcodeByByte(op)) |info| {
            try writer.writeAll("    ");
            try emitInstruction(writer, &tbf, info, w, i, n, &label_map);
            try writer.writeByte('\n');
            i += 1 + extraWords(info.format);
        } else {
            // Unknown opcode — emit as raw word
            try writer.print("    ; raw 0x{X:0>8}\n", .{w});
            i += 1;
        }
    }

    // ── [Data] sections ───────────────────────────────────────────────────
    for (tbf.data_pages) |dp| {
        try writer.print("\n[Data({d}:0x{X:0>4})]\n", .{ dp.page, dp.offset });

        // Try to emit named symbols from data_map for this page
        // Group bytes by known symbol boundaries where possible
        var byte_idx: usize = 0;
        while (byte_idx < dp.data.len) {
            const addr: u32 = (@as(u32, dp.page) << 16) | (@as(u32, dp.offset) + @as(u32, @intCast(byte_idx)));
            if (data_map.get(addr)) |dname| {
                try writer.print("    {s}: ", .{dname});
            } else {
                try writer.writeAll("    ");
            }
            // Emit up to 16 bytes per line as .u8 array initializer
            const chunk = @min(16, dp.data.len - byte_idx);
            try writer.writeAll(".u8 .");
            if (chunk == 1) {
                try writer.print("{{{d}}}\n", .{dp.data[byte_idx]});
            } else {
                try writer.writeByte('{');
                for (dp.data[byte_idx .. byte_idx + chunk], 0..) |b, bi| {
                    if (bi > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{b});
                }
                try writer.writeAll("}\n");
            }
            byte_idx += chunk;
        }
    }
}

/// Print the instruction at `target` IP address, with `window` instructions of
/// context on each side.  Writes to stdout (always a diagnostic, not a file).
pub fn disassembleExtract(
    allocator: std.mem.Allocator,
    io:        Io,
    tbf_path:  []const u8,
    writer:    *Io.Writer,
    target:    u32,
    window:    u32,
) !void {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, tbf_path, allocator, .limited(64 * 1024 * 1024)) catch |e| {
        std.debug.print("Error: cannot read '{s}': {}\n", .{ tbf_path, e });
        return e;
    };
    defer allocator.free(raw);

    var tbf = try parseTBF(allocator, raw);
    defer tbf.deinit();

    var targets: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer targets.deinit(allocator);

    var label_map = try buildLabelMap(allocator, &tbf, &targets);
    defer {
        var it = label_map.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        label_map.deinit(allocator);
    }

    const n = @as(u32, @intCast(tbf.instructions.len));

    // Build an ordered list of instruction-start word indices.
    var instr_ips: std.ArrayList(u32) = .empty;
    defer instr_ips.deinit(allocator);
    {
        var i: u32 = 0;
        while (i < n) {
            try instr_ips.append(allocator, i);
            const op: u8 = @truncate(tbf.instructions[i] & 0xFF);
            const step: u32 = if (findOpcodeByByte(op)) |info| 1 + extraWords(info.format) else 1;
            i += step;
        }
    }

    // Find which entry owns `target` (handles multi-word instructions).
    var tgt_entry: ?usize = null;
    for (instr_ips.items, 0..) |ip, idx| {
        if (ip == target) { tgt_entry = idx; break; }
        // Check if target falls inside a multi-word instruction at ip.
        const op: u8 = @truncate(tbf.instructions[ip] & 0xFF);
        if (findOpcodeByByte(op)) |info| {
            if (extraWords(info.format) > 0 and target > ip and target <= ip + extraWords(info.format)) {
                tgt_entry = idx;
                break;
            }
        }
    }

    const tgt_idx = tgt_entry orelse {
        try writer.print("No instruction at IP {d} (binary has {d} words)\n", .{ target, n });
        return;
    };

    const from: usize = if (tgt_idx >= window) tgt_idx - window else 0;
    const to:   usize = @min(instr_ips.items.len, tgt_idx + window + 1);

    for (instr_ips.items[from..to], from..) |ip, list_idx| {
        const is_target = list_idx == tgt_idx;
        const w   = tbf.instructions[ip];
        const op: u8 = @truncate(w & 0xFF);

        // Label line (not indented with marker, always plain)
        if (label_map.get(ip)) |lname| {
            try writer.print("   [{d:>6}] {s}:\n", .{ ip, lname });
        }

        const marker: []const u8 = if (is_target) ">>" else "  ";
        try writer.print("{s} [{d:>6}]  ", .{ marker, ip });

        if (findOpcodeByByte(op)) |info| {
            if (is_target and info.format == .LeaWide) {
                try writer.writeAll("(address of) ");
            }
            try emitInstruction(writer, &tbf, info, w, ip, n, &label_map);
        } else {
            try writer.print("raw 0x{X:0>8}", .{w});
        }
        try writer.writeByte('\n');
    }
}

fn emitInstruction(
    w:         *Io.Writer,
    tbf:       *const TBF,
    info:      encoder.OpcodeInfo,
    word:      u32,
    idx:       u32,
    n:         u32,
    lmap:      *const LabelMap,
) !void {
    const r = struct {
        fn reg(word2: u32, shift: u5) u5 { return @truncate((word2 >> shift) & 0x1F); }
        fn off9(word2: u32, shift: u5) i32 { return signExt9((word2 >> shift) & 0x1FF); }
    };

    switch (info.format) {
        .Bare => {
            // resume_skip is the canonical bare `resume` in user-facing syntax
            const name = if (std.mem.eql(u8, info.mnemonic, "resume_skip")) "resume" else info.mnemonic;
            try w.writeAll(name);
        },

        .Dst => {
            const dst = r.reg(word, 8);
            const p19 = (word >> 13) & 0x7FFFF;
            try w.print("{s} {s}, {d}", .{ info.mnemonic, regName(dst), p19 });
        },

        .DstSrc => {
            const dst = r.reg(word, 8);
            const src = r.reg(word, 13);
            try w.print("{s} {s}, {s}", .{ info.mnemonic, regName(dst), regName(src) });
        },

        .DstAddrSrc => {
            const base = r.reg(word, 8);
            const src  = r.reg(word, 13);
            const off  = r.off9(word, 18);
            if (off == 0) {
                try w.print("{s} [{s}], {s}", .{ info.mnemonic, regName(base), regName(src) });
            } else {
                try w.print("{s} [{s}{s}{d}], {s}", .{ info.mnemonic, regName(base), if (off > 0) "+" else "", off, regName(src) });
            }
        },

        .DstAddrXSrc => {
            const psr = r.reg(word, 8);
            const por = r.reg(word, 13);
            const src = r.reg(word, 18);
            const off = r.off9(word, 23);
            if (off == 0) {
                try w.print("{s} [{s}, {s}], {s}", .{ info.mnemonic, regName(psr), regName(por), regName(src) });
            } else {
                try w.print("{s} [{s}, {s}{s}{d}], {s}", .{ info.mnemonic, regName(psr), regName(por), if (off > 0) "+" else "", off, regName(src) });
            }
        },

        .DstSrcAddr => {
            const dst = r.reg(word, 8);
            const por = r.reg(word, 13);
            const off = r.off9(word, 18);
            if (off == 0) {
                try w.print("{s} {s}, [{s}]", .{ info.mnemonic, regName(dst), regName(por) });
            } else {
                try w.print("{s} {s}, [{s}{s}{d}]", .{ info.mnemonic, regName(dst), regName(por), if (off > 0) "+" else "", off });
            }
        },

        .DstSrcAddrX => {
            const dst = r.reg(word, 8);
            const psr = r.reg(word, 13);
            const por = r.reg(word, 18);
            const off = r.off9(word, 23);
            if (off == 0) {
                try w.print("{s} {s}, [{s}, {s}]", .{ info.mnemonic, regName(dst), regName(psr), regName(por) });
            } else {
                try w.print("{s} {s}, [{s}, {s}{s}{d}]", .{ info.mnemonic, regName(dst), regName(psr), regName(por), if (off > 0) "+" else "", off });
            }
        },

        .Dst2Src2 => {
            const d0 = r.reg(word, 8);
            const d1 = r.reg(word, 13);
            const s0 = r.reg(word, 18);
            const s1 = r.reg(word, 23);
            try w.print("{s} {s}, {s}, {s}, {s}", .{ info.mnemonic, regName(d0), regName(d1), regName(s0), regName(s1) });
        },

        .Dst2Src2Len => {
            const d0  = r.reg(word, 8);
            const d1  = r.reg(word, 13);
            const s0  = r.reg(word, 18);
            const s1  = r.reg(word, 23);
            const len: u5 = @intCast((word >> 28) & 0xF);
            try w.print("{s} {s}, {s}, {s}, {s}, {s}", .{ info.mnemonic, regName(d0), regName(d1), regName(s0), regName(s1), regName(len) });
        },

        .DstSrc2 => {
            const dst = r.reg(word, 8);
            const s0  = r.reg(word, 13);
            const s1  = r.reg(word, 18);
            try w.print("{s} {s}, {s}, {s}", .{ info.mnemonic, regName(dst), regName(s0), regName(s1) });
        },

        .DstSrc3 => {
            const dst = r.reg(word, 8);
            const s0  = r.reg(word, 13);
            const s1  = r.reg(word, 18);
            const s2  = r.reg(word, 23);
            try w.print("{s} {s}, {s}, {s}, {s}", .{ info.mnemonic, regName(dst), regName(s0), regName(s1), regName(s2) });
        },

        .LeaWide => {
            const hi   = r.reg(word, 8);
            const lo   = r.reg(word, 13);
            const addr = if (idx + 1 < n) tbf.instructions[idx + 1] else 0;
            try w.print("lea {s}, {s}, 0x{X}", .{ regName(hi), regName(lo), addr });
        },

        .BranchReg => {
            const hi = r.reg(word, 8);
            const lo = r.reg(word, 13);
            try w.print("{s} {s}, {s}", .{ info.mnemonic, regName(hi), regName(lo) });
        },

        .BranchRegCond => {
            const hi   = r.reg(word, 8);
            const lo   = r.reg(word, 13);
            const cond = r.reg(word, 18);
            try w.print("{s} {s}, {s}, {s}", .{ info.mnemonic, regName(hi), regName(lo), regName(cond) });
        },

        .BranchNear => {
            const off = signExt14((word >> 13) & 0x3FFF);
            const tgt = @as(i64, idx) + off;
            if (tgt >= 0 and tgt < n) {
                const tidx: u32 = @intCast(tgt);
                if (lmap.get(tidx)) |lname| {
                    try w.print("{s} {s}", .{ info.mnemonic, lname });
                } else {
                    try w.print("{s} lbl_{d:0>4}", .{ info.mnemonic, tidx });
                }
            } else {
                try w.print("{s} {d}", .{ info.mnemonic, off });
            }
        },

        .BranchNearCond => {
            const cond = r.reg(word, 8);
            const off  = signExt14((word >> 13) & 0x3FFF);
            const tgt  = @as(i64, idx) + off;
            if (tgt >= 0 and tgt < n) {
                const tidx: u32 = @intCast(tgt);
                if (lmap.get(tidx)) |lname| {
                    try w.print("{s} {s}, {s}", .{ info.mnemonic, regName(cond), lname });
                } else {
                    try w.print("{s} {s}, lbl_{d:0>4}", .{ info.mnemonic, regName(cond), tidx });
                }
            } else {
                try w.print("{s} {s}, {d}", .{ info.mnemonic, regName(cond), off });
            }
        },

        .Syscall => {
            const pool  = (word >> 8)  & 0x1FF;
            const event = (word >> 17) & 0x7FFF;
            try w.print("syscall {d}, {d}", .{ pool, event });
        },

        .ResumeReg => {
            const hi = @as(u5, @truncate((word >> 8)  & 0x1F));
            const lo = @as(u5, @truncate((word >> 13) & 0x1F));
            try w.print("resume [{s}, {s}]", .{ regName(hi), regName(lo) });
        },

        .VReduce => {
            const dst = @as(u5, @truncate((word >> 8)  & 0x1F));
            const src = @as(u5, @truncate((word >> 13) & 0x1F));
            const rc  = @as(u4, @truncate((word >> 18) & 0xF));
            try w.print("vreduce2 {s}, {s}, {s}", .{ regName(dst), regName(src), encoder.reduceCodeName(rc) });
        },
    }
}
