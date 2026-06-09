const std = @import("std");

pub const console = @import("conio.zig");
pub const log = @import("log.zig");

pub fn begin(io: std.Io) void {
    console.begin(io) catch {};
}

pub fn end(io: std.Io) void {
    console.end(io) catch {};
}
