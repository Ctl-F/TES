const std = @import("std");
const tes = @import("tes_core").vm;

pub const pool: tes.PoolID = 0;

pub const ErrorCodes = enum(u8) {
    UnknownEventCode = 0,
    DataPageNotFound = 1,
    PageBoundryException = 2,
    NonTerminatedString = 3,
};
pub const EventCodes = enum(u15) {
    Write = 0,
    Printf = 1,
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

fn crashDump(vm: *tes.TESVM) void {
    _ = vm;
    std.debug.print("System extension information not available\n", .{});
}

fn getFriendlyName() []const u8 {
    return "System";
}

//fn (vm: *TESVM, evCode: EventID) EventResult
fn handle(vm: *tes.TESVM, evCode: tes.EventID) tes.EventResult {
    switch (@as(EventCodes, @enumFromInt(evCode))) {
        .Write => {
            return write(vm);
        },
        .Printf => {
            return printf(vm);
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

fn printf(vm: *tes.TESVM) tes.EventResult {
    const registers = vm.registers.registers();
    const r0: usize = @intFromEnum(tes.RegisterID.R0);
    const r1: usize = @intFromEnum(tes.RegisterID.R1);

    const psr: u8 = @truncate(registers[r0]);
    const por = registers[r1];

    const page = vm.getPage(psr);
    if (page) |buf| {
        const ptr: [*]u8 = @ptrCast(&buf[por]);
        var end: usize = 0;
        while ((por + end) < buf.len) : (end += 1) {
            if (ptr[end] == 0) break;
        } else {
            return .{
                .fail = .{
                    .code = @intFromEnum(ErrorCodes.NonTerminatedString),
                    .panic = false,
                    .message = "Format string is not null terminated",
                },
            };
        }

        const fmt = ptr[0..end];
        var cursor: usize = 0;

        while (true) {
            const nxt = std.mem.find(u8, fmt[cursor..], "@{");
            if (nxt == null) {
                break;
            }
            const next = cursor + nxt.?;

            const aftr = std.mem.find(u8, fmt[next..], "}");
            if (aftr == null) {
                break;
            }
            const after = next + aftr.?;

            // @{X} is 4 chars: '@'=next+0, '{'=next+1, 'X'=next+2, '}'=next+3
            if (after - next != 3) {
                break;
            }

            std.debug.print("{s}", .{fmt[cursor..next]});

            const indexChar = fmt[next + 2];

            if ('0' <= indexChar and indexChar <= '9') {
                const index = indexChar - '0';
                std.debug.print("{}", .{registers[index]});
                cursor = after + 1;
                continue;
            }

            if ('a' <= indexChar and indexChar <= 'f') {
                const index = 10 + (indexChar - 'a');
                std.debug.print("{}", .{registers[index]});
                cursor = after + 1;
                continue;
            }

            if ('A' <= indexChar and indexChar <= 'F') {
                const index = 10 + (indexChar - 'A');
                std.debug.print("{}", .{registers[index]});
                cursor = after + 1;
                continue;
            }

            break;
        }

        std.debug.print("{s}", .{fmt[cursor..]});
        return .ok;
    }

    return .{
        .fail = .{
            .code = @intFromEnum(ErrorCodes.DataPageNotFound),
            .message = "Page does not exist",
            .panic = false,
        },
    };
}

fn write(vm: *tes.TESVM) tes.EventResult {
    const registers = vm.registers.registers();
    const r0: usize = @intFromEnum(tes.RegisterID.R0);
    const r1: usize = @intFromEnum(tes.RegisterID.R1);
    const r2: usize = @intFromEnum(tes.RegisterID.R2);

    const psr: u8 = @truncate(registers[r0]);
    const por = registers[r1];
    const len = registers[r2];

    const page = vm.getPage(psr);

    if (page) |buf| {
        const eof = por + len;
        if (eof > buf.len) {
            return .{
                .fail = .{
                    .code = @intFromEnum(ErrorCodes.PageBoundryException),
                    .message = "Data provided leaves the page boundry",
                    .panic = false,
                },
            };
        }

        const str = buf[por..eof];
        std.debug.print("{s}", .{str});
        return .ok;
    }

    return .{
        .fail = .{
            .code = @intFromEnum(ErrorCodes.DataPageNotFound),
            .message = "Page does not exist",
            .panic = false,
        },
    };
}
