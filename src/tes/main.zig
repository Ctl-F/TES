const std = @import("std");
const tes_core = @import("tes_core");
const builtin = @import("builtin");

pub fn main() !void {
    const vm: tes_core.vm.TESVM = undefined;
    _ = vm;
}

// Exported for web
export fn wasm_main() void {
    main() catch {};
}

test "native-tes basic test" {
    try std.testing.expect(true);
}
