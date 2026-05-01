const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello from native-xBEEF!\n", .{});
}

test "native-xBEEF basic test" {
    try std.testing.expect(true);
}
