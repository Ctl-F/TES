const std = @import("std");
const lexer = @import("lexer.zig");
const preprocessor = @import("preprocessor.zig");
const parser = @import("parser.zig");
const tbf = @import("tbf.zig");
const disasm = @import("disasm.zig");

const Define = struct { name: []const u8, value: []const u8 };

const usage =
    \\TES Assembler/Disassembler (tas) — Terere Binary Format (.tbf) toolchain
    \\
    \\Assembly:
    \\  tas [options] <input.tes>
    \\
    \\Disassembly:
    \\  tas --disasm <input.tbf> [-o <output.tes>]
    \\  tas --disasm --extract <ip> [--window <n>] <input.tbf>
    \\
    \\Options:
    \\  -o <output>       Output file path (default: derived from input)
    \\  -I <dir>          Add include search directory (repeatable)
    \\  -D <name[=val]>   Define a preprocessor macro (val defaults to 1)
    \\  --debug           Emit debug symbols in TBF output
    \\  --disasm          Disassemble a .tbf binary back to .tes source
    \\  --extract <ip>    Print the instruction at IP address <ip> (requires --disasm)
    \\  --window <n>      Context lines on each side for --extract (default: 5)
    \\  --dump-tokens     Print token stream and exit
    \\  --dump-symbols    Print symbol table after assembly
    \\  -h, --help        Show this help
    \\
    \\Examples:
    \\  tas game.tes -o game.tbf --debug
    \\  tas --disasm game.tbf -o game_dis.tes
    \\  tas --disasm --extract 27 game.tbf
    \\  tas --disasm --extract 27 --window 10 game.tbf
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // args[0] is the program name; skip it
    const all_args = try init.minimal.args.toSlice(allocator);
    const args = all_args[1..];

    if (args.len == 0) {
        try stderr.writeAll(usage);
        return error.NoArguments;
    }

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var emit_debug = false;
    var dump_tokens = false;
    var dump_symbols = false;
    var do_disasm = false;
    var extract_ip: ?u32 = null;
    var extract_window: u32 = 5;

    var include_dirs: std.ArrayList([]const u8) = .empty;
    defer include_dirs.deinit(allocator);

    var defines: std.ArrayList(Define) = .empty;
    defer defines.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            emit_debug = true;
        } else if (std.mem.eql(u8, arg, "--disasm")) {
            do_disasm = true;
        } else if (std.mem.eql(u8, arg, "--extract")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: --extract requires an IP address\n");
                return error.BadArgs;
            }
            extract_ip = std.fmt.parseInt(u32, args[i], 0) catch {
                try stderr.print("Error: --extract: invalid IP '{s}'\n", .{args[i]});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "--window")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: --window requires a number\n");
                return error.BadArgs;
            }
            extract_window = std.fmt.parseInt(u32, args[i], 0) catch {
                try stderr.print("Error: --window: invalid number '{s}'\n", .{args[i]});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "--dump-tokens")) {
            dump_tokens = true;
        } else if (std.mem.eql(u8, arg, "--dump-symbols")) {
            dump_symbols = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: -o requires a filename\n");
                return error.BadArgs;
            }
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "-I")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: -I requires a directory\n");
                return error.BadArgs;
            }
            try include_dirs.append(allocator, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-I")) {
            try include_dirs.append(allocator, arg[2..]);
        } else if (std.mem.eql(u8, arg, "-D")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: -D requires NAME or NAME=VALUE\n");
                return error.BadArgs;
            }
            try appendDefine(&defines, allocator, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            try appendDefine(&defines, allocator, arg[2..]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Error: unknown option '{s}'\n", .{arg});
            return error.BadArgs;
        } else {
            if (input_path != null) {
                try stderr.writeAll("Error: multiple input files\n");
                return error.BadArgs;
            }
            input_path = arg;
        }
    }

    const inpath = input_path orelse {
        try stderr.writeAll(usage);
        try stderr.writeAll("Error: no input file specified\n");
        return error.BadArgs;
    };

    const outpath = output_path orelse blk: {
        const stem = if (std.mem.lastIndexOfScalar(u8, inpath, '.')) |dot|
            inpath[0..dot]
        else
            inpath;
        break :blk try std.fmt.allocPrint(allocator, "{s}.tbf", .{stem});
    };

    // ── Disassembly mode ─────────────────────────────────────────────────
    if (do_disasm) {
        if (extract_ip) |ip| {
            // Extract mode: always writes to stdout
            try disasm.disassembleExtract(allocator, io, inpath, stdout, ip, extract_window);
        } else {
            const dis_out = output_path orelse blk: {
                const stem = if (std.mem.lastIndexOfScalar(u8, inpath, '.')) |dot|
                    inpath[0..dot]
                else
                    inpath;
                break :blk try std.fmt.allocPrint(allocator, "{s}_dis.tes", .{stem});
            };
            if (std.mem.eql(u8, dis_out, "-")) {
                try disasm.disassemble(allocator, io, inpath, stdout);
            } else {
                const file = try std.Io.Dir.cwd().createFile(io, dis_out, .{});
                defer file.close(io);
                var fbuf: [4096]u8 = undefined;
                var fw = file.writer(io, &fbuf);
                try disasm.disassemble(allocator, io, inpath, &fw.interface);
                try fw.interface.flush();
                try stdout.print("Disassembled {s} -> {s}\n", .{ inpath, dis_out });
            }
        }
        return;
    }

    // ── Read source ──────────────────────────────────────────────────────
    const src = std.Io.Dir.cwd().readFileAlloc(io, inpath, allocator, .limited(64 * 1024 * 1024)) catch |e| {
        try stderr.print("Error: cannot read '{s}': {}\n", .{ inpath, e });
        return e;
    };

    // ── Preprocess ───────────────────────────────────────────────────────
    var prep = preprocessor.Preprocessor.init(allocator, io);
    defer prep.deinit();

    // Implicit include: <binary-dir>/teslib  (installed alongside the assembler binary)
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &exe_dir_buf) catch null) |len| {
        const dir = exe_dir_buf[0..len];
        const implicit_teslib = try std.fmt.allocPrint(allocator, "{s}/teslib", .{dir});
        try prep.addIncludeDir(implicit_teslib);
    }

    for (include_dirs.items) |dir| try prep.addIncludeDir(dir);
    for (defines.items) |def| try prep.addDefine(def.name, def.value);

    const preprocessed = prep.process(src, inpath) catch |e| {
        try stderr.print("Preprocessor error: {}\n", .{e});
        return e;
    };

    // ── Lex ──────────────────────────────────────────────────────────────
    var lx = lexer.Lexer.initWithFile(preprocessed, inpath);
    const token_slice = lx.tokenize(allocator) catch |e| {
        try stderr.print("Lexer error: {}\n", .{e});
        return e;
    };

    if (dump_tokens) {
        try stdout.print("=== Token Stream ({} tokens) ===\n", .{token_slice.len});
        for (token_slice) |tok| {
            try stdout.print("  {s}:{:>4}:{:>3} {s:<20} '{s}'", .{ tok.source_file, tok.line, tok.col, @tagName(tok.kind), tok.text });
            if (tok.kind == .Integer) try stdout.print("  (= {})", .{tok.int_value});
            if (tok.kind == .SectionData) try stdout.print("  (page={} offset={})", .{ tok.data_page, tok.data_offset });
            try stdout.print("\n", .{});
        }
        return;
    }

    // ── Parse ────────────────────────────────────────────────────────────
    var p = parser.Parser.init(allocator, token_slice, emit_debug);
    p.parse() catch |e| {
        p.deinit();
        try stderr.print("Assembly error: {}\n", .{e});
        return e;
    };
    defer p.deinit();

    if (dump_symbols) {
        try stdout.writeAll("=== Symbol Table ===\n");
        var sit = p.sym.symbols.iterator();
        while (sit.next()) |entry| {
            switch (entry.value_ptr.*) {
                .Label => |idx| try stdout.print("  LABEL  {s:<30} -> instruction[{}]\n", .{ entry.key_ptr.*, idx }),
                .Data => |d| try stdout.print("  DATA   {s:<30} -> page={} offset=0x{X:0>4} size={} type={s}\n", .{
                    entry.key_ptr.*,                                  d.page, d.offset, d.size,
                    if (d.struct_name) |sn| sn else @tagName(d.prim),
                }),
            }
        }
        try stdout.writeAll("=== Structs ===\n");
        var strit = p.sym.structs.iterator();
        while (strit.next()) |entry| {
            const sd = entry.value_ptr.*;
            try stdout.print("  struct {s} (size={})\n", .{ sd.name, sd.total_size });
            for (sd.fields.items) |f| {
                try stdout.print("    +{:>4}  {s}: {s}\n", .{
                    f.offset, f.name, if (f.struct_name) |sn| sn else @tagName(f.prim),
                });
            }
        }
        try stdout.writeAll("=== Instructions ===\n");
        for (p.tbfWriter.instructions.items, 0..) |word, idx| {
            try stdout.print("  [{:>4}] 0x{X:0>8}\n", .{ idx, word });
        }
    }

    // ── Write TBF ────────────────────────────────────────────────────────
    p.tbfWriter.writeFile(io, outpath) catch |e| {
        try stderr.print("Error writing '{s}': {}\n", .{ outpath, e });
        return e;
    };

    try stdout.print(
        "Assembled {s}  ({} instructions, {} data pages, {} debug symbols)  ->  {s}\n",
        .{
            inpath,
            p.tbfWriter.instructions.items.len,
            p.tbfWriter.data_pages.items.len,
            p.tbfWriter.debug_symbols.items.len,
            outpath,
        },
    );
}

fn appendDefine(
    list: *std.ArrayList(Define),
    allocator: std.mem.Allocator,
    arg: []const u8,
) !void {
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        try list.append(allocator, .{ .name = arg[0..eq], .value = arg[eq + 1 ..] });
    } else {
        try list.append(allocator, .{ .name = arg, .value = "1" });
    }
}
