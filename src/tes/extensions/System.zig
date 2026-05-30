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
            if (nxt == null) break;
            const next = cursor + nxt.?;

            const aftr = std.mem.find(u8, fmt[next..], "}");
            if (aftr == null) break;
            const after = next + aftr.?;

            // @{n}   → after - next == 3 (1 char between braces)
            // @{n:s} → after - next == 5 (3 chars between braces)
            const content_len = after - next - 2;
            if (content_len != 1 and content_len != 3) break;

            const reg_idx = parsePrintfReg(fmt[next + 2]) orelse break;

            var specifier: u8 = 0;
            if (content_len == 3) {
                if (fmt[next + 3] != ':') break;
                specifier = fmt[next + 4];
            }

            std.debug.print("{s}", .{fmt[cursor..next]});
            printfReg(vm, registers[reg_idx], specifier);
            cursor = after + 1;
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

fn parsePrintfReg(c: u8) ?u8 {
    if ('0' <= c and c <= '9') return c - '0';
    if ('a' <= c and c <= 'f') return 10 + (c - 'a');
    if ('A' <= c and c <= 'F') return 10 + (c - 'A');
    return null;
}

fn printfReg(vm: *tes.TESVM, val: u16, specifier: u8) void {
    switch (specifier) {
        0   => std.debug.print("{d}", .{@as(i16, @bitCast(val))}),
        'u' => std.debug.print("{d}", .{val}),
        'x' => std.debug.print("{x}", .{val}),
        'X' => std.debug.print("{X}", .{val}),
        'b' => std.debug.print("{b}", .{val}),
        'v' => {
            const lo: i8 = @bitCast(@as(u8, @truncate(val)));
            const hi: i8 = @bitCast(@as(u8, @truncate(val >> 8)));
            std.debug.print("({d}, {d})", .{ lo, hi });
        },
        'w' => {
            const lo: u8 = @truncate(val);
            const hi: u8 = @truncate(val >> 8);
            std.debug.print("({d}, {d})", .{ lo, hi });
        },
        's' => {
            if (vm.getPage(0)) |p0| {
                const offset: usize = val;
                if (offset < p0.len) {
                    const ptr: [*]const u8 = @ptrCast(&p0[offset]);
                    var slen: usize = 0;
                    while (offset + slen < p0.len and ptr[slen] != 0) slen += 1;
                    std.debug.print("{s}", .{ptr[0..slen]});
                }
            }
        },
        else => {},
    }
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
