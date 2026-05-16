const std = @import("std");
const tes = @import("tes_core").vm;

pub const pool: tes.PoolID = 0;

pub const ErrorCodes = enum(u8) {
    UnknownEventCode = 0,
    DataPageNotFound = 1,
    PageBoundryException = 2,
};
pub const EventCodes = enum(u15) {
    Write = 0,
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
