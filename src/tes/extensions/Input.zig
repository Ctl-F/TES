const native = @import("native");
const std = @import("std");
const tes = @import("tes_core").vm;

const mmMap = @import("mmioHeader.zig").MMMap;

pub const pool: tes.PoolID = 2;

const gfx = @import("Graphics.zig");

pub const ErrorCodes = enum(u8) {
    UnknownEventCode = 0,
    PollError = 1,
};

pub const EventCodes = enum(u15) {
    IOSync = 1,
    IOPoll = 2,
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
    return "I/O Controller";
}

fn getIOHeader(page: tes.PageBuffer) *mmMap.IOHeader {
    const mmPtr: *mmMap = @ptrCast(@alignCast(&page[0]));
    return &mmPtr.io;
}

fn handle(vm: *tes.TESVM, evCode: tes.EventID) tes.EventResult {
    switch (@as(EventCodes, @enumFromInt(evCode))) {
        .IOSync => {
            return .ok;
        },
        .IOPoll => {
            IOPoll(vm) catch {
                return .{
                    .fail = .{
                        .code = @intFromEnum(ErrorCodes.PollError),
                        .message = "Failed to poll inputs",
                        .panic = false,
                    },
                };
            };
            return .ok;
        },
        _ => {},
    }

    return .{
        .fail = .{
            .code = @intFromEnum(ErrorCodes.UnknownEventCode),
            .message = "Provided event code not recognized",
            .panic = true,
        },
    };
}

var closeSignal: u32 = 0;

pub fn IOPoll(vm: *tes.TESVM) !void {
    var event: native.SDL_Event = undefined;
    const page = vm.getPageMMIO();
    var header = getIOHeader(page);

    while (native.SDL_PollEvent(&event)) {
        switch (event.type) {
            native.SDL_EVENT_QUIT, native.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                header.closeSignal = 1;
                std.debug.print("Close Signal Sent\n", .{});

                closeSignal += 1;
                if (closeSignal > 7) {
                    vm.dumpContext();
                    @panic("Unhandled close signal");
                }
            },
            else => {},
        }
    }
}

fn crashDump(vm: *tes.TESVM) void {
    _ = vm;

    std.debug.print(
        \\ [ IO Controller Info ]
        \\ Info Not Available
        \\
    , .{});
}
