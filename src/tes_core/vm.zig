const std = @import("std");
const instructions = @import("instructions.zig");
const meta = @import("meta.zig");
const conn = @import("conn");

pub const OpCode = instructions.InstructionCode;
pub const Instruction = instructions.Instruction;
const InstructionDst = instructions.InstructionDst;
const InstructionDstSrc = instructions.InstructionDstSrc;
const InstructionDstAddrSrc = instructions.InstructionDstAddrSrc;
const InstructionDstAddrXSrc = instructions.InstructionDstAddrXSrc;
const InstructionDstSrcAddr = instructions.InstructionDstSrcAddr;
const InstructionDstSrcAddrX = instructions.InstructionDstSrcAddrX;
const InstructionDst2Src2 = instructions.InstructionDst2Src2;
const InstructionDstSrc2 = instructions.InstructionDstSrc2;
const InstructionDstSrc3 = instructions.InstructionDstSrc3;

pub const AccessMode = enum(u8) { readwrite = 0, read = 1, write = 2 };
pub const Hooks = struct {
    frameHook: ?*const fn (*TESVM) anyerror!void = null,
    onMemoryAccess: ?*const fn (vm: *TESVM, page: u8, offset: u16, mode: AccessMode, value: u16) void = null,
    onRegisterModify: ?*const fn (vm: *TESVM, register: u5, oldValue: u16, newValue: u16) void = null,
    onInstructionBegin: ?*const fn (vm: *TESVM, opcode: OpCode, ip: u32, fc: u32, gc: u32) void = null,
    onInstructionEnd: ?*const fn (vm: *TESVM, opcode: OpCode, ip: u32, fc: u32, gc: u32) void = null,
    onSyscall: ?*const fn (vm: *TESVM, pool: PoolID, event: EventID) void = null,
    onEnterCoProcessor: ?*const fn (vm: *TESVM) void = null,
    onExitCoProcessor: ?*const fn (vm: *TESVM) void = null,

    pub inline fn complete(this: @This()) bool {
        return this.frameHook != null;
    }
    pub inline fn hasAnyDebug(this: @This()) bool {
        return (this.onMemoryAccess != null) or
            (this.onRegisterModify != null) or
            (this.onInstructionBegin != null) or
            (this.onInstructionEnd != null) or
            (this.onSyscall != null) or
            (this.onEnterCoProcessor != null) or
            (this.onExitCoProcessor != null);
    }
};

pub const TESVM = tes(.{});

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
    previousInstructionLength: u8 = 0, // u8 is too big  but we'll use it for access efficiency
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

pub const PoolID = u9;
pub const EventID = u15;
pub const EventResult = union(enum) {
    ok,
    okWithResult: struct { toRA: ?u16, toRB: ?u16, toRC: ?u16, toRD: ?u16, toRE: ?u16, toRF: ?u16 },
    fail: struct { panic: bool, code: u8, message: ?[]const u8 },
};

pub const EventInstruction = packed struct(u32) {
    opcode: u8,
    poolID: PoolID,
    eventID: EventID,
};

pub const Extension = struct {
    enabled: bool,
    handler: *const fn (vm: *TESVM, evCode: EventID) EventResult,
    crashDump: *const fn (vm: *TESVM) void,
    getFriendlyName: *const fn () []const u8,

    pub fn trigger(this: *@This(), vm: *TESVM, i: EventInstruction) Interrupt!void {
        const code = i.eventID;
        const pool = i.poolID;

        if (!this.enabled) {
            this.crash(vm, code, null);
        }

        const result = this.handler(vm, code);

        switch (result) {
            .ok => {},
            .okWithResult => |res| {
                const registers = vm.registers.registers();
                if (res.toRA) |a| {
                    registers[@intFromEnum(RegisterID.RA)] = a;
                }
                if (res.toRB) |b| {
                    registers[@intFromEnum(RegisterID.RB)] = b;
                }
                if (res.toRC) |c| {
                    registers[@intFromEnum(RegisterID.RC)] = c;
                }
                if (res.toRD) |d| {
                    registers[@intFromEnum(RegisterID.RD)] = d;
                }
                if (res.toRE) |e| {
                    registers[@intFromEnum(RegisterID.RE)] = e;
                }
                if (res.toRF) |f| {
                    registers[@intFromEnum(RegisterID.RF)] = f;
                }
            },
            .fail => |res| {
                if (res.panic) {
                    this.crash(vm, code, res.message);
                }

                // result error code
                vm.nonidxRegisters.flags.interruptCode = res.code;

                // called code and pool so that actual error identification can happen
                vm.registers.registers()[@intFromEnum(RegisterID.RF)] = code;
                vm.registers.registers()[@intFromEnum(RegisterID.RE)] = pool;

                return Interrupt.ExtensionInterrupt;
            },
        }
    }

    fn crash(this: *@This(), vm: *TESVM, code: EventID, message: ?[]const u8) noreturn {
        std.debug.print("Exception has occurred in Driver\n - {s}\n - {}\n\n", .{
            this.getFriendlyName(),
            code,
        });
        if (message) |msg| {
            std.debug.print("Message provided: {s}\n", .{msg});
        }
        vm.dumpContext();
        @trap();
    }
};

pub fn tes(comptime hooks: Hooks) type {
    const InstructionTable = comptime init: {
        var table = [_]InstructionInfo{.{ .handler = InvalidHandler, .cycles = 0 }} ** 256;

        table[@intFromEnum(OpCode.nop)] = .{ .handler = struct {
            pub inline fn do(_: *TESVM, _: Instruction) Interrupt!void {}
        }.do, .cycles = 1 };

        // basic mov
        table[@intFromEnum(OpCode.mov)] = MovFactory(InstructionDstSrc, .full, .none);
        table[@intFromEnum(OpCode.mov_hreg)] = MovFactory(InstructionDstSrc, .half, .none);
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
        table[@intFromEnum(OpCode.lea)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.resume_at)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.resume_skip)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.retry)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };

        // stack instructions
        table[@intFromEnum(OpCode.bump_c)] = StackFactory(.bump_c);
        table[@intFromEnum(OpCode.bump_r)] = StackFactory(.bump_r);
        table[@intFromEnum(OpCode.push8)] = StackFactory(.push8);
        table[@intFromEnum(OpCode.push16)] = StackFactory(.push16);
        table[@intFromEnum(OpCode.push32)] = StackFactory(.push32);
        table[@intFromEnum(OpCode.pop8)] = StackFactory(.pop8);
        table[@intFromEnum(OpCode.pop16)] = StackFactory(.pop16);
        table[@intFromEnum(OpCode.pop32)] = StackFactory(.pop32);
        table[@intFromEnum(OpCode.stackset)] = StackFactory(.stackset);

        table[@intFromEnum(OpCode.select)] = InstructionInfo{ .handler = implSelect, .cycles = 1 };
        table[@intFromEnum(OpCode.int)] = InstructionInfo{ .handler = implInt, .cycles = 1 };
        table[@intFromEnum(OpCode.syscall)] = InstructionInfo{ .handler = implSyscall, .cycles = 1 };
        table[@intFromEnum(OpCode.swap)] = InstructionInfo{ .handler = implSwap, .cycles = 1 };
        table[@intFromEnum(OpCode.trap)] = InstructionInfo{ .handler = implTrap, .cycles = 1 };
        table[@intFromEnum(OpCode.ivs)] = InstructionInfo{ .handler = implIVS, .cycles = 1 };
        table[@intFromEnum(OpCode.bittest)] = InstructionInfo{ .handler = implBittest, .cycles = 1 };
        table[@intFromEnum(OpCode.mcpy)] = InstructionInfo{ .handler = implMcpy, .cycles = 10 };
        table[@intFromEnum(OpCode.mset)] = InstructionInfo{ .handler = implMset, .cycles = 10 };
        table[@intFromEnum(OpCode.mmov)] = InstructionInfo{ .handler = implMmov, .cycles = 12 };

        //TODO: implement these later
        table[@intFromEnum(OpCode.yield_frame)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.sync_mov)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.sync_read)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.sync_hread)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.sync_write)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };
        table[@intFromEnum(OpCode.sync_hwrite)] = InstructionInfo{ .handler = NotInvalidButUnreachable, .cycles = 1 };

        // validation
        var missing: usize = 0;
        for (@typeInfo(OpCode).@"enum".fields) |field| {
            if (table[field.value].handler == InvalidHandler) {
                @compileLog("Instruction " ++ field.name ++ " is missing a handler");
                missing += 1;
            }
        }
        if (missing > 0) {
            const message = std.fmt.comptimePrint("Missing {}/{} implementations", .{
                missing,
                @typeInfo(OpCode).@"enum".fields.len,
            });
            @compileLog(message);
        }

        break :init table;
    };

    return extern struct {
        registers: Registers,
        nonidxRegisters: NonIndexableRegisters = .{},
        mmu: MMU,
        instructionBuffer: []const Instruction,
        allocator: std.mem.Allocator, // realistically should only ever be the page allocator!!!
        io: std.Io,
        log: conn.log.Log,

        registerBackBuffer: Registers = .{},
        nonidxRegisterBackBuffer: NonIndexableRegisters = .{},
        page0BackBuffer: PageBuffer,
        extensions: std.AutoHashMap(PoolID, Extension),

        userData: ?*anyopaque = null,

        /// Creates the default VM using the page allocator. I know this breaks zig api
        /// slightly, and I'll provide an actual allocator receiving initializer function also
        /// but the page allocator really is all that's necessary for this.
        pub fn defaultWithPageAllocator(io: std.Io) !@This() {
            const allocator = std.heap.page_allocator;
            var mmu = try MMU.init(allocator);
            errdefer mmu.deinit();

            const page0BackBuffer = try mmu.allocatePageSlice();
            errdefer allocator.free(page0BackBuffer);

            return .{
                .registers = .{},
                .instructionBuffer = &.{Instruction{ .opcode = @intFromEnum(OpCode.hlt), .payload = 0 }},
                .mmu = mmu,
                .io = io,
                .log = conn.log.init(io, "tes"),
                .page0BackBuffer = page0BackBuffer[0..PageSize],
                .allocator = allocator,
                .extensions = std.AutoHashMap(PoolID, Extension).init(allocator),
            };
        }

        pub fn deinit(this: *@This()) void {
            this.mmu.deinit();
            this.allocator.free(@as([]u8, this.page0BackBuffer[0..PageSize]));
        }

        pub inline fn getPage0(this: *@This()) PageBuffer {
            if (this.mmu.pages[0].buffer) |buf| {
                return buf;
            }
            unreachable;
        }

        pub inline fn getPage(this: *@This(), page: u8) ?PageBuffer {
            return (this.mmu.pages[page].buffer);
        }

        pub inline fn getPageEntry(this: *@This(), page: u8) PageEntry {
            return this.mmu.pages[page];
        }

        pub inline fn getPageMMIO(this: *@This()) PageBuffer {
            if (this.mmu.pages[MMU.MMIOPage].buffer) |buf| {
                return buf;
            }
            unreachable;
        }

        //TODO: When user sets table (and stack) address make sure to enforce alignment rules

        inline fn getIVTableSpan(this: *@This()) []u32 {
            const IVT = this.nonidxRegisters.interruptVectorTable;
            const page: u8 = @truncate((IVT & 0xFF0000) >> 16);
            const base: u16 = @truncate(IVT);

            var pageBuffer: PageBuffer = undefined;

            if (!this.mmu.tryGetPage(page, &pageBuffer)) {
                this.log.fatal("Misconfigured IVTable! Page requested does not exist", .{});
                @trap();
            }

            const tablePtrAddress = @as(usize, @intFromPtr(pageBuffer)) + base;
            if (tablePtrAddress % @sizeOf(u32) != 0) {
                this.log.fatal("IVTable base is not aligned", .{});
                @trap();
            }

            const tablePtr: [*]align(@alignOf(u32)) u32 = @as([*]align(@alignOf(u32)) u32, @ptrFromInt(tablePtrAddress));
            return tablePtr[0..256];
        }

        fn initIVTable(this: *@This()) void {
            this.nonidxRegisters.interruptVectorTable = 0;

            const pageBuffer = this.getIVTableSpan();

            @memset(pageBuffer[this.nonidxRegisters.interruptVectorTable .. this.nonidxRegisters.interruptVectorTable + IVTableSizeBytes], 0);
        }

        pub inline fn doubleRegIndex(comptime id: RegisterID) u5 {
            const raw: u5 = @intFromEnum(id);
            if (raw & 1 != 0) @compileError("Misaligned Register Id points to non-32 bit enabled register being reinterpreted");
            return raw / 2;
        }

        inline fn wideRegIndex(id: u5) u5 {
            if (id & 1 != 0) @panic("Misaligned RegisterID points to non-32 bit register.");
            return id / 2;
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

        pub fn runCoProcessor(this: *@This()) !void {
            try this.runImpl(true);
        }

        pub fn run(this: *@This()) !void {
            try this.runImpl(false);
        }

        fn runImpl(this: *@This(), comptime isCoPro: bool) !void {
            const ClockSpeed = 12_510_000;
            const FPS = 30;
            const CyclesPerFrame = ClockSpeed / FPS; // 166,666
            const NsPerCycle = std.time.ns_per_s / ClockSpeed;
            const NsPerFrame = std.time.ns_per_s / FPS; // 33.3ms

            var lastTime = std.Io.Timestamp.now(this.io, .awake);
            var ns_accum: i96 = 0;
            var cyclesInFrame: u32 = 0;

            const RFCL = doubleRegIndex(.FCL);
            const RGCL = doubleRegIndex(.GCL);

            var yielded_frame: bool = false;

            while (!this.nonidxRegisters.flags.halted) {
                const currentTime = std.Io.Timestamp.now(this.io, .awake);
                const elapsed = lastTime.durationTo(currentTime);
                lastTime = currentTime;

                ns_accum += elapsed.nanoseconds;

                // Anti-spiral time debt barrier
                if (ns_accum > NsPerFrame * 2) {
                    ns_accum = NsPerFrame;
                }

                if (ns_accum >= NsPerCycle) {
                    var cyclesToRun = @as(u32, @intCast(@divFloor(ns_accum, NsPerCycle)));
                    ns_accum = @rem(ns_accum, NsPerCycle);

                    const wideRegs = this.registers.doubleRegisters();

                    if (cyclesToRun > CyclesPerFrame) {
                        cyclesToRun = CyclesPerFrame;
                    }

                    // --- STRATEGY: ONLY EXECUTE IF GUEST IS NOT WAITING FOR VSYNC ---
                    if (!yielded_frame) {
                        const preClock = wideRegs[RGCL];

                        const status = this.exec(cyclesToRun, isCoPro) catch |e| {
                            if (e == error.AbruptProgramEOF) {
                                this.log.err("IP {}/{} instructions\n", .{
                                    this.registers.doubleRegisters()[doubleRegIndex(.IP)],
                                    this.instructionBuffer.len,
                                });
                            }
                            return e;
                        };

                        const postClock = wideRegs[RGCL];
                        const consumed = postClock -% preClock;
                        cyclesInFrame += consumed;

                        if (status == .Yield) {
                            yielded_frame = true;

                            // Pad guest frame cycle limits up to full frame metrics
                            if (cyclesInFrame < CyclesPerFrame) {
                                const remaining = CyclesPerFrame - cyclesInFrame;
                                wideRegs[RFCL] += remaining;
                                cyclesInFrame = CyclesPerFrame;
                            }
                        }
                    } else {
                        // If the guest has already yielded, it is consuming time slices
                        // up to the hardware frame boundary limit without running instruction loops
                        cyclesInFrame += cyclesToRun;
                    }

                    // --- MASTER HARDWARE FRAME TRIGGER ---
                    if (cyclesInFrame >= CyclesPerFrame) {
                        if (yielded_frame) {
                            // The guest explicitly finished drawing its frame!
                            // It is now safe to show this complete image to the world.
                            if (comptime hooks.frameHook) |fh| {
                                try fh(this);
                            }

                            yielded_frame = false;
                            ns_accum = 0; // Sync the real-world clock anchor
                        }

                        // Always balance the structural metrics
                        cyclesInFrame -= CyclesPerFrame;
                        wideRegs[RFCL] = cyclesInFrame;
                    }
                }

                // Clean OS thread resting
                if (ns_accum < NsPerCycle) {
                    const duration = std.Io.Duration.fromMilliseconds(1);
                    _ = try this.io.sleep(duration, .awake);
                }
            }
        }

        const Status = enum {
            Ok,
            Yield,
        };

        pub fn exec(this: *@This(), totalCycles: u32, comptime isCoProcessor: bool) !Status {
            @setRuntimeSafety(false);
            @setEvalBranchQuota(12000);

            var cycles = totalCycles;

            if (this.registers.registers()[@intFromEnum(RegisterID.IP)] >= this.instructionBuffer.len) {
                @branchHint(.unlikely);
                return error.AbruptProgramEOF;
            }

            var instruction = this.instructionBuffer[this.registers.registers()[@intFromEnum(RegisterID.IP)]];
            DISPATCH: switch (@as(OpCode, @enumFromInt(instruction.opcode))) {
                .hlt => {
                    this.nonidxRegisters.flags.halted = true;
                    return .Ok;
                },
                .resume_skip => {
                    if (comptime !isCoProcessor) {
                        const code = InterruptToID(Interrupt.InvalidInstruction);
                        this.fireInterrupt(code, hooks);
                    }
                    this.nonidxRegisters.flags.policy = .resume_skip;
                    this.nonidxRegisters.flags.halted = true;
                    return .Ok;
                },
                .resume_at => {
                    this.nonidxRegisters.flags.policy = .resume_at;
                    this.nonidxRegisters.flags.halted = true;
                    return .Ok;
                },
                .retry => {
                    this.nonidxRegisters.flags.policy = .resume_retry;
                    this.nonidxRegisters.flags.halted = true;
                    return .Ok;
                },
                .b => {
                    const decoded: InstructionDstSrc = @bitCast(instruction);
                    const doubles = this.registers.doubleRegisters();

                    const newIP = this.mergeRegs(decoded.dst, decoded.src);
                    const IP = doubleRegIndex(.IP);
                    const JR = doubleRegIndex(.JR);

                    this.nonidxRegisters.previousInstructionLength = 1;

                    doubles[IP] += 1;
                    doubles[JR] = doubles[IP];
                    doubles[IP] = newIP;

                    this.tickClock(1);
                    cycles -= 1;
                    if (cycles == 0) {
                        @branchHint(.unlikely);
                        return .Ok;
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

                    this.nonidxRegisters.previousInstructionLength = 1;

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
                        return .Ok;
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

                    this.nonidxRegisters.previousInstructionLength = 1;

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
                        return .Ok;
                    }

                    instruction = this.instructionBuffer[doubles[IP]];
                    continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
                },
                inline .bnf, .bnt => |which| {
                    const decoded: InstructionDst = @bitCast(instruction);
                    const doubles = this.registers.doubleRegisters();

                    const IP = doubleRegIndex(.IP);
                    const JR = doubleRegIndex(.JR);

                    this.nonidxRegisters.previousInstructionLength = 1;

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
                        return .Ok;
                    }

                    instruction = this.instructionBuffer[doubles[IP]];
                    continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
                },
                .yield_frame => {
                    this.nonidxRegisters.previousInstructionLength = 1;
                    const wideRegisters = this.registers.doubleRegisters();
                    wideRegisters[doubleRegIndex(.IP)] += 1;

                    while (cycles > 0) {
                        const chunk: u8 = if (cycles > 255) 255 else @truncate(cycles);
                        this.tickClock(chunk);
                        cycles -= chunk;
                    }
                    return .Yield;
                },
                .lea => {
                    // lea [high] [low] | [32bit constant]
                    this.nonidxRegisters.previousInstructionLength = 2;

                    const wideRegisters = this.registers.doubleRegisters();
                    const registers = this.registers.registers();

                    if (wideRegisters[doubleRegIndex(.IP)] + 1 >= this.instructionBuffer.len) {
                        @branchHint(.unlikely);
                        return error.AbruptProgramEOF;
                    }

                    const decoded: InstructionDstSrc = @bitCast(instruction);
                    const address: u32 = @bitCast(this.instructionBuffer[wideRegisters[doubleRegIndex(.IP)] + 1]);

                    wideRegisters[doubleRegIndex(.IP)] += 2;

                    registers[decoded.dst] = @truncate(address >> 16);
                    registers[decoded.src] = @truncate(address);

                    const consumed = InstructionTable[@intFromEnum(OpCode.lea)].cycles;
                    this.tickClock(consumed);
                    cycles = if (consumed > cycles) 0 else cycles - consumed;

                    if (cycles == 0) {
                        @branchHint(.unlikely);
                        return .Ok;
                    }
                    if (wideRegisters[doubleRegIndex(.IP)] >= this.instructionBuffer.len) {
                        @branchHint(.unlikely);
                        return error.AbruptProgramEOF;
                    }
                    instruction = this.instructionBuffer[wideRegisters[doubleRegIndex(.IP)]];

                    continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
                },
                inline else => |op| {
                    if (comptime !isCoProcessor) {
                        if (op == .sync_mov or
                            op == .sync_write or op == .sync_hwrite or op == .sync_read or op == .sync_hread)
                        {
                            const code = InterruptToID(Interrupt.InvalidInstruction);
                            this.fireInterrupt(code, hooks);
                            return .Ok;
                        }
                    }

                    if (comptime hooks.hasAnyDebug()) {
                        const h = hooks;
                        switch (comptime op) {
                            .mov, .mov_c, .mov_hreg => {
                                const dstReg = @as(InstructionDst, @bitCast(instruction)).dst;
                                const srcVal: u16 = switch (comptime op) {
                                    .mov => this.registers.registers()[@as(InstructionDstSrc, @bitCast(instruction)).src],
                                    .mov_c => @truncate(@as(InstructionDst, @bitCast(instruction)).payload),
                                    .mov_hreg => @as(u8, @truncate(this.registers.registers()[@as(InstructionDstSrc, @bitCast(instruction)).src])),
                                    else => unreachable,
                                };
                                if (h.onRegisterModify) |onRegisterModify| {
                                    onRegisterModify(this, dstReg, this.registers.registers()[dstReg], srcVal);
                                }
                            },
                            .mov_av, .mov_aev, .mov_hav, .mov_heav, .mov_aevi, .mov_haevi, .mov_aevd, .mov_haevd => {
                                const psr: u8, const por: u16, const val: u16 = switch (comptime op) {
                                    .mov_av => blk: {
                                        const decoded: InstructionDstAddrSrc = @bitCast(instruction);
                                        const psr = 0;
                                        const por = this.registers.registers()[decoded.dPOR];
                                        const val = this.registers.registers()[@as(InstructionDstSrc, @bitCast(instruction)).src];
                                        break :blk .{ psr, por, val };
                                    },
                                    .mov_aev, .mov_aevi, .mov_aevd => blk: {
                                        const decoded: InstructionDstAddrXSrc = @bitCast(instruction);
                                        const psr: u8 = @truncate(this.registers.registers()[decoded.dPSR]);
                                        const por = this.registers.registers()[decoded.dPOR];
                                        const val = this.registers.registers()[decoded.src];
                                        break :blk .{ psr, por, val };
                                    },
                                    .mov_hav => blk: {
                                        const decoded: InstructionDstAddrSrc = @bitCast(instruction);
                                        const psr: u8 = 0;
                                        const por = this.registers.registers()[decoded.dPOR];
                                        const val = @as(u8, @truncate(this.registers.registers()[decoded.src]));
                                        break :blk .{ psr, por, @as(u16, val) };
                                    },
                                    .mov_heav, .mov_haevi, .mov_haevd => blk: {
                                        const decoded: InstructionDstAddrXSrc = @bitCast(instruction);
                                        const psr: u8 = @truncate(this.registers.registers()[decoded.dPSR]);
                                        const por = this.registers.registers()[decoded.dPOR];
                                        const val = @as(u8, @truncate(this.registers.registers()[decoded.src]));
                                        break :blk .{ psr, por, @as(u16, val) };
                                    },
                                    else => unreachable,
                                };
                                if (h.onMemoryAccess) |onMemoryAccess| {
                                    onMemoryAccess(this, psr, por, .write, val);
                                }
                            },
                            .mov_ra, .mov_rae, .mov_hra, .mov_hrae, .mov_raei, .mov_hraei, .mov_raed, .mov_hraed => {
                                switch (comptime op) {
                                    // Simple (page-0) reads — buffer is always non-null
                                    .mov_ra, .mov_hra => {
                                        const decoded: InstructionDstSrcAddr = @bitCast(instruction);
                                        const base: isize = @intCast(this.registers.registers()[decoded.sPOR]);
                                        const offset: isize = @intCast(decoded.offset);
                                        const addr = base + offset;
                                        const sz: isize = if (comptime op == .mov_ra) 2 else 1;
                                        if (addr >= 0 and addr + sz <= PageSize) {
                                            const val: u16 = if (comptime op == .mov_ra)
                                                std.mem.readInt(u16, this.mmu.pages[0].buffer.?[@as(usize, @intCast(addr))..][0..2], .little)
                                            else
                                                this.mmu.pages[0].buffer.?[@as(usize, @intCast(addr))];

                                            if (h.onMemoryAccess != null and h.onRegisterModify != null) {
                                                h.onMemoryAccess.?(this, 0, @truncate(@as(u32, @intCast(addr))), .read, val);
                                                h.onRegisterModify.?(this, decoded.dst, this.registers.registers()[decoded.dst], val);
                                            }
                                        }
                                    },
                                    // Extended (full-word) reads
                                    .mov_rae, .mov_raei, .mov_raed => {
                                        const decoded: InstructionDstSrcAddrX = @bitCast(instruction);
                                        const pageID: u8 = @truncate(this.registers.registers()[decoded.sPSR]);
                                        const base: isize = @intCast(this.registers.registers()[decoded.sPOR]);
                                        const offset: isize = @intCast(decoded.offset);
                                        const addr = base + offset;
                                        if (this.mmu.pages[pageID].buffer != null and addr >= 0 and addr + 2 <= PageSize) {
                                            const val = std.mem.readInt(u16, this.mmu.pages[pageID].buffer.?[@as(usize, @intCast(addr))..][0..2], .little);

                                            if (h.onMemoryAccess != null and h.onRegisterModify != null) {
                                                h.onMemoryAccess.?(this, pageID, @truncate(@as(u32, @intCast(addr))), .read, val);
                                                h.onRegisterModify.?(this, decoded.dst, this.registers.registers()[decoded.dst], val);
                                            }
                                        }
                                    },
                                    // Extended (byte) reads
                                    .mov_hrae, .mov_hraei, .mov_hraed => {
                                        const decoded: InstructionDstSrcAddrX = @bitCast(instruction);
                                        const pageID: u8 = @truncate(this.registers.registers()[decoded.sPSR]);
                                        const base: isize = @intCast(this.registers.registers()[decoded.sPOR]);
                                        const offset: isize = @intCast(decoded.offset);
                                        const addr = base + offset;
                                        if (this.mmu.pages[pageID].buffer != null and addr >= 0 and addr + 1 <= PageSize) {
                                            const val: u16 = this.mmu.pages[pageID].buffer.?[@as(usize, @intCast(addr))];

                                            if (h.onMemoryAccess != null and h.onRegisterModify != null) {
                                                h.onMemoryAccess.?(this, pageID, @truncate(@as(u32, @intCast(addr))), .read, val);
                                                h.onRegisterModify.?(this, decoded.dst, this.registers.registers()[decoded.dst], val);
                                            }
                                        }
                                    },
                                    else => unreachable,
                                }
                            },
                            else => {},
                        }
                    }

                    this.nonidxRegisters.previousInstructionLength = 1;

                    const wideRegisters = this.registers.doubleRegisters();
                    const IP = doubleRegIndex(.IP);

                    wideRegisters[IP] += 1;

                    const consumed = InstructionTable[@intFromEnum(op)].cycles;
                    InstructionTable[@intFromEnum(op)].handler(this, instruction) catch |e| {
                        const code = if (e == Interrupt.UserInterrupt)
                            this.nonidxRegisters.flags.interruptCode
                        else
                            InterruptToID(e);

                        this.fireInterrupt(code, hooks);
                        // I'm not sure if this should continue or not...
                    };

                    this.tickClock(consumed);

                    cycles = if (consumed > cycles) 0 else cycles - consumed;
                    if (cycles == 0) {
                        @branchHint(.unlikely);
                        return .Ok;
                    }
                    if (wideRegisters[IP] >= this.instructionBuffer.len) {
                        @branchHint(.unlikely);
                        return error.AbruptProgramEOF;
                    }
                    instruction = this.instructionBuffer[wideRegisters[IP]];

                    continue :DISPATCH @as(OpCode, @enumFromInt(instruction.opcode));
                },
            }
        }

        fn fireInterrupt(this: *@This(), code: u8) void {
            if (comptime @import("builtin").mode == .Debug) {
                const _ip = this.registers.doubleRegisters()[doubleRegIndex(.IP)];

                this.log.trace("Interrupt {} fired at:\n IP: {}/{}\n Op: {}\n", .{
                    code,
                    _ip,
                    this.instructionBuffer.len,
                    @as(OpCode, @enumFromInt(this.instructionBuffer[_ip - this.nonidxRegisterBackBuffer.previousInstructionLength].opcode)),
                });
            }

            const interruptTable = this.getIVTableSpan();
            const handlerAddress = interruptTable[code];

            if (handlerAddress == 0) {
                this.dumpContext();
                this.log.fatal("Unhandled interrupt/fault has occurred.", .{});
                @trap();
            }

            const mainToCoBoundryCross = !this.nonidxRegisters.flags.isCoProcessor;

            const IP = doubleRegIndex(.IP);
            const JR = doubleRegIndex(.JR);

            const registers = this.registers.registers();
            const mainCoreRegisters = this.registerBackBuffer.registers();
            const wideRegisters = this.registers.doubleRegisters();
            const mainCoreWideRegisters = this.registerBackBuffer.doubleRegisters();

            // swap context to co-processor.
            // this will swap the registers and page0.
            // I have decided that pages 1..255 will
            // remain available as shared resources so that the co-processor is more useful
            // to the user outside of just error correction.
            if (mainToCoBoundryCross) {
                this.swapContext();

                registers[@intFromEnum(RegisterID.GCL)] = mainCoreRegisters[@intFromEnum(RegisterID.GCL)];
                registers[@intFromEnum(RegisterID.GCH)] = mainCoreRegisters[@intFromEnum(RegisterID.GCH)];

                this.nonidxRegisters.flags.isCoProcessor = true;
                this.nonidxRegisters.flags.interruptCode = code;
                this.nonidxRegisters.flags.halted = false;

                // initialize stack
                const DefaultStackSize = 1024;
                registers[@intFromEnum(RegisterID.SB)] = DefaultStackSize;
                registers[@intFromEnum(RegisterID.SP)] = DefaultStackSize;
                registers[@intFromEnum(RegisterID.SH)] = 0;

                // if we are first crossing the boundry then we want to write IP before JR so that JR points to the same thing as IP
                // and they can't "return" from the handler to some un-initialized address
                wideRegisters[IP] = handlerAddress;
            }

            // call handler, linking JR to the current IP.
            // this allows for recursive handlers like any other function.
            wideRegisters[JR] = wideRegisters[IP];

            // this is reduntant if we are crossing the boundry here, but necessary if
            // we are recursively calling a handler. I honestly think a second write is
            // cheap enough that it doesn't need a branch + write.
            // A write here costs what? tens of cycles maybe depending on where the memory
            // is cached, but given that it's used often in this method it might be in a register at this point
            // where as a branch might cost roughly the same amount anyway.
            wideRegisters[IP] = handlerAddress;

            while (!this.nonidxRegisters.flags.halted) {
                this.runCoProcessor() catch {
                    this.dumpContext();
                    this.log.fatal("Unrecoverable fault happened in co-processor", .{});
                    @trap();
                };
            }

            switch (this.nonidxRegisters.flags.policy) {
                .resume_retry => {
                    // retry the failed instruction, ip has already been incremented before fault occurred so we rewind by 1 instruction.
                    mainCoreWideRegisters[IP] -= this.nonidxRegisterBackBuffer.previousInstructionLength;
                },
                .resume_skip => {
                    // skip the failed instruction, no further work needed since IP has already been incremented prior to the fault
                },
                .resume_at => {
                    // resume_at method will write the new address to our IP before halting the co-processor. So we need to store our IP to maincore.IP
                    // and store the maincore.IP (instruction after the failed instruction) into the maincore.JR

                    mainCoreWideRegisters[JR] = mainCoreWideRegisters[IP];
                    mainCoreWideRegisters[IP] = wideRegisters[IP];
                },
            }

            if (mainToCoBoundryCross) {
                // recore change to global cycle counter
                mainCoreRegisters[@intFromEnum(RegisterID.GCL)] = registers[@intFromEnum(RegisterID.GCL)];
                mainCoreRegisters[@intFromEnum(RegisterID.GCH)] = registers[@intFromEnum(RegisterID.GCH)];

                this.nonidxRegisters.flags.isCoProcessor = false;

                this.swapContext();
            }
        }

        pub fn dumpContext(this: *@This()) void {
            const totalPagesAllocated, const totalMemAllocated = blk: {
                var tpa: usize = 0;
                var tma: usize = 0;

                for (this.mmu.pages) |page| {
                    if (page.buffer != null) {
                        tpa += 1;
                        tma += PageSize;
                    }
                }

                break :blk .{ tpa, tma };
            };

            std.debug.print(
                \\MainCore: [{} Pages, {} Bytes]
                \\Instruction Count: {}
                \\Instruction Pointer: {}
                \\
            , .{
                totalPagesAllocated,        totalMemAllocated,
                this.instructionBuffer.len,
                this.registers.doubleRegisters()[
                    doubleRegIndex(.IP)
                ],
            });

            if (this.nonidxRegisters.flags.isCoProcessor) {
                dumpIndexableRegisters(&this.registerBackBuffer);
                dumpNonIndexableRegisters(&this.nonidxRegisterBackBuffer);
                std.debug.print("Secondary-Core:\n", .{});
                dumpIndexableRegisters(&this.registers);
                dumpNonIndexableRegisters(&this.nonidxRegisters);
            } else {
                dumpIndexableRegisters(&this.registers);
                dumpNonIndexableRegisters(&this.nonidxRegisters);
                std.debug.print("Secondary-Core:\n", .{});
                dumpIndexableRegisters(&this.registerBackBuffer);
                dumpNonIndexableRegisters(&this.nonidxRegisterBackBuffer);
            }

            dumpMMIOInfo(&this.mmu.pages[MMU.MMIOPage]);
            this.dumpExtensionContext();
        }

        fn dumpIndexableRegisters(regs: *Registers) void {
            const registers = regs.registers();
            std.debug.print(
                \\General Registers:
                \\ R0: {X:0>4} R1: {X:0>4} R2: {X:0>4} R3: {X:0>4}
                \\ R4: {X:0>4} R5: {X:0>4} R6: {X:0>4} R7: {X:0>4}
                \\ R8: {X:0>4} R9: {X:0>4} RA: {X:0>4} RB: {X:0>4}
                \\ RC: {X:0>4} RD: {X:0>4} RE: {X:0>4} RF: {X:0>4}
                \\
                \\Global Cycles Executed: {}
                \\Frame Cycles Executed: {}
                \\
            , .{
                registers[0],                                 registers[1],                                 registers[2],  registers[3],
                registers[4],                                 registers[5],                                 registers[6],  registers[7],
                registers[8],                                 registers[9],                                 registers[10], registers[11],
                registers[12],                                registers[13],                                registers[14], registers[15],
                regs.doubleRegisters()[doubleRegIndex(.GCL)], regs.doubleRegisters()[doubleRegIndex(.FCL)],
            });

            const stackUsed = registers[@intFromEnum(RegisterID.SB)] - registers[@intFromEnum(RegisterID.SP)];
            const stackSize = registers[@intFromEnum(RegisterID.SB)] - registers[@intFromEnum(RegisterID.SH)];
            std.debug.print(
                \\ Stack ({} / {} bytes)
                \\ SH: {X:0>4} SP: {X:0>4} SB: {X:0>4}
                \\
            , .{
                stackUsed,
                stackSize,
                registers[@intFromEnum(RegisterID.SH)],
                registers[@intFromEnum(RegisterID.SP)],
                registers[@intFromEnum(RegisterID.SB)],
            });
        }

        fn dumpNonIndexableRegisters(registers: *NonIndexableRegisters) void {
            std.debug.print(
                \\ Flags:
                \\   Halt: {}
                \\   Interrupt-Code: {}
                \\   CoProcessor, Policy: {}, {}
                \\ IVT: {x:0>4}
                \\ Last-Instruction-Size: {}
                \\
            , .{
                registers.flags.halted,
                registers.flags.interruptCode,
                registers.flags.isCoProcessor,
                registers.flags.policy,
                registers.interruptVectorTable,
                registers.previousInstructionLength,
            });
        }

        fn dumpMMIOInfo(mmioPage: *PageEntry) void {
            std.debug.print(
                \\ MMIO-Page: {any}
                \\ Permissions[R/W/M]: {}/{}/{}
                \\
            , .{
                if (mmioPage.buffer) |buf| @as(?usize, @intFromPtr(buf)) else null,
                mmioPage.permissions.read,
                mmioPage.permissions.write,
                mmioPage.permissions.isMapped,
            });
        }

        fn dumpExtensionContext(this: *@This()) void {
            var iter = this.extensions.iterator();

            while (iter.next()) |entry| {
                entry.value_ptr.crashDump(this);
            }
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
}

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
// TODO: Finish refactor with hooks
pub const PageAlign = std.mem.Alignment.fromByteUnits(PageSize);
pub const PageBuffer = *align(PageAlign.toByteUnits()) [PageSize]u8;
pub const AlignedPageSlice = []align(PageAlign.toByteUnits()) u8;

pub const PageEntry = struct {
    permissions: PagePermissions,
    buffer: ?PageBuffer,
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

        const page0 = try this.requestPage(0, null);
        errdefer this.freePage(0);

        @memset(page0, 0);

        const mmioPage = try this.requestPage(MMIOPage, null);
        errdefer this.freePage(MMIOPage);

        @memset(mmioPage, 0);

        return this;
    }

    pub inline fn hasPage(this: *@This(), pageID: u8) bool {
        return this.pages[pageID].buffer != null and (this.pages[pageID].permissions.read or this.pages[pageID].permissions.read);
    }

    pub inline fn getPage(this: *@This(), pageID: u8) ?PageBuffer {
        return this.pages[pageID].buffer;
    }

    pub inline fn tryGetPage(this: *@This(), pageID: u8, bufferPtr: *PageBuffer) bool {
        if (this.hasPage(pageID)) {
            bufferPtr.* = this.pages[pageID].buffer.?;
            return true;
        }
        return false;
    }

    pub fn allocatePageSlice(this: *@This()) !AlignedPageSlice {
        return try this.allocator.alignedAlloc(u8, PageAlign, PageSize);
    }

    pub fn requestPage(this: *@This(), pageID: u8, permissions: ?PagePermissions) !PageBuffer {
        const perm = if (permissions) |p| p else PagePermissions.ReadWrite;

        if (perm.isMapped) {
            @panic("Mapped pages must not be requested through 'requestPage' use 'mapPage' instead.");
        }

        // allocate new page
        if (this.pages[pageID].buffer == null) {
            const pageBuffer = try this.allocatePageSlice();
            errdefer this.allocator.free(pageBuffer);

            this.pages[pageID] = .{
                .permissions = perm,
                .buffer = pageBuffer[0..PageSize],
            };

            return this.pages[pageID].buffer.?;
        }

        // reallocate existing page (e.g. change permissions without changing data)
        // this can't be done if a page is a mapped page (those must always be readonly)
        // which is why we have the validation up top for if perm.isMapped. The VM itself should
        // manage whether to map or request pages under a given syscall which is why the mmu treats
        // it as unreachable.
        this.pages[pageID].permissions = perm;
        return this.pages[pageID].buffer.?;
    }

    pub fn mapPage(this: *@This(), id: u8, buffer: PageBuffer) !void {
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
                allocator.free(@as([]u8, bufPtr[0..PageSize]));
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
    InvalidStackRelocation,
    MisalignedStackRelocation,
    ExtensionInterrupt,
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
        Interrupt.InvalidStackRelocation => 7,
        Interrupt.MisalignedStackRelocation => 8,
        Interrupt.ExtensionInterrupt => 64,
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
                if (comptime width == .half) {
                    vm.registers.registers()[decoded.dst] = @as(u8, @truncate(vm.registers.registers()[decoded.src]));
                } else {
                    vm.registers.registers()[decoded.dst] = vm.registers.registers()[decoded.src];
                }
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

                std.mem.writeInt(moveType, vm.mmu.pages[0].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], @truncate(vm.registers.registers()[decoded.src]), .little);

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

                std.mem.writeInt(moveType, vm.mmu.pages[pageID].buffer.?[@as(usize, @intCast(base + offset))..][0..@sizeOf(moveType)], @truncate(vm.registers.registers()[decoded.src]), .little);

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
                const shift: u4 = @truncate(vm.registers.registers()[de.src]);
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
                vm.registers.registers()[de.dst] = std.math.rotl(u16, vm.registers.registers()[de.dst], vm.registers.registers()[de.src]);
            }
        }.do, 1 },
        .ror => .{ struct {
            pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                const de: InstructionDstSrc = @bitCast(i);
                vm.registers.registers()[de.dst] = std.math.rotr(u16, vm.registers.registers()[de.dst], vm.registers.registers()[de.src]);
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
                    // TODO: verify this logic
                    const low: i8 = @bitCast(@as(u8, @truncate(vm.registers.registers()[de.dst])));
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
    .vseteq2,  .vsetneq2, .vsetlt2,  .vsetle2,  .vsetgt2,
    .vsetge2,  .vreduce2, .vsplat2,  .vldc2,    .viadd2,
    .visub2,   .vimul2,   .visetlt2, .visetle2, .visetgt2,
    .visetge2, .vselect2, .vswap2,   .vsar2,    .vabs2,
    .vsign2,   .vmin2,    .vmax2,    .vrol2,    .vror2,
    .vimin2,   .vimax2,
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
                .Sub => va[0] - va[1],
                .Mul => @reduce(.Mul, va),
                .BitAnd => @reduce(.And, va),
                .BitOr => @reduce(.Or, va),
                .BitXor => @reduce(.Xor, va),
                .Min => @reduce(.Min, va),
                .Max => @reduce(.Max, va),
                .And => a: {
                    const bool0 = va[0] != 0;
                    const bool1 = va[1] != 0;
                    break :a if (bool0 and bool1) @as(u8, 1) else @as(u8, 0);
                },
                .Or => a: {
                    const bool0 = va[0] != 0;
                    const bool1 = va[1] != 0;
                    break :a if (bool0 or bool1) @as(u8, 1) else @as(u8, 0);
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
                    const zv2: @Vector(2, i8) = @splat(0);
                    const pos = vb2vi8(sv > zv2);
                    const neg = vb2vi8(sv < zv2);
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
                .vrol2 => std.math.rotl(@Vector(2, u8), v, s[0]),
                .vror2 => std.math.rotr(@Vector(2, u8), v, s[0]),
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
            .vimin2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @as(@Vector(2, u8), @bitCast(@min(
                        @as(@Vector(2, i8), @bitCast(a)),
                        @as(@Vector(2, i8), @bitCast(b)),
                    )));
                }
            }.f,
            .vimax2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return @as(@Vector(2, u8), @bitCast(@max(
                        @as(@Vector(2, i8), @bitCast(a)),
                        @as(@Vector(2, i8), @bitCast(b)),
                    )));
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
                    return vb2vu8(a == b);
                }
            }.f,
            .vsetneq2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(a != b);
                }
            }.f,
            .vsetlt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(a < b);
                }
            }.f,
            .vsetle2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(a <= b);
                }
            }.f,
            .vsetgt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(a > b);
                }
            }.f,
            .vsetge2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(a >= b);
                }
            }.f,

            // Comparisons (Signed)
            .visetlt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(@as(@Vector(2, i8), @bitCast(a)) < @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .visetle2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(@as(@Vector(2, i8), @bitCast(a)) <= @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .visetgt2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(@as(@Vector(2, i8), @bitCast(a)) > @as(@Vector(2, i8), @bitCast(b)));
                }
            }.f,
            .visetge2 => struct {
                pub fn f(a: @Vector(2, u8), b: @Vector(2, u8)) @Vector(2, u8) {
                    return vb2vu8(@as(@Vector(2, i8), @bitCast(a)) >= @as(@Vector(2, i8), @bitCast(b)));
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

inline fn vb2vu8(vb: @Vector(2, bool)) @Vector(2, u8) {
    const trues: @Vector(2, u8) = .{ 1, 1 };
    const falses: @Vector(2, u8) = .{ 0, 0 };
    // Wherever the vector condition is true, pick from trues, else pick from falses
    return @select(u8, vb, trues, falses);
}

inline fn vb2vi8(vb: @Vector(2, bool)) @Vector(2, i8) {
    const trues: @Vector(2, i8) = .{ 1, 1 };
    const falses: @Vector(2, i8) = .{ 0, 0 };
    return @select(i8, vb, trues, falses);
}

pub const MinimumStackSize = 256;

const StackOp = meta.Subset(OpCode, &.{
    .push8,  .pop8,  .push16, .pop16, .bump_r, .bump_c, .stackset,
    .push32, .pop32,
});

fn StackFactory(comptime op: StackOp) InstructionInfo {
    comptime {
        const SP = @intFromEnum(RegisterID.SP);
        const SB = @intFromEnum(RegisterID.SB);
        const SH = @intFromEnum(RegisterID.SH);

        return switch (op) {
            .stackset => InstructionInfo{
                .handler = struct {
                    pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                        const de: InstructionDstSrc = @bitCast(i);

                        const registers = vm.registers.registers();

                        if (registers[SP] != registers[SB]) {
                            // cannot use stackset when the stack is not empty.
                            @branchHint(.unlikely);
                            return Interrupt.InvalidStackRelocation;
                        }

                        const baseAddress = registers[de.dst];
                        const len = registers[de.src];

                        if (baseAddress % @sizeOf(u32) != 0) {
                            @branchHint(.unlikely);
                            return Interrupt.MisalignedStackRelocation;
                        }

                        if (len < MinimumStackSize) {
                            @branchHint(.unlikely);
                            return Interrupt.InvalidStackRelocation;
                        }

                        // if baseAddress < len then baseAddress-len will be a negative number and therefore (since stack grows down)
                        // SH will become larger than SB which is invalid.
                        if (len > baseAddress) {
                            @branchHint(.unlikely);
                            return Interrupt.InvalidStackRelocation;
                        }

                        registers[SB] = baseAddress;
                        registers[SP] = baseAddress;
                        registers[SH] = baseAddress - len;
                    }
                }.do,
                .cycles = 1,
            },
            .bump_r => InstructionInfo{
                .handler = struct {
                    pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                        const de: InstructionDst = @bitCast(i);
                        const registers = vm.registers.registers();

                        const amount: i16 = @bitCast(registers[de.dst]);

                        const sp = registers[SP];
                        const sb = registers[SB];
                        const sh = registers[SH];

                        const wideSP: i32 = @intCast(sp);
                        const wideSB: i32 = @intCast(sb);
                        const wideSH: i32 = @intCast(sh);

                        const nextSP = wideSP + amount;

                        if (nextSP < wideSH) {
                            @branchHint(.unlikely);
                            return Interrupt.StackOverflow;
                        }

                        if (nextSP > wideSB) {
                            @branchHint(.unlikely);
                            return Interrupt.StackUnderflow;
                        }

                        registers[SP] = @intCast(nextSP);
                    }
                }.do,
                .cycles = 1,
            },
            .bump_c => InstructionInfo{
                .handler = struct {
                    pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                        const de: InstructionDst = @bitCast(i);
                        const registers = vm.registers.registers();

                        const amount: i16 = @bitCast(@as(u16, @truncate(de.payload)));

                        const sp = registers[SP];
                        const sb = registers[SB];
                        const sh = registers[SH];

                        const wideSP: i32 = @intCast(sp);
                        const wideSB: i32 = @intCast(sb);
                        const wideSH: i32 = @intCast(sh);

                        const nextSP = wideSP + amount;

                        if (nextSP < wideSH) {
                            @branchHint(.unlikely);
                            return Interrupt.StackOverflow;
                        }

                        if (nextSP > wideSB) {
                            @branchHint(.unlikely);
                            return Interrupt.StackUnderflow;
                        }

                        registers[SP] = @intCast(nextSP);
                    }
                }.do,
                .cycles = 1,
            },
            inline .push8, .push16 => InstructionInfo{
                .handler = struct {
                    pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                        const vTy = if (comptime op == .push8)
                            u8
                        else
                            u16;

                        const size = @sizeOf(vTy);

                        const de: InstructionDst = @bitCast(i);
                        const registers = vm.registers.registers();
                        const sp = registers[SP];
                        const sh = registers[SH];

                        if (size > sp or sp - size < sh) {
                            @branchHint(.unlikely);
                            return Interrupt.StackOverflow;
                        }

                        registers[SP] -= size;

                        const value: vTy = @truncate(registers[de.dst]);
                        const page0 = vm.getPage0();

                        const address = @as([*]u8, @ptrCast(&page0[registers[SP]]));
                        std.mem.writeInt(vTy, address[0..size], value, .little);
                    }
                }.do,
                .cycles = 1,
            },
            inline .pop8, .pop16 => InstructionInfo{
                .handler = struct {
                    pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                        const vTy = if (comptime op == .push8)
                            u8
                        else
                            u16;

                        const size = @sizeOf(vTy);

                        const de: InstructionDst = @bitCast(i);
                        const registers = vm.registers.registers();
                        const sp = registers[SP];
                        const sb = registers[SB];

                        if (sp + size > sb) {
                            @branchHint(.unlikely);
                            return Interrupt.StackUnderflow;
                        }
                        const page0 = vm.getPage0();
                        const address = @as([*]u8, @ptrCast(&page0[registers[SP]]));
                        const value: vTy = std.mem.readInt(vTy, address[0..size], .little);

                        registers[SP] += size;
                        registers[de.dst] = value;
                    }
                }.do,
                .cycles = 1,
            },
            .push32 => InstructionInfo{
                .handler = struct {
                    pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                        const vTy = u32;

                        const size = @sizeOf(vTy);

                        const de: InstructionDstSrc = @bitCast(i);
                        const registers = vm.registers.registers();
                        const sp = registers[SP];
                        const sh = registers[SH];

                        if (size > sp or sp - size < sh) {
                            @branchHint(.unlikely);
                            return Interrupt.StackOverflow;
                        }

                        registers[SP] -= size;

                        const low = registers[de.dst];
                        const high = registers[de.src];

                        const page0 = vm.getPage0();

                        const address = @as([*]u8, @ptrCast(&page0[registers[SP]]));
                        std.mem.writeInt(u16, address[0..2], low, .little);
                        std.mem.writeInt(u16, address[2..4], high, .little);
                    }
                }.do,
                .cycles = 1,
            },
            .pop32 => InstructionInfo{
                .handler = struct {
                    pub inline fn do(vm: *TESVM, i: Instruction) Interrupt!void {
                        const vTy = u32;

                        const size = @sizeOf(vTy);

                        const de: InstructionDstSrc = @bitCast(i);
                        const registers = vm.registers.registers();
                        const sp = registers[SP];
                        const sb = registers[SB];

                        if (sp + size > sb) {
                            @branchHint(.unlikely);
                            return Interrupt.StackUnderflow;
                        }
                        const page0 = vm.getPage0();
                        const address = @as([*]u8, @ptrCast(&page0[registers[SP]]));
                        //const value: vTy = std.mem.readInt(vTy, address[0..size], .little);

                        registers[de.dst] = std.mem.readInt(u16, address[0..2], .little);
                        registers[de.src] = std.mem.readInt(u16, address[2..4], .little);

                        registers[SP] += size;
                        //vm.registers.doubleRegisters()[TESVM.wideRegIndex(de.dst)] = value;
                    }
                }.do,
                .cycles = 1,
            },
        };
    }
}

// msc codes

pub inline fn implSelect(vm: *TESVM, i: Instruction) Interrupt!void {
    // select [dst] [srcA] [srcB] [cond]
    const de: InstructionDstSrc3 = @bitCast(i);
    const registers = vm.registers.registers();

    registers[de.dst] = if (registers[de.src2] != 0) registers[de.src0] else registers[de.src1];
}

pub inline fn implInt(vm: *TESVM, i: Instruction) Interrupt!void {
    // int r
    const de: InstructionDst = @bitCast(i);
    const code: u8 = @truncate(vm.registers.registers()[de.dst]);
    vm.nonidxRegisters.flags.interruptCode = code;
    return Interrupt.UserInterrupt;
}

pub inline fn implSyscall(vm: *TESVM, i: Instruction) Interrupt!void {
    const de: EventInstruction = @bitCast(i);

    const ext = vm.extensions.getPtr(de.poolID);

    if (ext) |e| {
        try e.trigger(vm, de);
    }
}

pub inline fn implSwap(vm: *TESVM, i: Instruction) Interrupt!void {
    const de: InstructionDstSrc = @bitCast(i);
    const registers = vm.registers.registers();

    const tmp = registers[de.dst];
    registers[de.dst] = registers[de.src];
    registers[de.src] = tmp;
}

pub inline fn implTrap(vm: *TESVM, _: Instruction) Interrupt!void {
    vm.dumpContext();
    @panic("User Trap has fired!");
}

pub inline fn implIVS(vm: *TESVM, i: Instruction) Interrupt!void {
    const de: InstructionDst2Src2 = @bitCast(i);
    const registers = vm.registers.registers();

    const table = vm.getIVTableSpan();
    const offset: u8 = @truncate(registers[de.src1]);
    const addr = table[offset];

    registers[de.dst0] = @truncate(addr >> 16);
    registers[de.dst1] = @truncate(addr);
}

pub inline fn implBittest(vm: *TESVM, i: Instruction) Interrupt!void {
    const de: InstructionDstSrc2 = @bitCast(i);

    const registers = vm.registers.registers();
    const shift: u4 = @truncate(registers[de.src1]);
    const result = (registers[de.src0] & (@as(u16, 1) << shift)) != 0;

    registers[de.dst] = if (result) 1 else 0;
}

pub inline fn implMcpy(vm: *TESVM, i: Instruction) Interrupt!void {
    // mcpy dstPsr, dstPor, srcPsr, srcPor, len (reg u4)
    const de: InstructionDst2Src2 = @bitCast(i);
    const registers = vm.registers.registers();

    const dPsr: u8 = @truncate(registers[de.dst0]);
    const dPor = registers[de.dst1];

    const sPsr: u8 = @truncate(registers[de.src0]);
    const sPor: u8 = @truncate(registers[de.src1]);

    const len = registers[de.reserved];

    if (len == 0) return;

    const destinationPage = vm.getPageEntry(dPsr);
    const sourcePage = vm.getPageEntry(sPsr);

    if (destinationPage.buffer == null or !destinationPage.permissions.write) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    if (sourcePage.buffer == null or !sourcePage.permissions.read) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    if (@as(usize, dPor) + len > PageSize) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    if (@as(usize, sPor) + len > PageSize) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    const dBuff = destinationPage.buffer.?;
    const sBuff = sourcePage.buffer.?;

    const dEof = dPor + len;
    const sEof = sPor + len;

    @memcpy(dBuff[dPor..dEof], sBuff[sPor..sEof]);
}

pub inline fn implMset(vm: *TESVM, i: Instruction) Interrupt!void {
    // memset [dPsr], [dpor], dLen, regValue(u8)
    const de: InstructionDst2Src2 = @bitCast(i);
    const registers = vm.registers.registers();

    const dPsr: u8 = @truncate(registers[de.dst0]);
    const dPor = registers[de.dst1];

    const len = registers[de.src0];

    if (len == 0) return;

    const val: u8 = @truncate(registers[de.src1]);

    const destinationPage = vm.getPageEntry(dPsr);
    if (destinationPage.buffer == null or !destinationPage.permissions.write) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    if (@as(usize, dPor) + len > PageSize) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    const dBuff = destinationPage.buffer.?;
    const dEof = dPor + len;

    @memset(dBuff[dPor..dEof], val);
}

pub inline fn implMmov(vm: *TESVM, i: Instruction) Interrupt!void {
    // mmov dstPsr, dstPor, srcPsr, srcPor, len (reg u4)
    const de: InstructionDst2Src2 = @bitCast(i);
    const registers = vm.registers.registers();

    const dPsr: u8 = @truncate(registers[de.dst0]);
    const dPor = registers[de.dst1];

    const sPsr: u8 = @truncate(registers[de.src0]);
    const sPor: u8 = @truncate(registers[de.src1]);

    const len = registers[de.reserved];

    if (len == 0) return;

    const destinationPage = vm.getPageEntry(dPsr);
    const sourcePage = vm.getPageEntry(sPsr);

    if (destinationPage.buffer == null or !destinationPage.permissions.write) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    if (sourcePage.buffer == null or !sourcePage.permissions.read) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    if (@as(usize, dPor) + len > PageSize) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    if (@as(usize, sPor) + len > PageSize) {
        @branchHint(.unlikely);
        return Interrupt.PageFault;
    }

    const dBuff = destinationPage.buffer.?;
    const sBuff = sourcePage.buffer.?;

    const dEof = dPor + len;
    const sEof = sPor + len;

    @memmove(dBuff[dPor..dEof], sBuff[sPor..sEof]);
}
