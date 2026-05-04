const std = @import("std");
const instructions = @import("instructions.zig");

const OpCode = instructions.InstructionCode;
const Instruction = instructions.Instruction;
const InstructionDst = instructions.InstructionDst;
const InstructionDstSrc = instructions.InstructionDstSrc;
const InstructionDstAddrSrc = instructions.InstructionDstAddrSrc;
const InstructionDstAddrXSrc = instructions.InstructionDstAddrXSrc;
const InstructionDstSrcAddr = instructions.InstructionDstSrcAddr;
const InstructionDstSrcAddrX = instructions.InstructionDstSrcAddrX;
const InstructionDst2Src2 = instructions.InstructionDst2Src2;
const InstructionDstSrc2 = instructions.InstructionDstSrc2;
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
    instructionBuffer: []Instruction,
    halted: bool = false,
    // TODO: add interrupt table

    pub fn tickClock(this: *@This(), cycles: u8) void {
        var localCycle: u32 = (@as(u32, @intCast(this.registers[@intFromEnum(RegisterID.FCH)])) << 16) | this.registers[@intFromEnum(RegisterID.FCL)];
        var globalCycle: u32 = (@as(u32, @intCast(this.registers[@intFromEnum(RegisterID.GCH)])) << 16) | this.registers[@intFromEnum(RegisterID.GCL)];

        localCycle +%= cycles;
        globalCycle +%= cycles;

        this.registers[@intFromEnum(RegisterID.FCH)] = @truncate(localCycle >> 16);
        this.registers[@intFromEnum(RegisterID.FCL)] = @truncate(localCycle);
        this.registers[@intFromEnum(RegisterID.GCH)] = @truncate(globalCycle >> 16);
        this.registers[@intFromEnum(RegisterID.GCL)] = @truncate(globalCycle);
    }

    pub fn exec(this: *@This(), cycles: u32) !void {
        @setRuntimeSafety(false);

        if (this.registers[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
            @branchHint(.unlikely);
            return error.AbruptProgramEOF;
        }
        var instruction = this.instructionBuffer[this.registers[@intFromEnum(RegisterID.IP)]];
        DISPATCH: switch (instruction.opcode) {
            .Hlt => {
                this.halted = true;
                return;
            },
            .B => {
                const decoded: InstructionDst = @bitCast(instruction);

                this.registers[@intFromEnum(RegisterID.IP)] += 1;

                this.registers[@intFromEnum(RegisterID.JR)] = this.registers[@intFromEnum(RegisterID.IP)];
                this.registers[@intFromEnum(RegisterID.IP)] = this.registers[decoded.dst];
                this.tickClock(1);
                cycles -= 1;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }

                if (this.registers[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }

                instruction = this.instructionBuffer[this.registers[@intFromEnum(RegisterID.IP)]];
                continue :DISPATCH instruction.opcode;
            },
            .Bt => {
                const decoded: InstructionDstSrc = @bitCast(instruction);

                this.registers[@intFromEnum(RegisterID.IP)] += 1;
                if (this.registers[decoded.src] != 0) {
                    this.registers[@intFromEnum(RegisterID.JR)] = this.registers[@intFromEnum(RegisterID.IP)];
                    this.registers[@intFromEnum(RegisterID.IP)] = this.registers[decoded.dst];
                }

                this.tickClock(1);
                cycles -= 1;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }

                if (this.registers[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }

                instruction = this.instructionBuffer[this.registers[@intFromEnum(RegisterID.IP)]];
                continue :DISPATCH instruction.opcode;
            },
            .Bf => {
                const decoded: InstructionDstSrc = @bitCast(instruction);

                this.registers[@intFromEnum(RegisterID.IP)] += 1;
                if (this.registers[decoded.src] == 0) {
                    this.registers[@intFromEnum(RegisterID.JR)] = this.registers[@intFromEnum(RegisterID.IP)];
                    this.registers[@intFromEnum(RegisterID.IP)] = this.registers[decoded.dst];
                }

                this.tickClock(1);
                cycles -= 1;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }
                if (this.registers[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }
                instruction = this.instructionBuffer[this.registers[@intFromEnum(RegisterID.IP)]];
                continue :DISPATCH instruction.opcode;
            },
            inline else => |op| {
                const consumed = InstructionTable[op].cycles;
                InstructionTable[op].handler(this, instruction) catch {
                    // TODO: handle Interrupt
                };

                this.registers[@intFromEnum(RegisterID.IP)] += 1;

                this.tickClock(consumed);

                cycles = if (consumed > cycles) 0 else cycles - consumed;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }
                if (this.registers[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }
                instruction = this.instructionBuffer[this.registers[@intFromEnum(RegisterID.IP)]];

                continue :DISPATCH instruction.opcode;
            },
        }
    }
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
    pages: [256]PageEntry = [_]PageEntry{.{ .buffer = null, .permissions = .{ .read = false, .write = false } }} ** 256,
};

const Interrupt = error{
    Unknown,
    StackUnderflow,
    StackOverflow,
    PageFault,
    DivideByZero,
    SignedDivisionOverflow,
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

fn MovFactory(comptime instrType: type, comptime width: enum { full, half }, comptime postOp: enum { none, inc, dec }) InstructionInfo {
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

const ScalarOp = enum {
    add,
    sub,
    mul,
    shr,
    shl,
    bin_add, // Assuming you meant bin_and
    bin_or,
    bin_xor,
    bin_not,
    log_and,
    log_or,
    log_not,
    neg,
    inc,
    dec,
    rol,
    ror,
    sar,
    min,
    max,
    abs,
    sign,
    iadd,
    isub,
    imul,
    idiv,
    extz,
    exts,
    truncz,
    clamp,
    fma,

    seteq,
    setneq,
    setlt,
    setle,
    setgt,
    setge,
    isetlt,
    isetle,
    isetgt,
    isetge,
};
fn ScalarFactory(comptime op: ScalarOp) InstructionInfo {
    const function, const cost = switch (op) {
        // --- Binary Math ---
        .add => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] +%= vm.registers[de.src];
            }
        }.do, 1 },
        .sub => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] -%= vm.registers[de.src];
            }
        }.do, 1 },
        .mul => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] *%= vm.registers[de.src];
            }
        }.do, 1 },
        .div => .{
            struct {
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst2Src2 = @bitCast(i);
                    // div q, r, d, v ==> q = d / v : r = d % v
                    const q = de.dst0;
                    const r = de.dst1;
                    const d = de.src0;
                    const v = de.src1;

                    if (vm.registers[v] == 0) return Interrupt.DivideByZero;

                    vm.registers[q] = vm.registers[d] / vm.registers[v];
                    vm.registers[r] = vm.registers[d] % vm.registers[v];
                }
            }.do,
            8,
        },
        // --- Shifts ---
        .shr => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] >>= @truncate(vm.registers[de.src]);
            }
        }.do, 1 },
        .shl => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] <<= @truncate(vm.registers[de.src]);
            }
        }.do, 1 },
        .sar => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const val: i16 = @bitCast(vm.registers[de.dst]);
                const shift: u4 = @truncate(vm.registerse[de.src]);
                vm.registers[de.dst] = @bitCast(val >> shift);
            }
        }.do, 1 },

        // --- Bitwise ---
        .bin_add => .{
            struct { // Treated as bitwise AND per common naming conventions
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDstSrc = @bitCast(i);
                    vm.registers[de.dst] &= vm.registers[de.src];
                }
            }.do,
            1,
        },
        .bin_or => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] |= vm.registers[de.src];
            }
        }.do, 1 },
        .bin_xor => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] ^= vm.registers[de.src];
            }
        }.do, 1 },

        // --- Logical ---
        .log_and => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const res = (vm.registers[de.dst] != 0) and (vm.registers[de.src] != 0);
                vm.registers[de.dst] = if (res) 1 else 0;
            }
        }.do, 1 },
        .log_or => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const res = (vm.registers[de.dst] != 0) or (vm.registers[de.src] != 0);
                vm.registers[de.dst] = if (res) 1 else 0;
            }
        }.do, 1 },

        // --- Unary (using InstructionDst) ---
        .bin_not => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers[de.dst] = ~vm.registers[de.dst];
            }
        }.do, 1 },
        .log_not => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers[de.dst] = if (vm.registers[de.dst] == 0) 1 else 0;
            }
        }.do, 1 },
        .neg => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers[de.dst] = -%vm.registers[de.dst];
            }
        }.do, 1 },
        .inc => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers[de.dst] +%= 1;
            }
        }.do, 1 },
        .dec => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers[de.dst] -%= 1;
            }
        }.do, 1 },
        // --- Rotates ---
        .rol => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] = std.math.rotl(u16, vm.registers[de.dst], @truncate(vm.registers[de.src]));
            }
        }.do, 1 },
        .ror => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] = std.math.rotr(u16, vm.registers[de.dst], @truncate(vm.registers[de.src]));
            }
        }.do, 1 },

        // --- Min/Max/Abs/Sign ---
        .min => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] = @min(vm.registers[de.dst], vm.registers[de.src]);
            }
        }.do, 1 },
        .max => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers[de.dst] = @max(vm.registers[de.dst], vm.registers[de.src]);
            }
        }.do, 1 },
        .abs => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                const val: i16 = @bitCast(vm.registers[de.dst]);
                vm.registers[de.dst] = @bitCast(if (val < 0) -%val else val);
            }
        }.do, 1 },
        .sign => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                const val: i16 = @bitCast(vm.registers[de.dst]);
                vm.registers[de.dst] = if (val > 0) @as(u16, 1) else if (val < 0) @as(u16, 0xFFFF) else 0;
            }
        }.do, 1 },

        // --- Signed Arithmetic ---
        .iadd => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const a: i16 = @bitCast(vm.registers[de.dst]);
                const b: i16 = @bitCast(vm.registers[de.src]);
                vm.registers[de.dst] = @bitCast(a +% b);
            }
        }.do, 1 },
        .isub => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const a: i16 = @bitCast(vm.registers[de.dst]);
                const b: i16 = @bitCast(vm.registers[de.src]);
                vm.registers[de.dst] = @bitCast(a -% b);
            }
        }.do, 1 },
        .imul => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const a: i16 = @bitCast(vm.registers[de.dst]);
                const b: i16 = @bitCast(vm.registers[de.src]);
                vm.registers[de.dst] = @bitCast(a *% b);
            }
        }.do, 1 },
        .idiv => .{
            struct {
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst2Src2 = @bitCast(i);
                    // div q, r, d, v ==> q = d / v : r = d % v
                    const q: u16 = de.dst0;
                    const r: u16 = de.dst1;
                    const d: i16 = @bitCast(vm.registers[de.src0]);
                    const v: i16 = @bitCast(vm.registers[de.src1]);

                    if (v == 0) {
                        @branchHint(.unlikely);
                        return Interrupt.DivideByZero;
                    }
                    if (d == std.math.minInt(i16) and v == -1) {
                        @branchHint(.unlikely);
                        return Interrupt.SignedDivisionOverflow;
                    }

                    vm.registers[q] = @bitCast(@divTrunc(d, v));
                    vm.registers[r] = @bitCast(@rem(d, v));
                }
            }.do,
            8,
        },
        // --- Extensions & Conversions ---
        .extz => .{
            struct { // Zero extend lower 8 bits
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    vm.registers[de.dst] = vm.registers[de.dst] & 0x00FF;
                }
            }.do,
            1,
        },
        .exts => .{
            struct { // Sign extend lower 8 bits
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    const low: i8 = @truncate(@as(u16, vm.registers[de.dst]));
                    vm.registers[de.dst] = @bitCast(@as(i16, low));
                }
            }.do,
            1,
        },
        .truncz => .{
            struct { // Truncate to lower 8 bits
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    vm.registers[de.dst] = @as(u8, @truncate(vm.registers[de.dst]));
                }
            }.do,
            1,
        },
        .clamp => .{
            struct { // Saturate 16-bit to 8-bit range (0-255)
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    vm.registers[de.dst] = @min(vm.registers[de.dst], 255);
                }
            }.do,
            1,
        },

        // --- Ternary Math ---
        .fma => .{
            struct { // (A * B) + C
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDstSrc2 = @bitCast(i);
                    const prod = vm.registers[de.src0] *% vm.registers[de.src1];
                    vm.registers[de.dst] +%= prod;
                }
            }.do,
            1,
        },

        // set* family
        .seteq => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (vm.registers[de.src0] == vm.registers[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setneq => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (vm.registers[de.src0] != vm.registers[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setlt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (vm.registers[de.src0] < vm.registers[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setle => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (vm.registers[de.src0] <= vm.registers[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setgt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (vm.registers[de.src0] > vm.registers[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setge => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (vm.registers[de.src0] >= vm.registers[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .isetlt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (@as(i16, @bitCast(vm.registers[de.src0])) < @as(i16, @bitCast(vm.registers[de.src1]))) 1 else 0;
            }
        }.do, 1 },
        .isetle => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (@as(i16, @bitCast(vm.registers[de.src0])) <= @as(i16, @bitCast(vm.registers[de.src1]))) 1 else 0;
            }
        }.do, 1 },
        .isetgt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (@as(i16, @bitCast(vm.registers[de.src0])) > @as(i16, @bitCast(vm.registers[de.src1]))) 1 else 0;
            }
        }.do, 1 },
        .isetge => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers[de.dst] = if (@as(i16, @bitCast(vm.registers[de.src0])) >= @as(i16, @bitCast(vm.registers[de.src1]))) 1 else 0;
            }
        }.do, 1 },
    };

    return InstructionInfo{ .handler = function, .cycles = cost };
}

const VectorOp = enum {
    vadd2,
    vsub2,
    vmul2,
    vshr2,
    vshl2,
    vand2,
    vor2,
    vxor2,
    vnot2,
    vneg2,
    vseteq2,
    vsetne2,
    vsetlt2,
    vsetle2,
    vsetgt2,
    vsetge2,
    vreduce2,
    vsplat2,
    vldc2,
    viadd2,
    visub2,
    vimul2,
    visetlt2,
    visetle2,
    visetgt2,
    visetge2,
    vselect2,
    vswap2,
    vsar2,
    vabs2,
    vsign2,
    vmin2,
    vmax2,
    vrol2,
    vror2,
};
fn VectorFactory(comptime op: VectorOp) InstructionInfo {
    const handler = if (comptime op == .vswap2) a: {
        break :a struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers[de.dst] = @byteSwap(vm.registers[de.dst]);
            }
        }.do;
    } else if (comptime op == .vselect2) b: {
        break :b struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc3 = @bitCast(i);

                const va: @Vector(2, u8) = @bitCast(vm.registers[de.src0]);
                const vb: @Vector(2, u8) = @bitCast(vm.registers[de.src1]);

                const mask = vm.registers[de.src2];
                const vMask = @Vector(2, bool){ mask & 0x00FF != 0, mask & 0xFF00 != 0 };

                const vr = @select(u8, vMask, va, vb);

                vm.registers[de.dst] = @bitCast(vr);
            }
        }.do;
    } else if (comptime op == .vreduce2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDstSrc = @bitCast(i);

            const va: @Vector(2, u8) = @bitCast(vm.registers[de.src]);

            vm.registers[de.dst] = @intCast(switch (@as(instructions.ReduceCode, @enumFromInt(@as(u8, @truncate(de.payload))))) {
                .Add => @reduce(.Add, va),
                .Sub => @reduce(.Sub, va),
                .Mul => @reduce(.Mul, va),
                .BitAnd => @reduce(.And, va),
                .BitOr => @reduce(.Or, va),
                .BitXor => @reduce(.Xor, va),
                .Min => @reduce(.Min, va),
                .Max => @reduce(.Max, va),
                .And => a: {
                    const bool0 = va[0] != 0;
                    const bool1 = va[1] != 0;
                    break :a if (bool0 and bool1) 1 else 0;
                },
                .Or => a: {
                    const bool0 = va[0] != 0;
                    const bool1 = va[1] != 0;
                    break :a if (bool0 or bool1) 1 else 0;
                },
            });
        }
    }.do else if (comptime op == .vsplat2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDst = @bitCast(i);
            const immediate: u8 = @truncate(de.payload);
            vm.registers[de.dst] = (@as(u16, @intCast(immediate)) << 8) | immediate;
        }
    }.do else if (comptime op == .vldc2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDst = @bitCast(i);
            vm.registers[de.dst] = @truncate(de.payload);
        }
    }.do else if (comptime op == .vnot2 or op == .vneg2 or op == .vabs2 or op == .vsign2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDst = @bitCast(i);
            const v: @Vector(2, u8) = @bitCast(vm.registers[de.dst]);
            vm.registers[de.dst] = @bitCast(switch (op) {
                .vnot2 => ~v,
                .vneg2 => -%@as(@Vector(2, i8), @bitCast(v)),
                .vabs2 => a: {
                    const sv: @Vector(2, i8) = @bitCast(v);
                    break :a @abs(sv);
                },
                .vsign2 => a: {
                    const sv: @Vector(2, i8) = @bitCast(v);
                    const pos = @as(@Vector(2, i8), @bitCast(sv > @as(@Vector(2, i8), @splat(@as(i8, 0)))));
                    const neg = @as(@Vector(2, i8), @bitCast(sv < @as(@Vector(2, i8), @splat(@as(i8, 0)))));
                    break :a @as(@Vector(2, u8), @bitCast(pos -% neg));
                },
                else => unreachable,
            });
        }
    }.do else if (comptime op == .vshl2 or op == .vshr2 or op == .vsar2 or op == .vrol2 or op == .vror2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDstSrc = @bitCast(i);
            const v: @Vector(2, u8) = @bitCast(vm.registers[de.dst]);
            const amount: u3 = @truncate(vm.registers[de.src]); // Shift amount usually 0..7
            const s: @Vector(2, u3) = @splat(amount);

            vm.registers[de.dst] = @bitCast(switch (op) {
                .vshl2 => v << s,
                .vshr2 => v >> s,
                .vsar2 => @as(@Vector(2, u8), @bitCast(@as(@Vector(2, i8), @bitCast(v)) >> s)),
                .vrol2 => std.math.rotl(@Vector(2, u8), v, s),
                .vror2 => std.math.rotr(@Vector(2, u8), v, s),
                else => unreachable,
            });
        }
    }.do else c: {
        const vectorFn = fn (@Vector(2, u8), @Vector(2, u8)) @Vector(2, u8);

        const whichFn: vectorFn = switch (op) {
            // Unsigned Math
            .vadd2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return a +% b;
                }
            }.f,
            .vsub2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return a -% b;
                }
            }.f,
            .vmul2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return a *% b;
                }
            }.f,
            .vmin2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @min(a, b);
                }
            }.f,
            .vmax2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @max(a, b);
                }
            }.f,

            // Signed Math
            .viadd2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(@as(@Vector(2, i8), @bitCast(a)) +% @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .visub2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(@as(@Vector(2, i8), @bitCast(a)) -% @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .vimul2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(@as(@Vector(2, i8), @bitCast(a)) *% @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,

            // Bitwise
            .vand2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return a & b;
                }
            }.f,
            .vor2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return a | b;
                }
            }.f,
            .vxor2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return a ^ b;
                }
            }.f,

            // Comparisons (Unsigned)
            .vseteq2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(a == b);
                }
            }.f,
            .vsetne2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(a != b);
                }
            }.f,
            .vsetlt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(a < b);
                }
            }.f,
            .vsetle2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(a <= b);
                }
            }.f,
            .vsetgt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(a > b);
                }
            }.f,
            .vsetge2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(a >= b);
                }
            }.f,

            // Comparisons (Signed)
            .visetlt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(@as(@Vector(2, i8), @bitCast(a)) < @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .visetle2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(@as(@Vector(2, i8), @bitCast(a)) <= @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .visetgt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(@as(@Vector(2, i8), @bitCast(a)) > @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .visetge2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @bitCast(@as(@Vector(2, i8), @bitCast(a)) >= @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,

            else => unreachable,
        };

        break :c struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);

                const a: @Vector(2, u8) = @bitCast(vm.registers[de.dst]);
                const b: @Vector(2, u8) = @bitCast(vm.registers[de.src]);
                vm.registers[de.dst] = @bitCast(whichFn(a, b));
            }
        }.do;
    };
    return .{
        .cycles = 1,
        .handler = handler,
    };
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

    for (@typeInfo(ScalarOp).@"enum".fields) |field| {
        if (!@hasField(OpCode, field.name)) continue;
        table[@intFromEnum(@field(OpCode, field.name))] = ScalarFactory(@enumFromInt(field.value));
    }

    for (@typeInfo(VectorOp).@"enum".fields) |field| {
        if (!@hasField(OpCode, field.name)) continue;
        table[@intFromEnum(@field(OpCode, field.name))] = VectorFactory(@enumFromInt(field.value));
    }

    // TODO: add the rest

    // validation
    for (@typeInfo(OpCode).@"enum".fields) |field| {
        if (table[field.value].handler == InvalidHandler) {
            @compileLog("Instruction " ++ field.name ++ " is missing a handler");
        }
    }

    break :init table;
};
