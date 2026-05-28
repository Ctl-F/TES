const native = @import("native");
const std = @import("std");
const tes = @import("tes_core").vm;

const mmMap = @import("mmioHeader.zig").MMMap;

pub const pool: tes.PoolID = 2;

const gfx = @import("Graphics.zig");

pub const ErrorCodes = enum(u8) {
    UnknownEventCode = 0,
    PollError = 1,
    SyncError = 2,
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

const ButtonEvent = struct {
    buttonID: u8,
    state: enum(u8) { pushed = 1, released = 0 },
};

const ControllerInputMapFn = *const fn (ev: native.SDL_Event) ?ButtonEvent;
const ControllerMappers: [4]ControllerInputMapFn = .{
    MapController0,
    MapController1,
    MapController2,
    MapController3,
};

fn MapController0(ev: native.SDL_Event) ?ButtonEvent {
    if (ev.type != native.SDL_EVENT_KEY_DOWN and ev.type != native.SDL_EVENT_KEY_UP) {
        return null;
    }
    const keyboardEvent = ev.key;

    const key: ?u8 = switch (keyboardEvent.scancode) {
        native.SDL_SCANCODE_W => mmMap.IO_CONTROLLER_UP,
        native.SDL_SCANCODE_A => mmMap.IO_CONTROLLER_LEFT,
        native.SDL_SCANCODE_S => mmMap.IO_CONTROLLER_DOWN,
        native.SDL_SCANCODE_D => mmMap.IO_CONTROLLER_RIGHT,
        native.SDL_SCANCODE_J => mmMap.IO_CONTROLLER_BTN0,
        native.SDL_SCANCODE_K => mmMap.IO_CONTROLLER_BTN1,
        native.SDL_SCANCODE_L => mmMap.IO_CONTROLLER_BTN2,
        native.SDL_SCANCODE_I => mmMap.IO_CONTROLLER_BTN3,
        native.SDL_SCANCODE_LSHIFT => mmMap.IO_CONTROLLER_ALT,
        native.SDL_SCANCODE_ESCAPE => mmMap.IO_CONTROLLER_MENU,
        native.SDL_SCANCODE_F => mmMap.IO_CONTROLLER_START,
        else => null,
    };

    if (key) |conButId| {
        return .{
            .buttonID = conButId,
            .state = if (keyboardEvent.down) .pushed else .released,
        };
    }

    return null;
}

fn MapController1(_: native.SDL_Event) ?ButtonEvent {
    return null;
}
fn MapController2(_: native.SDL_Event) ?ButtonEvent {
    return null;
}
fn MapController3(_: native.SDL_Event) ?ButtonEvent {
    return null;
}

const InputSource = union(enum) {
    disabled,
    controller: ControllerSource,
    cursor: CursorSource,
    text: TextSource,

    fn handleEvent(this: *@This(), event: native.SDL_Event) void {
        switch (this.*) {
            .disabled => {},
            .controller => |*con| con.handleEvent(event),
            .cursor => |*cur| cur.handleEvent(event),
            .text => |*txt| txt.handleEvent(event),
        }
    }

    const ControllerSource = struct {
        buffer: *mmMap.IOBufferControllerSource,
        mapper: ControllerInputMapFn,

        fn handleEvent(this: *@This(), event: native.SDL_Event) void {
            const ev = this.mapper(event);
            if (ev) |e| {
                const addr: *u8 = switch (e.buttonID) {
                    mmMap.IO_CONTROLLER_BTN0 => &this.buffer.sBtn0,
                    mmMap.IO_CONTROLLER_BTN1 => &this.buffer.sBtn1,
                    mmMap.IO_CONTROLLER_BTN2 => &this.buffer.sBtn2,
                    mmMap.IO_CONTROLLER_BTN3 => &this.buffer.sBtn3,
                    mmMap.IO_CONTROLLER_LEFT => &this.buffer.sLeft,
                    mmMap.IO_CONTROLLER_RIGHT => &this.buffer.sRight,
                    mmMap.IO_CONTROLLER_UP => &this.buffer.sUp,
                    mmMap.IO_CONTROLLER_DOWN => &this.buffer.sDown,
                    mmMap.IO_CONTROLLER_ALT => &this.buffer.sAlt,
                    mmMap.IO_CONTROLLER_MENU => &this.buffer.sMenu,
                    mmMap.IO_CONTROLLER_START => &this.buffer.sStart,
                    else => unreachable,
                };

                addr.* = @as(u8, @intFromEnum(e.state));
            }
        }
    };
    const CursorSource = struct {
        buffer: *mmMap.IOBufferCursorSource,

        fn handleEvent(_: *@This(), _: native.SDL_Event) void {}
    };
    const TextSource = struct {
        buffer: *mmMap.IOBufferTextSource,

        fn handleEvent(_: *@This(), _: native.SDL_Event) void {}
    };
};

const Context = struct {
    inputs: [4]InputSource = [_]InputSource{.disabled} ** 4,
};
var singleton: Context = .{};

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
            IOSync(vm) catch {
                return .{
                    .fail = .{
                        .code = @intFromEnum(ErrorCodes.SyncError),
                        .message = "Failed to sync input controller",
                        .panic = false,
                    },
                };
            };

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

pub fn IOSync(vm: *tes.TESVM) !void {
    const header = getIOHeader(vm.getPageMMIO());

    for (header.sources, 0..) |source, idx| {
        if (source.source == mmMap.IO_SOURCE_DISABLED) {
            singleton.inputs[idx] = .disabled;
            return;
        }

        if (source.source == mmMap.IO_SOURCE_CONTROLLER_0 or
            source.source == mmMap.IO_SOURCE_CONTROLLER_1 or
            source.source == mmMap.IO_SOURCE_CONTROLLER_2 or
            source.source == mmMap.IO_SOURCE_CONTROLLER_3)
        {
            const mappingIndex = source.source - mmMap.IO_SOURCE_CONTROLLER_0;
            std.debug.assert(mappingIndex < ControllerMappers.len);

            const page: u8 = @truncate(source.bufferHigh);
            const offset: u16 = source.bufferLow;

            const buffer = if (vm.getPage(page)) |nnp| BLK: {
                break :BLK @as(*mmMap.IOBufferControllerSource, @ptrCast(@alignCast(&nnp[offset])));
            } else return error.PageDoesNotExist;

            singleton.inputs[idx] = InputSource{
                .controller = .{
                    .mapper = ControllerMappers[mappingIndex],
                    .buffer = buffer,
                },
            };

            return;
        }

        if (source.source == mmMap.IO_SOURCE_CURSOR) {
            const page: u8 = @truncate(source.bufferHigh);
            const offset: u16 = source.bufferLow;

            const buffer = if (vm.getPage(page)) |nnp| BLK: {
                break :BLK @as(*mmMap.IOBufferCursorSource, @ptrCast(@alignCast(&nnp[offset])));
            } else return error.PageDoesNotExist;

            singleton.inputs[idx] = InputSource{
                .cursor = .{
                    .buffer = buffer,
                },
            };
            return;
        }

        if (source.source == mmMap.IO_SOURCE_TEXT) {
            const page: u8 = @truncate(source.bufferHigh);
            const offset: u16 = source.bufferLow;

            const buffer = if (vm.getPage(page)) |nnp| BLK: {
                break :BLK @as(*mmMap.IOBufferTextSource, @ptrCast(@alignCast(&nnp[offset])));
            } else return error.PageDoesNotExist;

            singleton.inputs[idx] = InputSource{
                .text = .{
                    .buffer = buffer,
                },
            };

            return;
        }

        unreachable;
    }
}

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
            else => {
                for (&singleton.inputs) |*input| {
                    input.handleEvent(event);
                }
            },
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
