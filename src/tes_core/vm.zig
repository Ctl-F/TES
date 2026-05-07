const std = @import("std");
const instructions = @import("instructions.zig");
const meta = @import("meta.zig");

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
    R1 = 1,
    R2 = 2,
    R3 = 3,
    R4 = 4,
    R5 = 5,
    R6 = 6,
    R7 = 7,
    R8 = 8,
    R9 = 9,
    RA = 10,
    RB = 11,
    RC = 12,
    RD = 13,
    RE = 14,
    RF = 15,

    IP = 16, // and 17 (32 bit)
    JR = 18, // and 19 (32 bit)
    FCL = 20, // keep these on an even number so they're save to reinterpet as 32 bit also
    FCH = 21, // keep low before high since we're targeting little-endian. Low part comes first
    GCL = 22,
    GCH = 23,

    SH = 24,
    SB = 25,
    SP = 26,
    REGISTER_COUNT_ENTRY,
};

pub const RegisterType = u16;
pub const RegisterIType = u16;
pub const InterruptID = u16;
pub const MaxRegisterID = 31;
pub const MaxRegisterCount = 32;
pub const DoubleRegisterType = @Int(.unsigned, @bitSizeOf(RegisterType) * 2);

const PageSize = std.math.maxInt(RegisterType) + 1;

const Registers = struct {
    const BUFF_LEN = MaxRegisterCount * @sizeOf(RegisterType);
    buffer: [BUFF_LEN]u8 align(@alignOf(DoubleRegisterType)) = [_]u8{0} ** BUFF_LEN,

    pub inline fn registers(this: *@This()) []RegisterType {
        return std.mem.bytesAsSlice(RegisterType, &this.buffer);
    }

    pub inline fn doubleRegisters(this: *@This()) []DoubleRegisterType {
        return std.mem.bytesAsSlice(DoubleRegisterType, &this.buffer);
    }
};

pub const IVTableSizeBytes = 256 * @sizeOf(u32);

const CoProcessorReturnPolicy = enum(u2) {
    resume_retry = 0,
    resume_skip = 1,
    resume_at = 2,
};

// TODO: Move IP from indexable registers to non-indexable registers
const NonIndexableRegisters = struct {
    flags: packed struct(u16) {
        halted: bool,
        isCoProcessor: bool,
        policy: CoProcessorReturnPolicy,
        reserved: u4,
        interruptCode: u8,
    } = .{
        .halted = false,
        .reserved = 0,
        .interruptCode = 0,
        .isCoProcessor = false,
        .policy = .resume_retry,
    },
    // base of the table and grows up
    interruptVectorTable: u32 = 0,
};

comptime {
    const fcl: u5 = @intFromEnum(RegisterID.FCL);
    const fch: u5 = @intFromEnum(RegisterID.FCH);
    const gcl: u5 = @intFromEnum(RegisterID.GCL);
    const gch: u5 = @intFromEnum(RegisterID.GCH);

    if (!(fch == fcl + 1)) @compileError("Frame Counter Registers are not paired correctly");
    if (!(gch == gcl + 1)) @compileError("Global Counter Registers are not paired correctly");

    if (!(fcl & 1 == 0)) @compileError("Frame Counter Register is misaligned for reinterpretation as 32bit");
    if (!(gcl & 1 == 0)) @compileError("Global Counter Register is misaligned for reinterpetation as 32bit");
}

pub const TESVM = struct {
    registers: Registers,
    nonidxRegisters: NonIndexableRegisters = .{},
    mmu: MMU = .{},
    instructionBuffer: []const Instruction,
    allocator: std.mem.Allocator, // realistically should only ever be the page allocator!!!

    registerBackBuffer: Registers = .{},
    nonidxRegisterBackBuffer: NonIndexableRegisters = .{},
    page0BackBuffer: *[PageSize]u8,

    /// Creates the default VM using the page allocator. I know this breaks zig api
    /// slightly, and I'll provide an actual allocator receiving initializer function also
    /// but the page allocator really is all that's necessary for this.
    pub fn defaultWithPageAllocator() !@This() {
        const allocator = std.heap.page_allocator;
        var mmu = try MMU.init(allocator);
        errdefer mmu.deinit();

        const page0BackBuffer = try allocator.alloc(u8, PageSize);
        errdefer allocator.free(page0BackBuffer);

        return .{
            .registers = .{},
            .instructionBuffer = &.{Instruction{ .opcode = @intFromEnum(OpCode.hlt), .payload = 0 }},
            .mmu = mmu,
            .page0BackBuffer = page0BackBuffer[0..PageSize],
        };
    }

    inline fn getPage0(this: *@This()) *[PageSize]u8 {
        if (this.mmu.pages[0].buffer) |buf| {
            return buf;
        }
        unreachable;
    }

    inline fn getPageMMIO(this: *@This()) *[PageSize]u8 {
        if (this.mmu.pages[MMU.MMIOPage].buffer) |buf| {
            return buf;
        }
        unreachable;
    }

    inline fn getIVTableSpan(this: *@This()) []u32 {
        const IVT = this.nonidxRegisters.interruptVectorTable;
        const page = (IVT & 0xFF0000) >> 16;
        const base = IVT & 0xFFFF;
        const top = base + IVTableSizeBytes;

        var pageBuffer: *[PageSize]u8 = undefined;

        if (!this.mmu.tryGetPage(page, &pageBuffer)) {
            @panic("Misconfigured IVTable! Page requested does not exist");
        }

        return pageBuffer[base..top];
    }

    fn initIVTable(this: *@This()) void {
        this.nonidxRegisters.interruptVectorTable = 0;

        const pageBuffer = this.getIVTableSpan();

        @memset(pageBuffer[this.nonidxRegisters.interruptVectorTable .. this.nonidxRegisters.interruptVectorTable + IVTableSizeBytes], 0);
    }

    inline fn doubleRegIndex(comptime id: RegisterID) u5 {
        const raw: u5 = @intFromEnum(id);
        if (raw & 1 != 0) @compileError("Misaligned Register Id points to non-32 bit enabled register being reinterpreted");
        return raw / 2;
    }

    pub inline fn tickClock(this: *@This(), cycles: u8) void {
        this.registers.doubleRegisters()[doubleRegIndex(.FCL)] +%= cycles;
        this.registers.doubleRegisters()[doubleRegIndex(.GCL)] +%= cycles;
    }

    pub inline fn mergeRegs(this: *@This(), highReg: u5, lowReg: u5) u32 {
        const high: u32 = this.registers.registers()[highReg];
        const low: u32 = this.registers.registers()[lowReg];

        return (high << 16) | low;
    }

    pub fn exec(this: *@This(), totalCycles: u32, comptime isCoProcessor: bool) !void {
        @setRuntimeSafety(false);

        var cycles = totalCycles;

        if (this.registers.registers()[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
            @branchHint(.unlikely);
            return error.AbruptProgramEOF;
        }

        var instruction = this.instructionBuffer[this.registers.registers()[@intFromEnum(RegisterID.IP)]];
        DISPATCH: switch (@as(OpCode, @enumFromInt(instruction.opcode))) {
            .hlt => {
                this.halted = true;
                return;
            },
            .b => {
                const decoded: InstructionDstSrc = @bitCast(instruction);
                const doubles = this.registers.doubleRegisters();

                const newIP = this.mergeRegs(decoded.dst, decoded.src);
                const IP = doubleRegIndex(.IP);
                const JR = doubleRegIndex(.JR);

                doubles[IP] += 1;
                doubles[JR] = doubles[IP];
                doubles[IP] = newIP;

                this.tickClock(1);
                cycles -= 1;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }

                if (doubles[IP] >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }

                instruction = this.instructionBuffer[doubles[IP]];
                continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
            },
            inline .bt, .bf => |which| {
                const decoded: InstructionDstSrc2 = @bitCast(instruction);
                const doubles = this.registers.doubleRegisters();

                const IP = doubleRegIndex(.IP);
                const JR = doubleRegIndex(.JR);

                const newIP = this.mergeRegs(decoded.dst, decoded.src0);
                const condition = if (comptime which == .bt)
                    this.registers.registers()[decoded.src1] != 0
                else
                    this.registers.registers()[decoded.src1] == 0;

                doubles[IP] += 1;
                if (condition) {
                    doubles[JR] = doubles[IP];
                    doubles[IP] = newIP;
                }

                this.tickClock(1);
                cycles -= 1;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }

                if (doubles[IP] >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }

                instruction = this.instructionBuffer[doubles[IP]];
                continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
            },
            .bn => {
                const decoded: InstructionDst = @bitCast(instruction);
                const doubles = this.registers.doubleRegisters();

                const IP = doubleRegIndex(.IP);
                const JR = doubleRegIndex(.JR);

                const offset: i14 = @bitCast(@as(u14, @truncate(decoded.payload)));

                const targetIP = @as(i64, @intCast(doubles[IP])) + offset;
                if (targetIP < 0 or targetIP >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }

                doubles[IP] += 1;
                doubles[JR] = doubles[IP];

                // should be safe since we verified that offset won't push IP out of range
                // and also that targetIP isn't smaller than zero
                doubles[IP] = @truncate(@as(u64, @bitCast(targetIP)));

                this.tickClock(1);
                cycles -= 1;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }

                instruction = this.instructionBuffer[doubles[IP]];
                continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
            },
            inline .bnf, .bnt => |which| {
                const decoded: InstructionDst = @bitCast(instruction);
                const doubles = this.registers.doubleRegisters();

                const IP = doubleRegIndex(.IP);
                const JR = doubleRegIndex(.JR);

                const offset: i14 = @bitCast(@as(u14, @truncate(decoded.payload)));

                const targetIP = @as(i64, @intCast(doubles[IP])) + offset;
                if (targetIP < 0 or targetIP >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }

                const condition = if (comptime which == .bnt)
                    this.registers.registers()[decoded.dst] != 0
                else
                    this.registers.registers()[decoded.dst] == 0;

                doubles[IP] += 1;

                if (condition) {
                    doubles[JR] = doubles[IP];
                    doubles[IP] = @truncate(@as(u64, @bitCast(targetIP)));
                }

                this.tickClock(1);
                cycles -= 1;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }

                instruction = this.instructionBuffer[doubles[IP]];
                continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
            },

            inline else => |op| {
                if (comptime !isCoProcessor) {
                    if (op == .resume_skip or op == .resume_at or op == .retry or op == .sync_mov or
                        op == .sync_write or op == .sync_hwrite or op == .read or op == .sync_hread)
                    {
                        const code = InterruptToID(Interrupt.InvalidInstruction);
                        this.fireInterrupt(code);
                    }
                }

                this.registers.doubleRegisters()[doubleRegIndex(.IP)] += 1;

                const consumed = InstructionTable[op].cycles;
                InstructionTable[op].handler(this, instruction) catch |e| {
                    const code = InterruptToID(e);
                    this.fireInterrupt(code);
                };

                this.tickClock(consumed);

                cycles = if (consumed > cycles) 0 else cycles - consumed;
                if (cycles == 0) {
                    @branchHint(.unlikely);
                    return;
                }
                if (this.registers.registers()[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
                    @branchHint(.unlikely);
                    return error.AbruptProgramEOF;
                }
                instruction = this.instructionBuffer[this.registers.registers()[@intFromEnum(RegisterID.IP)]];

                continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
            },
        }
    }

    fn fireInterrupt(this: *@This(), code: u8) void {
        const interruptTable = this.getIVTableSpan();
        const handlerAddress = interruptTable[code];

        if (handlerAddress == 0) {
            this.dumpContext();
            @panic("Unhandled interrupt/fault has occurred.");
        }

        const mainToCoBoundryCross = !this.nonidxRegisters.flags.isCoProcessor;

        // swap context to co-processor.
        // this will swap the registers and page0
        // TODO: add memory checks to ensure co-processor can't access pages 1..255 directly
        if (mainToCoBoundryCross) {
            this.swapContext();
            defer this.swapContext();

            const registers = this.registers.registers();
            const mainCoreRegisters = this.registerBackBuffer.registers();

            registers[@intFromEnum(RegisterID.GCL)] = mainCoreRegisters[@intFromEnum(RegisterID.GCL)];
            registers[@intFromEnum(RegisterID.GCH)] = mainCoreRegisters[@intFromEnum(RegisterID.GCH)];

            // recore change to global cycle counter
            defer mainCoreRegisters[@intFromEnum(RegisterID.GCL)] = registers[@intFromEnum(RegisterID.GCL)];
            defer mainCoreRegisters[@intFromEnum(RegisterID.GCH)] = registers[@intFromEnum(RegisterID.GCH)];

            this.nonidxRegisters.flags.isCoProcessor = true;
            this.nonidxRegisters.flags.interruptCode = code;

            // initialize stack
            const DefaultStackSize = 1024;
            registers[@intFromEnum(RegisterID.SB)] = DefaultStackSize;
            registers[@intFromEnum(RegisterID.SP)] = DefaultStackSize;
            registers[@intFromEnum(RegisterID.SH)] = 0;
        }

        // call handler
        this.registers.doubleRegisters()[doubleRegIndex(.IP)] = handlerAddress;
        this.registers.doubleRegisters()[doubleRegIndex(.JR)] = handlerAddress;
        // TODO: fix cycles handling here and have proper timing
        this.exec(5000, true);

        switch (this.nonidxRegisters.flags.policy) {
            // TODO: resume here
        }
    }

    fn dumpContext(this: *@This()) void {
        // TODO: dump debug context to standard out
        _ = this;
    }

    fn swapContext(this: *@This()) void {
        const bb = this.mmu.pages[0].buffer.?;
        this.mmu.pages[0].buffer = this.page0BackBuffer;
        this.page0BackBuffer = bb;

        const rr = this.registers;
        const ri = this.nonidxRegisters;

        this.registers = this.registerBackBuffer;
        this.nonidxRegisters = this.nonidxRegisterBackBuffer;

        this.registerBackBuffer = rr;
        this.nonidxRegisterBackBuffer = ri;
    }
};

pub const PagePermissions = packed struct(u8) {
    read: bool,
    write: bool,
    isMapped: bool = false,
    reserved: u5 = undefined,

    pub const ReadWrite = @This(){ .read = true, .write = true };
    pub const ReadOnly = @This(){ .read = true, .write = false };
    pub const WriteOnly = @This(){ .read = false, .write = true };
    pub const Unavailable = @This(){ .read = false, .write = false };
};

pub const PageEntry = struct {
    permissions: PagePermissions,
    buffer: ?*[PageSize]u8,
};

pub const MMU = struct {
    pages: [256]PageEntry = [_]PageEntry{.{ .buffer = null, .permissions = PagePermissions.Unavailable }} ** 256,
    allocator: std.mem.Allocator,

    pub const MMIOPage: u8 = 255;

    /// allocator is HIGHLY RECOMMENDED to be the page allocator
    pub fn init(allocator: std.mem.Allocator) !@This() {
        var this = @This(){
            .allocator = allocator,
        };

        try this.requestPage(0, null);
        errdefer this.freePage(0);

        try this.requestPage(MMIOPage, null);
        errdefer this.freePage(MMIOPage);

        return this;
    }

    pub inline fn hasPage(this: *@This(), pageID: u8) bool {
        return this.pages[pageID].buffer != null and (this.pages[pageID].permissions.read or this.pages[pageID].permissions.read);
    }

    pub inline fn getPage(this: *@This(), pageID: u8) ?*[PageSize]u8 {
        return this.pages[pageID].buffer;
    }

    pub inline fn tryGetPage(this: *@This(), pageID: u8, bufferPtr: **[PageSize]u8) bool {
        if (this.hasPage(pageID)) {
            bufferPtr.* = this.pages[pageID].buffer.?;
            return true;
        }
        return false;
    }

    pub fn requestPage(this: *@This(), pageID: u8, permissions: ?PagePermissions) !void {
        const perm = if (permissions) |p| p else PagePermissions.ReadWrite;

        if (perm.isMapped) {
            @panic("Mapped pages must not be requested through 'requestPage' use 'mapPage' instead.");
        }

        // allocate new page
        if (this.pages[pageID].buffer == null) {
            const pageBuffer = try this.allocator.alloc(u8, PageSize);
            errdefer this.allocator.free(pageBuffer);

            this.pages[pageID] = .{
                .permissions = perm,
                .buffer = pageBuffer[0..PageSize],
            };

            return;
        }

        // reallocate existing page (e.g. change permissions without changing data)
        // this can't be done if a page is a mapped page (those must always be readonly)
        // which is why we have the validation up top for if perm.isMapped. The VM itself should
        // manage whether to map or request pages under a given syscall which is why the mmu treats
        // it as unreachable.
        this.pages[pageID].permissions = perm;
    }

    pub fn mapPage(this: *@This(), id: u8, buffer: *[PageSize]u8) !void {
        if (this.pages[id].buffer != null) {
            @panic("Mapping cannot overwrite an existing page. You must first free the page before mapping");
        }

        this.pages[id] = .{
            .permissions = .{ .read = true, .write = false, .isMapped = true },
            .buffer = buffer,
        };
    }

    pub fn freePage(this: *@This(), id: u8) void {
        deinitPage(this.allocator, &this.pages[id]);
    }

    inline fn deinitPage(allocator: std.mem.Allocator, page: *PageEntry) void {
        if (page.buffer) |bufPtr| {
            if (!page.permissions.isMapped) {
                allocator.free(bufPtr);
            }
            page.buffer = null;
            page.permissions = PagePermissions.Unavailable;
        }
    }

    pub fn deinit(this: *@This()) void {
        for (&this.pages) |*page| {
            deinitPage(this.allocator, page);
        }
    }
};

const Interrupt = error{
    Unknown,
    StackUnderflow,
    StackOverflow,
    PageFault,
    DivideByZero,
    SignedDivisionOverflow,
    InvalidInstruction,
    UserInterrupt,
};

pub fn InterruptToID(e: Interrupt) u8 {
    return switch (e) {
        Interrupt.Unknown => 0,
        Interrupt.StackUnderflow => 1,
        Interrupt.StackOverflow => 2,
        Interrupt.PageFault => 3,
        Interrupt.DivideByZero => 4,
        Interrupt.SignedDivisionOverflow => 5,
        Interrupt.InvalidInstruction => 6,
        // Add System Interrupts Here...
        Interrupt.UserInterrupt => 128,
        // user interrupts will use the InterruptCode in the flags register
        // instead of a literal value from the error
    };
}

const InstructionHandler = fn (*TESVM, Instruction) callconv(.@"inline") Interrupt!void;

pub inline fn InvalidHandler(_: *TESVM, _: Instruction) Interrupt!void {
    return Interrupt.InvalidInstruction;
}
pub inline fn NotInvalidButUnreachable(_: *TESVM, _: Instruction) Interrupt!void {
    unreachable;
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
                vm.registers.registers()[decoded.dst] = vm.registers.registers()[decoded.src];
            }
        }.do,
        InstructionDstAddrSrc => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstAddrSrc = @bitCast(instr);

                const base: isize = @intCast(vm.registers.registers()[decoded.dPOR]);
                const offset: isize = @intCast(decoded.offset);

                // no need to check pageID fault since page0 always exists

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                std.mem.writeInt(moveType, vm.mmu.pages[0].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], vm.registers.registers()[decoded.src], .little);

                if (comptime postOp == .inc) {
                    vm.registers.registers()[decoded.dPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers.registers()[decoded.dPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDstAddrXSrc => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstAddrXSrc = @bitCast(instr);

                const base: isize = @intCast(vm.registers.registers()[decoded.dPOR]);
                const offset: isize = @intCast(decoded.offset);
                const pageID: u8 = @truncate(vm.registers.registers()[decoded.dPSR]);

                if (vm.mmu.pages[pageID].buffer == null) {
                    @branchHint(.unlikely);
                    // maybe separate this "unallocated page" vs "page fault"
                    // but for now page fault is the catch all
                    return Interrupt.PageFault;
                }

                if (!vm.mmu.pages[pageID].permissions.write) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                std.mem.writeInt(moveType, vm.mmu.pages[pageID].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], vm.registers.registers()[decoded.src], .little);

                if (comptime postOp == .inc) {
                    vm.registers.registers()[decoded.dPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers.registers()[decoded.dPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDstSrcAddr => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstSrcAddr = @bitCast(instr);

                const base: isize = @intCast(vm.registers.registers()[decoded.sPOR]);
                const offset: isize = @intCast(decoded.offset);

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                vm.registers.registers()[decoded.dst] = std.mem.readInt(moveType, vm.mmu.pages[0].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], .little);

                if (comptime postOp == .inc) {
                    vm.registers.registers()[decoded.sPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers.registers()[decoded.sPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDstSrcAddrX => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDstSrcAddrX = @bitCast(instr);

                const pageID: u8 = @truncate(vm.registers.registers()[decoded.sPSR]);
                const base: isize = @intCast(vm.registers.registers()[decoded.sPOR]);
                const offset: isize = @intCast(decoded.offset);

                if (vm.mmu.pages[pageID].buffer == null) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                if (!vm.mmu.pages[pageID].permissions.read) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                if (base + offset < 0 or (base + offset + @sizeOf(moveType)) > PageSize) {
                    @branchHint(.unlikely);
                    return Interrupt.PageFault;
                }

                vm.registers.registers()[decoded.dst] = std.mem.readInt(moveType, vm.mmu.pages[pageID].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], .little);

                if (comptime postOp == .inc) {
                    vm.registers.registers()[decoded.sPOR] +%= @sizeOf(moveType);
                } else if (comptime postOp == .dec) {
                    vm.registers.registers()[decoded.sPOR] -%= @sizeOf(moveType);
                }
            }
        }.do,
        InstructionDst => struct {
            pub inline fn do(vm: *TESVM, instr: Instruction) Interrupt!void {
                const decoded: InstructionDst = @bitCast(instr);
                vm.registers.registers()[decoded.dst] = @truncate(decoded.payload);
            }
        }.do,
        else => unreachable,
    };

    return .{ .handler = function, .cycles = 1 };
}

const ScalarOp = meta.Subset(OpCode, &.{
    .add,     .sub,    .mul,     .div,     .shr,     .shl,
    .bin_and, .bin_or, .bin_xor, .bin_not, .log_and, .log_or,
    .log_not, .neg,    .inc,     .dec,     .rol,     .ror,
    .sar,     .min,    .max,     .abs,     .sign,    .iadd,
    .isub,    .imul,   .idiv,    .extz,    .exts,    .truncz,
    .clamp,   .fma,    .seteq,   .setneq,  .setlt,   .setle,
    .setgt,   .setge,  .isetlt,  .isetle,  .isetgt,  .isetge,
});

fn ScalarFactory(comptime op: ScalarOp) InstructionInfo {
    const function, const cost = switch (op) {
        // --- Binary Math ---
        .add => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] +%= vm.registers.registers()[de.src];
            }
        }.do, 1 },
        .sub => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] -%= vm.registers.registers()[de.src];
            }
        }.do, 1 },
        .mul => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] *%= vm.registers.registers()[de.src];
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

                    if (vm.registers.registers()[v] == 0) return Interrupt.DivideByZero;

                    vm.registers.registers()[q] = vm.registers.registers()[d] / vm.registers.registers()[v];
                    vm.registers.registers()[r] = vm.registers.registers()[d] % vm.registers.registers()[v];
                }
            }.do,
            8,
        },
        // --- Shifts ---
        .shr => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] >>= @truncate(vm.registers.registers()[de.src]);
            }
        }.do, 1 },
        .shl => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] <<= @truncate(vm.registers.registers()[de.src]);
            }
        }.do, 1 },
        .sar => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const val: i16 = @bitCast(vm.registers.registers()[de.dst]);
                const shift: u4 = @truncate(vm.registerse[de.src]);
                vm.registers.registers()[de.dst] = @bitCast(val >> shift);
            }
        }.do, 1 },

        // --- Bitwise ---
        .bin_and => .{
            struct { // Treated as bitwise AND per common naming conventions
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDstSrc = @bitCast(i);
                    vm.registers.registers()[de.dst] &= vm.registers.registers()[de.src];
                }
            }.do,
            1,
        },
        .bin_or => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] |= vm.registers.registers()[de.src];
            }
        }.do, 1 },
        .bin_xor => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] ^= vm.registers.registers()[de.src];
            }
        }.do, 1 },

        // --- Logical ---
        .log_and => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const res = (vm.registers.registers()[de.dst] != 0) and (vm.registers.registers()[de.src] != 0);
                vm.registers.registers()[de.dst] = if (res) 1 else 0;
            }
        }.do, 1 },
        .log_or => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const res = (vm.registers.registers()[de.dst] != 0) or (vm.registers.registers()[de.src] != 0);
                vm.registers.registers()[de.dst] = if (res) 1 else 0;
            }
        }.do, 1 },

        // --- Unary (using InstructionDst) ---
        .bin_not => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers.registers()[de.dst] = ~vm.registers.registers()[de.dst];
            }
        }.do, 1 },
        .log_not => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers.registers()[de.dst] = if (vm.registers.registers()[de.dst] == 0) 1 else 0;
            }
        }.do, 1 },
        .neg => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers.registers()[de.dst] = -%vm.registers.registers()[de.dst];
            }
        }.do, 1 },
        .inc => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers.registers()[de.dst] +%= 1;
            }
        }.do, 1 },
        .dec => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers.registers()[de.dst] -%= 1;
            }
        }.do, 1 },
        // --- Rotates ---
        .rol => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] = std.math.rotl(u16, vm.registers.registers()[de.dst], @truncate(vm.registers.registers()[de.src]));
            }
        }.do, 1 },
        .ror => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] = std.math.rotr(u16, vm.registers.registers()[de.dst], @truncate(vm.registers.registers()[de.src]));
            }
        }.do, 1 },

        // --- Min/Max/Abs/Sign ---
        .min => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] = @min(vm.registers.registers()[de.dst], vm.registers.registers()[de.src]);
            }
        }.do, 1 },
        .max => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] = @max(vm.registers.registers()[de.dst], vm.registers.registers()[de.src]);
            }
        }.do, 1 },
        .abs => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                const val: i16 = @bitCast(vm.registers.registers()[de.dst]);
                vm.registers.registers()[de.dst] = @bitCast(if (val < 0) -%val else val);
            }
        }.do, 1 },
        .sign => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                const val: i16 = @bitCast(vm.registers.registers()[de.dst]);
                vm.registers.registers()[de.dst] = if (val > 0) @as(u16, 1) else if (val < 0) @as(u16, 0xFFFF) else 0;
            }
        }.do, 1 },

        // --- Signed Arithmetic ---
        .iadd => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const a: i16 = @bitCast(vm.registers.registers()[de.dst]);
                const b: i16 = @bitCast(vm.registers.registers()[de.src]);
                vm.registers.registers()[de.dst] = @bitCast(a +% b);
            }
        }.do, 1 },
        .isub => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const a: i16 = @bitCast(vm.registers.registers()[de.dst]);
                const b: i16 = @bitCast(vm.registers.registers()[de.src]);
                vm.registers.registers()[de.dst] = @bitCast(a -% b);
            }
        }.do, 1 },
        .imul => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                const a: i16 = @bitCast(vm.registers.registers()[de.dst]);
                const b: i16 = @bitCast(vm.registers.registers()[de.src]);
                vm.registers.registers()[de.dst] = @bitCast(a *% b);
            }
        }.do, 1 },
        .idiv => .{
            struct {
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst2Src2 = @bitCast(i);
                    // div q, r, d, v ==> q = d / v : r = d % v
                    const q: u16 = de.dst0;
                    const r: u16 = de.dst1;
                    const d: i16 = @bitCast(vm.registers.registers()[de.src0]);
                    const v: i16 = @bitCast(vm.registers.registers()[de.src1]);

                    if (v == 0) {
                        @branchHint(.unlikely);
                        return Interrupt.DivideByZero;
                    }
                    if (d == std.math.minInt(i16) and v == -1) {
                        @branchHint(.unlikely);
                        return Interrupt.SignedDivisionOverflow;
                    }

                    vm.registers.registers()[q] = @bitCast(@divTrunc(d, v));
                    vm.registers.registers()[r] = @bitCast(@rem(d, v));
                }
            }.do,
            8,
        },
        // --- Extensions & Conversions ---
        .extz => .{
            struct { // Zero extend lower 8 bits
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    vm.registers.registers()[de.dst] = vm.registers.registers()[de.dst] & 0x00FF;
                }
            }.do,
            1,
        },
        .exts => .{
            struct { // Sign extend lower 8 bits
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    const low: i8 = @truncate(@as(u16, vm.registers.registers()[de.dst]));
                    vm.registers.registers()[de.dst] = @bitCast(@as(i16, low));
                }
            }.do,
            1,
        },
        .truncz => .{
            struct { // Truncate to lower 8 bits
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    vm.registers.registers()[de.dst] = @as(u8, @truncate(vm.registers.registers()[de.dst]));
                }
            }.do,
            1,
        },
        .clamp => .{
            struct { // Saturate 16-bit to 8-bit range (0-255)
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDst = @bitCast(i);
                    vm.registers.registers()[de.dst] = @min(vm.registers.registers()[de.dst], 255);
                }
            }.do,
            1,
        },

        // --- Ternary Math ---
        .fma => .{
            struct { // (A * B) + C
                pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                    const de: InstructionDstSrc2 = @bitCast(i);
                    const prod = vm.registers.registers()[de.src0] *% vm.registers.registers()[de.src1];
                    vm.registers.registers()[de.dst] +%= prod;
                }
            }.do,
            1,
        },

        // set* family
        .seteq => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (vm.registers.registers()[de.src0] == vm.registers.registers()[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setneq => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (vm.registers.registers()[de.src0] != vm.registers.registers()[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setlt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (vm.registers.registers()[de.src0] < vm.registers.registers()[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setle => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (vm.registers.registers()[de.src0] <= vm.registers.registers()[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setgt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (vm.registers.registers()[de.src0] > vm.registers.registers()[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .setge => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (vm.registers.registers()[de.src0] >= vm.registers.registers()[de.src1]) 1 else 0;
            }
        }.do, 1 },
        .isetlt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (@as(i16, @bitCast(vm.registers.registers()[de.src0])) < @as(i16, @bitCast(vm.registers.registers()[de.src1]))) 1 else 0;
            }
        }.do, 1 },
        .isetle => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (@as(i16, @bitCast(vm.registers.registers()[de.src0])) <= @as(i16, @bitCast(vm.registers.registers()[de.src1]))) 1 else 0;
            }
        }.do, 1 },
        .isetgt => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (@as(i16, @bitCast(vm.registers.registers()[de.src0])) > @as(i16, @bitCast(vm.registers.registers()[de.src1]))) 1 else 0;
            }
        }.do, 1 },
        .isetge => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc2 = @bitCast(i);
                vm.registers.registers()[de.dst] = if (@as(i16, @bitCast(vm.registers.registers()[de.src0])) >= @as(i16, @bitCast(vm.registers.registers()[de.src1]))) 1 else 0;
            }
        }.do, 1 },
    };

    return InstructionInfo{ .handler = function, .cycles = cost };
}

const VectorOp = meta.Subset(OpCode, &.{
    .vadd2,    .vsub2,    .vmul2,    .vshr2,    .vshl2,
    .vand2,    .vor2,     .vxor2,    .vnot2,    .vneg2,
    .vseteq2,  .vsetne2,  .vsetlt2,  .vsetle2,  .vsetgt2,
    .vsetge2,  .vreduce2, .vsplat2,  .vldc2,    .viadd2,
    .visub2,   .vimul2,   .visetlt2, .visetle2, .visetgt2,
    .visetge2, .vselect2, .vswap2,   .vsar2,    .vabs2,
    .vsign2,   .vmin2,    .vmax2,    .vrol2,    .vror2,
});

fn VectorFactory(comptime op: VectorOp) InstructionInfo {
    const handler = if (comptime op == .vswap2) a: {
        break :a struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDst = @bitCast(i);
                vm.registers.registers()[de.dst] = @byteSwap(vm.registers.registers()[de.dst]);
            }
        }.do;
    } else if (comptime op == .vselect2) b: {
        break :b struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc3 = @bitCast(i);

                const va: @Vector(2, u8) = @bitCast(vm.registers.registers()[de.src0]);
                const vb: @Vector(2, u8) = @bitCast(vm.registers.registers()[de.src1]);

                const mask = vm.registers.registers()[de.src2];
                const vMask = @Vector(2, bool){ mask & 0x00FF != 0, mask & 0xFF00 != 0 };

                const vr = @select(u8, vMask, va, vb);

                vm.registers.registers()[de.dst] = @bitCast(vr);
            }
        }.do;
    } else if (comptime op == .vreduce2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDstSrc = @bitCast(i);

            const va: @Vector(2, u8) = @bitCast(vm.registers.registers()[de.src]);

            vm.registers.registers()[de.dst] = @intCast(switch (@as(instructions.ReduceCode, @enumFromInt(@as(u8, @truncate(de.payload))))) {
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
            vm.registers.registers()[de.dst] = (@as(u16, @intCast(immediate)) << 8) | immediate;
        }
    }.do else if (comptime op == .vldc2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDst = @bitCast(i);
            vm.registers.registers()[de.dst] = @truncate(de.payload);
        }
    }.do else if (comptime op == .vnot2 or op == .vneg2 or op == .vabs2 or op == .vsign2) struct {
        pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
            const de: InstructionDst = @bitCast(i);
            const v: @Vector(2, u8) = @bitCast(vm.registers.registers()[de.dst]);
            vm.registers.registers()[de.dst] = @bitCast(switch (op) {
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
            const v: @Vector(2, u8) = @bitCast(vm.registers.registers()[de.dst]);
            const amount: u3 = @truncate(vm.registers.registers()[de.src]); // Shift amount usually 0..7
            const s: @Vector(2, u3) = @splat(amount);

            vm.registers.registers()[de.dst] = @bitCast(switch (op) {
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

                const a: @Vector(2, u8) = @bitCast(vm.registers.registers()[de.dst]);
                const b: @Vector(2, u8) = @bitCast(vm.registers.registers()[de.src]);
                vm.registers.registers()[de.dst] = @bitCast(whichFn(a, b));
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

    // branching instructions are handled directly in the dispatch (b family, bn family, hlt)
    table[@intFromEnum(OpCode.b)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
    table[@intFromEnum(OpCode.bt)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
    table[@intFromEnum(OpCode.bf)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
    table[@intFromEnum(OpCode.bn)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
    table[@intFromEnum(OpCode.bnt)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
    table[@intFromEnum(OpCode.bnf)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
    table[@intFromEnum(OpCode.hlt)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };

    // TODO: add the rest

    // validation
    for (@typeInfo(OpCode).@"enum".fields) |field| {
        if (table[field.value].handler == InvalidHandler) {
            @compileLog("Instruction " ++ field.name ++ " is missing a handler");
        }
    }

    break :init table;
};
