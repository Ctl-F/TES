const std = @import("std");
const instructions = @import("instructions.zig");

const OpCode = instructions.InstructionCode;
const Instruction = instructions.BasicInstruction;
const InstructionDst = instructions.InstructionDst;
const InstructionDstSrc = instructions.InstructionDstSrc;
const InstructionDstAddrSrc = instructions.InstructionDstAddrSrc;
const InstructionDstAddrXSrc = instructions.InstructionDstAddrXSrc;
const InstructionDstSrcAddr = instructions.InstructionDstSrcAddr;
const InstructionDstSrcAddrX = instructions.InstructionDstSrcAddrX;
const InstructionDst2Src2 = instructions.InstructionDst2Src2;
const InstructionDstSrc3 = instructions.InstructionDstSrc3;

pub const RegisterID = enum(u5) {
    R0 = 0,
    R1,
    R2,
    R3,
    R4,
    R5,
    R6,
    R7,
    R8,
    R9,
    RA,
    RB,
    RC,
    RD,
    RE,
    RF,
    SH,
    SB,
    SP,
    IP,
    FCL,
    FCH,
    GCL,
    GCH,
    REGISTER_COUNT_ENTRY,
};

pub const RegisterType = u16;
pub const RegisterIType = u16;
pub const InterruptID = u16;

const PageSize = std.math.maxInt(RegisterType);

pub const TESVM = struct {
    registers: [@intFromEnum(RegisterID.REGISTER_COUNT_ENTRY)]RegisterType = [_]RegisterType{0} ** @intFromEnum(RegisterID.REGISTER_COUNT_ENTRY),
    mmu: MMU = .{},
    instructionBuffer: []instructions.BasicInstruction,
};

pub const PagePermissions = packed struct(u8) {
    read: bool,
    write: bool,
    reserved: u6 = undefined,
};

pub const PageEntry = struct {
    permissions: PagePermissions,
    buffer: ?*[0xFFFF]u8,
};

pub const MMU = struct {
    pages: [256]PageEntry = [_]PageEntry{.{ .buffer = null, .permissions = .{ .read = true, .write = true } }} ** 256,
};

const Interrupt = error{
    Unknown,
    StackUnderflow,
    StackOverflow,
    PageFault,
    DivideByZero,
    InvalidInstruction,
};

const InstructionHandler = fn (*TESVM, Instruction) Interrupt!void;

inline fn InvalidHandler(_: *TESVM, _: Instruction) Interrupt!void {
    return Interrupt.InvalidInstruction;
}

const InstructionInfo = struct {
    handler: InstructionHandler,
    cycles: u8,
};

pub fn MovFactory(comptime instrType: type, comptime width: enum { full, half }, comptime postOp: enum { none, inc, dec }) InstructionInfo {
    const moveType = switch (width) {
        .full => u16,
        .half => u8,
    };

    const function = switch (instrType) {
        InstructionDstSrc => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstSrc = @bitCast(instr);
                vm.registers[decoded.dst] = vm.registers[decoded.src];
            }
        }.do,
        InstructionDstAddrSrc => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstAddrSrc = @bitCast(instr);

                const base: isize = @intCast(vm.registers[decoded.dPOR]);
                const offset: isize = @intCast(decoded.offset);

                // no need to check pageID fault since page0 always exists

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                std.mem.writeInt(moveType, vm.mmu.pages[0].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], vm.registers[decoded.src], .little);

                if (comptime postOp == .inc) {
                    vm.registers[decoded.dPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers[decoded.dPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDstAddrXSrc => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstAddrXSrc = @bitCast(instr);

                const base: isize = @intCast(vm.registers[decoded.dPOR]);
                const offset: isize = @intCast(decoded.offset);
                const pageID: u8 = @truncate(vm.registers[decoded.dPSR]);

                if (vm.mmu.pages[pageID].buffer == null) {
                    @branchHint(.unlikely);
                    // maybe separate this "unallocated page" vs "page fault"
                    // but for now page fault is the catch all
                    return Interrupt.PageFault;
                }

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                std.mem.writeInt(moveType, vm.mmu.pages[pageID].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], vm.registers[decoded.src], .little);

                if (comptime postOp == .inc) {
                    vm.registers[decoded.dPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers[decoded.dPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDstSrcAddr => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstSrcAddr = @bitCast(instr);

                const base: isize = @intCast(vm.registers[decoded.sPOR]);
                const offset: isize = @intCast(decoded.offset);

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                vm.registers[decoded.dst] = std.mem.readInt(moveType, vm.mmu.pages[0].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], .little);

                if (comptime postOp == .inc) {
                    vm.registers[decoded.sPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers[decoded.sPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDstSrcAddrX => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstSrcAddrX = @bitCast(instr);

                const pageID: u8 = @truncate(vm.registers[decoded.sPSR]);
                const base: isize = @intCast(vm.registers[decoded.sPOR]);
                const offset: isize = @intCast(decoded.offset);

                if (vm.mmu.pages[pageID].buffer == null) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                vm.registers[decoded.dst] = std.mem.readInt(moveType, vm.mmu.pages[pageID].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], .little);

                if (comptime postOp == .inc) {
                    vm.registers[decoded.sPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers[decoded.sPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDst => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDst = @bitCast(instr);
                vm.registers[decoded.dst] = @truncate(decoded.payload);
            }
        }.do,
        else => unreachable,
    };

    return .{ .handler = function, .cycles = 1 };
}

const InstructionTable = init: {
    var table = [_]InstructionInfo{.{ .handler = InvalidHandler, .cycles = 0 }} ** 256;

    table[@intFromEnum(OpCode.nop)] = .{ .handler = struct {
        pub inline fn do(_: *TESVM, _: Instruction) Interrupt!void {}
    }.do, .cycles = 1 };

    // basic mov
    table[@intFromEnum(OpCode.mov)] = MovFactory(InstructionDstSrc, .full, .none);
    table[@intFromEnum(OpCode.mov_c)] = MovFactory(InstructionDst, .full, .none);

    // mov to memory (simple addr)
    table[@intFromEnum(OpCode.mov_av)] = MovFactory(InstructionDstAddrSrc, .full, .none);
    table[@intFromEnum(OpCode.mov_ra)] = MovFactory(InstructionDstSrcAddr, .full, .none);
    table[@intFromEnum(OpCode.mov_aev)] = MovFactory(InstructionDstAddrXSrc, .full, .none);
    table[@intFromEnum(OpCode.mov_rae)] = MovFactory(InstructionDstSrcAddrX, .full, .none);

    // mov to memory (full addr)
    table[@intFromEnum(OpCode.mov_hav)] = MovFactory(InstructionDstAddrSrc, .half, .none);
    table[@intFromEnum(OpCode.mov_hra)] = MovFactory(InstructionDstSrcAddr, .half, .none);
    table[@intFromEnum(OpCode.mov_heav)] = MovFactory(InstructionDstAddrXSrc, .half, .none);
    table[@intFromEnum(OpCode.mov_hrae)] = MovFactory(InstructionDstSrcAddrX, .half, .none);

    // streaming mov
    table[@intFromEnum(OpCode.mov_aevi)] = MovFactory(InstructionDstAddrXSrc, .full, .inc);
    table[@intFromEnum(OpCode.mov_raei)] = MovFactory(InstructionDstSrcAddrX, .full, .inc);
    table[@intFromEnum(OpCode.mov_haevi)] = MovFactory(InstructionDstAddrXSrc, .half, .inc);
    table[@intFromEnum(OpCode.mov_hraei)] = MovFactory(InstructionDstSrcAddrX, .half, .inc);

    table[@intFromEnum(OpCode.mov_aevd)] = MovFactory(InstructionDstAddrXSrc, .full, .dec);
    table[@intFromEnum(OpCode.mov_raed)] = MovFactory(InstructionDstSrcAddrX, .full, .dec);
    table[@intFromEnum(OpCode.mov_haevd)] = MovFactory(InstructionDstAddrXSrc, .half, .dec);
    table[@intFromEnum(OpCode.mov_hraed)] = MovFactory(InstructionDstSrcAddrX, .half, .dec);

    // TODO: add the rest

    // validation
    for (@typeInfo(OpCode).@"enum".fields) |field| {
        if (table[field.value].handler == InvalidHandler) {
            @compileLog("Instruction " ++ field.name ++ " is missing a handler");
        }
    }

    break :init table;
};
