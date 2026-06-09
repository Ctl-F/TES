// This is not a thread safe log implementation
const std = @import("std");
const console = @import("conio.zig");

pub fn init(io: std.Io, source: []const u8) Log {
    return Log{
        .io = io,
        .source = source,
    };
}

pub const Log = struct {
    io: std.Io,
    source: []const u8,

    pub fn info(this: @This(), comptime messageFmt: []const u8, args: anytype) void {
        log(this.io, .Info, this.source, messageFmt, args);
    }

    pub fn warn(this: @This(), comptime messageFmt: []const u8, args: anytype) void {
        log(this.io, .Warn, this.source, messageFmt, args);
    }

    pub fn err(this: @This(), comptime messageFmt: []const u8, args: anytype) void {
        log(this.io, .Error, this.source, messageFmt, args);
    }

    pub fn fatal(this: @This(), comptime messageFmt: []const u8, args: anytype) void {
        log(this.io, .Fatal, this.source, messageFmt, args);
    }

    pub fn trace(this: @This(), comptime messageFmt: []const u8, args: anytype) void {
        log(this.io, .Trace, this.source, messageFmt, args);
    }
};

pub const Level = enum {
    Trace,
    Info,
    Warn,
    Error,
    Fatal,

    fn to_string(this: @This()) []const u8 {
        return switch (this) {
            .Trace => "trace",
            .Info => "info",
            .Warn => "warn",
            .Error => "error",
            .Fatal => "fatal",
        };
    }

    fn get_fg(this: @This()) console.Color {
        return switch (this) {
            .Trace => .green,
            .Info => .white,
            .Warn => .yellow,
            .Error => .red,
            .Fatal => .black,
        };
    }

    fn get_bg(this: @This()) console.BgColor {
        return switch (this) {
            .Trace => .black,
            .Info => .black,
            .Warn => .black,
            .Error => .black,
            .Fatal => .white,
        };
    }
};

pub fn warn(io: std.Io, source: []const u8, comptime messageFmt: []const u8, args: anytype) void {
    log(io, .Warn, source, messageFmt, args);
}

pub fn info(io: std.Io, source: []const u8, comptime messageFmt: []const u8, args: anytype) void {
    log(io, .Info, source, messageFmt, args);
}

pub fn trace(io: std.Io, source: []const u8, comptime messageFmt: []const u8, args: anytype) void {
    log(io, .Trace, source, messageFmt, args);
}

pub fn err(io: std.Io, source: []const u8, comptime messageFmt: []const u8, args: anytype) void {
    log(io, .Error, source, messageFmt, args);
}

pub fn fatal(io: std.Io, source: []const u8, comptime messageFmt: []const u8, args: anytype) void {
    log(io, .Fatal, source, messageFmt, args);
}

pub fn log(io: std.Io, level: Level, source: []const u8, comptime messageFmt: []const u8, args: anytype) void {
    const fg = level.get_fg();
    const bg = level.get_bg();

    // TODO: allow for single buffered write rather than multiple buffered writes
    console.setFg(io, fg) catch {};
    console.setBg(io, bg) catch {};

    console.print(io, "[{s}] {s}: ", .{ source, level.to_string() }) catch {};
    console.print(io, messageFmt, args) catch {};
    console.print(io, "\n", .{}) catch {};
}
