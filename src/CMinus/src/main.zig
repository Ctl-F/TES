const std = @import("std");
const CMinus = @import("CMinus");

const usage =
    \\C- Compiler — emits TES assembly (.tes)
    \\
    \\Usage:
    \\  CMinus [options] <input.cm>
    \\
    \\Options:
    \\  -o <output.tes>   Output file (default: <input>.tes, or "-" for stdout)
    \\  -h, --help        Show this help
    \\
    \\Examples:
    \\  CMinus hello.cm -o hello.tes
    \\  CMinus hello.cm -o -
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

    const all_args = try init.minimal.args.toSlice(allocator);
    const args = all_args[1..];

    if (args.len == 0) {
        try stderr.writeAll(usage);
        return error.NoArguments;
    }

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: -o requires a filename\n");
                return error.BadArgs;
            }
            output_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Error: unknown option '{s}'\n", .{arg});
            return error.BadArgs;
        } else {
            if (input_path != null) {
                try stderr.writeAll("Error: multiple input files specified\n");
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

    // Default output: replace extension with .tes (or append .tes)
    const outpath = output_path orelse blk: {
        const stem = if (std.mem.lastIndexOfScalar(u8, inpath, '.')) |dot|
            inpath[0..dot]
        else
            inpath;
        break :blk try std.fmt.allocPrint(allocator, "{s}.tes", .{stem});
    };

    // Read source file
    const src = std.Io.Dir.cwd().readFileAlloc(io, inpath, allocator, .limited(16 * 1024 * 1024)) catch |e| {
        try stderr.print("Error: cannot read '{s}': {}\n", .{ inpath, e });
        return e;
    };

    // Compile and write output
    if (std.mem.eql(u8, outpath, "-")) {
        // Write directly to stdout
        CMinus.compileSource(allocator, src, inpath, stdout) catch |e| {
            try stderr.print("Compile error: {}\n", .{e});
            return e;
        };
    } else {
        // Write to file
        const file = std.Io.Dir.cwd().createFile(io, outpath, .{}) catch |e| {
            try stderr.print("Error: cannot create '{s}': {}\n", .{ outpath, e });
            return e;
        };
        defer file.close(io);
        var fbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &fbuf);
        CMinus.compileSource(allocator, src, inpath, &fw.interface) catch |e| {
            try stderr.print("Compile error: {}\n", .{e});
            return e;
        };
        try fw.interface.flush();
        try stdout.print("Compiled {s} -> {s}\n", .{ inpath, outpath });
    }
}
