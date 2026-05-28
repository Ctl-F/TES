const std = @import("std");
const tes = @import("tes_core").vm;

pub const pool: tes.PoolID = 3;

pub const ErrorCodes = enum(u8) {
    UnknownEventCode = 0,
};

pub const EventCodes = enum(u15) {
    Report = 512,
    _,
};

pub fn extension(enable: bool) tes.Extension {
    return .{
        .enabled = enable,
        .getFriendlyName = getFriendlyName,
        .crashDump = crashDump,
        .handler = handle,
    };
}

fn getFriendlyName() []const u8 {
    return "Tracer";
}
fn crashDump(_: *tes.TESVM) void {
    report();
}

fn report() void {
    std.debug.print("Trace Results:\n", .{});
    std.debug.print("=" ** 80, .{});
    std.debug.print("\n", .{});
    std.debug.print(("-" ** 30) ++ "[ Continuous ]" ++ ("-" ** 30), .{});
    std.debug.print("\n", .{});

    for (continuousSlots, 0..) |slot, idx| {
        if (slot.hit == 0) continue;
        const avg = slot.total_elapsed / slot.hit;

        std.debug.print("{: >3}: Total {}\n" ++
            "          Avg {}\n" ++
            "          Min {}\n" ++
            "          Max {}\n" ++
            "         Hits {}\n", .{
            idx,
            slot.total_elapsed,
            avg,
            slot.min,
            slot.max,
            slot.hit,
        });
    }

    std.debug.print("=" ** 80, .{});
    std.debug.print("\n", .{});
    std.debug.print(("-" ** 30) ++ "[ Stopwatch ]" ++ ("-" ** 30), .{});
    std.debug.print("\n", .{});

    for (stopwatchSlots, 0..) |slot, idx| {
        if (slot.hit == 0) continue;
        const avg = slot.total_elapsed / slot.hit;

        std.debug.print("{: >3}: Total {}\n" ++
            "          Avg {}\n" ++
            "          Min {}\n" ++
            "          Max {}\n" ++
            "         Hits {}\n", .{
            idx,
            slot.total_elapsed,
            avg,
            slot.min,
            slot.max,
            slot.hit,
        });
    }

    std.debug.print("=" ** 80, .{});
    std.debug.print("\n", .{});
}

const Slot = struct {
    total_elapsed: u64 = 0,
    hit: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    timestamp: ?u64 = null,
};
var continuousSlots: [256]Slot = [_]Slot{.{}} ** 256;
var stopwatchSlots: [256]Slot = [_]Slot{.{}} ** 256;

fn log(vm: *tes.TESVM, slotIdx: u15, comptime stopwatch: bool) tes.EventResult {
    const index: u8 = @truncate(slotIdx);

    const slot: *Slot = if (comptime stopwatch)
        &stopwatchSlots[index]
    else
        &continuousSlots[index];

    const counter: u64 = vm.registers.doubleRegisters()[
        tes.TESVM.doubleRegIndex(.GCL)
    ];

    slot.hit += 1;

    if (slot.timestamp == null) {
        slot.timestamp = counter;
        return .ok;
    }

    const elapsed = counter -% slot.timestamp.?;
    slot.timestamp = if (comptime stopwatch) null else counter;

    slot.total_elapsed += elapsed;
    slot.min = @min(slot.min, elapsed);
    slot.max = @max(slot.max, elapsed);

    return .ok;
}

fn handle(vm: *tes.TESVM, evCode: tes.EventID) tes.EventResult {
    switch (evCode) {
        0...255 => |code| return log(vm, code, false),
        256...511 => |code| return log(vm, code, true),
        @intFromEnum(EventCodes.Report) => {
            report();
            return .ok;
        },
        else => {},
    }
    return .{
        .fail = .{
            .code = @intFromEnum(ErrorCodes.UnknownEventCode),
            .message = "Provided event code not recognized",
            .panic = true,
        },
    };
}
