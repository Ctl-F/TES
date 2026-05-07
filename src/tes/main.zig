const std = @import("std");
const tes_core = @import("tes_core");
const builtin = @import("builtin");

pub fn main() !void {
    var vm: tes_core.vm.TESVM = try tes_core.vm.TESVM.defaultWithPageAllocator();
    defer vm.deinit();
    try vm.exec(1, false);
}

// Exported for web
export fn wasm_main() void {
    main() catch {};
}

test "native-tes basic test" {
    try std.testing.expect(true);
}
