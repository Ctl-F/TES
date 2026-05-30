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

const sep = "+" ++ "-" ** 78 ++ "+";

fn report() void {
    printSection("Continuous", &continuousSlots);
    std.debug.print("\n", .{});
    printSection("Stopwatch", &stopwatchSlots);
}

fn printSection(title: []const u8, slots: []const Slot) void {
    std.debug.print("{s}\n", .{sep});
    std.debug.print("|{s: ^78}|\n", .{title});
    std.debug.print("{s}\n", .{sep});
    for (slots, 0..) |slot, idx| {
        if (slot.hit == 0) continue;
        const avg = slot.total_elapsed / slot.hit;
        printSlot(idx, slot.total_elapsed, avg, slot.min, slot.max, slot.hit);
        std.debug.print("{s}\n", .{sep});
    }
}

fn printSlot(idx: usize, total: u64, avg: u64, min: u64, max: u64, hits: u64) void {
    var buf: [78]u8 = undefined;
    var s = std.fmt.bufPrint(&buf, " {d:0>3}: Total  {d}", .{ idx, total }) catch buf[0..];
    std.debug.print("|{s: <78}|\n", .{s});
    s = std.fmt.bufPrint(&buf, "        Avg  {d}", .{avg}) catch buf[0..];
    std.debug.print("|{s: <78}|\n", .{s});
    s = std.fmt.bufPrint(&buf, "        Min  {d}", .{min}) catch buf[0..];
    std.debug.print("|{s: <78}|\n", .{s});
    s = std.fmt.bufPrint(&buf, "        Max  {d}", .{max}) catch buf[0..];
    std.debug.print("|{s: <78}|\n", .{s});
    s = std.fmt.bufPrint(&buf, "       Hits  {d}", .{hits}) catch buf[0..];
    std.debug.print("|{s: <78}|\n", .{s});
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

    if (comptime stopwatch) {
        if (slot.timestamp != null) {
            slot.hit += 1;
        }
    } else {
        slot.hit += 1;
    }
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
