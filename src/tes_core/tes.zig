const std = @import("std");
const builtin = @import("builtin");

pub const vm = @import("vm.zig");

extern fn print(ptr: [*]const u8, len: usize) void;

pub fn hello() void {
    const msg = "Hello World\n";
    if (builtin.target.os.tag == .freestanding) {
        print(msg.ptr, msg.len);
    } else {
        std.debug.print("{s}", .{msg});
    }
}

test "tes_core basic test" {
    try std.testing.expect(true);
}
