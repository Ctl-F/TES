const std = @import("std");

const ENTER_ALT_MODE = "\x1b[?1049h";
const EXIT_ALT_MODE = "\x1b[2J\x1b[?1049l";

pub const Color = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
};

pub const BgColor = enum(u8) {
    black = 40,
    red = 41,
    green = 42,
    yellow = 43,
    blue = 44,
    magenta = 45,
    cyan = 46,
    white = 47,
};

pub fn begin(io: std.Io) !void {
    var buf: [128]u8 = undefined;
    var writer = getStdout(io, &buf);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(ENTER_ALT_MODE);
}

pub fn end(io: std.Io) !void {
    var buf: [128]u8 = undefined;
    var writer = getStdout(io, &buf);
    defer writer.interface.flush() catch {};

    try writer.interface.writeAll(EXIT_ALT_MODE);
}

pub fn moveCursor(io: std.Io, row: u16, col: u16) !void {
    var stdoutBuf: [128]u8 = undefined;

    var writer = getStdout(io, &stdoutBuf);
    defer writer.interface.flush() catch {};

    try writer.interface.print("\x1b[{};{}H", .{ row, col });
}

pub fn clearToEnd(io: std.Io) !void {
    var buf: [128]u8 = undefined;
    var writer = getStdout(io, &buf);
    defer writer.interface.flush() catch {};

    try writer.interface.write("\x1b[K");
}

/// Sets the text foreground color
pub fn setFg(io: std.Io, color: Color) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);

    try writer.interface.print("\x1b[{}m", .{@intFromEnum(color)});
    try writer.interface.flush();
}

/// Sets the text background color
pub fn setBg(io: std.Io, color: BgColor) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);

    try writer.interface.print("\x1b[{}m", .{@intFromEnum(color)});
    try writer.interface.flush();
}

/// Resets all colors and text formatting styles back to terminal defaults
pub fn resetStyle(io: std.Io) !void {
    var buf: [16]u8 = undefined;
    var writer = getStdout(io, &buf);

    try writer.interface.writeAll("\x1b[0m");
    try writer.interface.flush();
}

pub fn moveUp(io: std.Io, n: u16) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\x1b[{}A", .{n});
    try writer.interface.flush();
}

pub fn moveDown(io: std.Io, n: u16) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\x1b[{}B", .{n});
    try writer.interface.flush();
}

pub fn moveRight(io: std.Io, n: u16) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\x1b[{}C", .{n});
    try writer.interface.flush();
}

pub fn moveLeft(io: std.Io, n: u16) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\x1b[{}D", .{n});
    try writer.interface.flush();
}

/// Moves to the start of the line, then up N lines
pub fn moveLineUp(io: std.Io, n: u16) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\x1b[{}F", .{n});
    try writer.interface.flush();
}

pub fn returnToLineStart(io: std.Io) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\r");
    try writer.interface.flush();
}

pub fn putCursor(io: std.Io) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\x1b[s");
    try writer.interface.flush();
}

pub fn restoreCursor(io: std.Io) !void {
    var buf: [32]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print("\x1b[u");
    try writer.interface.flush();
}

pub fn clear(io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.writeAll("\x1b[2J\x1b[H");
    try writer.interface.flush();
}

pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [fmt.len + 128]u8 = undefined;
    var writer = getStdout(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

pub fn getStdout(io: std.Io, buffer: []u8) std.Io.File.Writer {
    const stdout = std.Io.File.stdout();
    return stdout.writer(io, buffer);
}
