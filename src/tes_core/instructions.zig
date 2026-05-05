const vm = @import("vm.zig");
const std = @import("std");

pub const InstructionCode = enum(u8) {
    nop = 0x00,
    mov = 0x01, // mov reg, reg
    mov_c = 0x02, // mov reg, constant
    mov_av = 0x03, // mov [address], reg
    mov_ra = 0x04, // mov reg, [address]
    mov_aev = 0x05, // mov [address + ext], reg
    mov_rae = 0x06, // mov reg, [address + ext]
    mov_hav = 0x07, // mov [address], (byte) reg
    mov_hra = 0x08, // mov reg, (byte)[address]
    mov_heav = 0x09, // mov reg, (byte)[address + ext]
    mov_hrae = 0x0A, // mov [address + ext], (byte) reg
    add = 0x0B, // add [dest], [src]
    sub = 0x0C,
    mul = 0x0D,
    div = 0x0E, // div [quotient], [remainder], [dividend], [divisor]
    shr = 0x0F,
    shl = 0x10,
    bin_and = 0x11,
    bin_or = 0x12,
    bin_xor = 0x13,
    bin_not = 0x14,
    log_and = 0x15,
    log_or = 0x16,
    log_not = 0x17,
    neg = 0x18,
    vadd2 = 0x19,
    vsub2 = 0x1A,
    vmul2 = 0x1B,
    vshr2 = 0x1C,
    vshl2 = 0x1D,
    vand2 = 0x1E,
    vor2 = 0x1F,
    vxor2 = 0x20,
    vnot2 = 0x21,
    vneg2 = 0x22,
    inc = 0x23,
    dec = 0x24,
    seteq = 0x25, // seteq [result], [a], [b]
    setneq = 0x26,
    setlt = 0x27,
    setle = 0x28,
    setgt = 0x29,
    setge = 0x2A,
    b = 0x2B, // now requires 2 registers
    bt = 0x2C,
    bf = 0x2D,
    push8 = 0x2E,
    push16 = 0x2F,
    pop8 = 0x30,
    pop16 = 0x31,
    bump_r = 0x32, // bump [register-amount]
    bump_c = 0x33, // bump [const-amount]
    mov_aevi = 0x34, // mov [address + ext], reg  -- increments offset byte
    mov_raei = 0x35, // mov reg, [address + ext]
    mov_haevi = 0x36, // mov reg, (byte)[address + ext]
    mov_hraei = 0x37, // mov [address + ext], (byte) reg
    mov_aevd = 0x38, // mov [address + ext], reg  -- decrements offset byte (by size of value)
    mov_raed = 0x39, // mov reg, [address + ext]
    mov_haevd = 0x3A, // mov reg, (byte)[address + ext]
    mov_hraed = 0x3B, // mov [address + ext], (byte) reg
    fma = 0x3C, // fma [a], [b], [c] --> (a = (a * b) + c) TODO: figure out if this is most useful variant of formula
    stackset = 0x3D, // stackset [base], [len]
    int = 0x3E, // int reg
    syscall = 0x3F,
    hlt = 0x40,

    // coprossesor <--> main processor channels
    yield_frame = 0x41,
    resume_skip = 0x42,
    resume_at = 0x43,
    retry = 0x44,
    sync_mov = 0x45,
    sync_write = 0x46,
    sync_hwrite = 0x47,
    sync_read = 0x48,
    sync_hread = 0x49,

    extz = 0x4A,
    exts = 0x4B,
    truncz = 0x4C,
    clamp = 0x4D,
    swap = 0x4E,
    bittest = 0x4F,
    vseteq2 = 0x50,
    vsetneq2 = 0x51,
    vsetlt2 = 0x52,
    vsetle2 = 0x53,
    vsetgt2 = 0x54,
    vsetge2 = 0x55,
    vreduce2 = 0x56, // vreduce2 [dst], [vreg], [operation-literal]
    vsplat2 = 0x57, // splat a 8-bit value into two channels
    vldc2 = 0x58, // load 2 separate 8-bit values into two channels --> This actually doesn't need to be it's own instruction since the assembler can pack 2 constants into a single 16 bit word. It's here though so we'll implement it even though it's redundant
    // "unreachable" instruction. This isn't really recoverable in the same way an interrupt is
    // so you should prefer interrupts when things can actually validly go wrong and are recoverable
    // this is mostly to insert in places that should be logically unreachable, but for security purposes you add
    // the trap to ensure that if something does go wrong the cpu doesn't start executing who-knows-what
    trap = 0x59,
    iadd = 0x5A,
    isub = 0x5B,
    imul = 0x5C,
    idiv = 0x5D,
    isetlt = 0x5E,
    isetle = 0x5F,
    isetgt = 0x60,
    isetge = 0x61,
    viadd2 = 0x62,
    visub2 = 0x63,
    vimul2 = 0x64,
    visetlt2 = 0x65,
    visetle2 = 0x66,
    visetgt2 = 0x67,
    visetge2 = 0x68,
    mcpy = 0x69,
    mset = 0x6A,
    mmov = 0x6B,
    select = 0x6C, // select ra, rb, rc, rd ==> { ra = (rd) ? rb : rc }
    vselect2 = 0x6D, // select vresult, vreg0, vreg1, vregmask
    vswap2 = 0x6E, // swaps channels of vector
    sar = 0x6F, // saturating arithmetic roll right (a = (0x8000 & (b >> c))); (keeps signs correct)
    vsar2 = 0x70,
    abs = 0x71,
    sign = 0x72,
    min = 0x73,
    max = 0x74,
    vabs2 = 0x75,
    vsign2 = 0x76,
    vmin2 = 0x77,
    vmax2 = 0x78,
    rol = 0x79, // rotate left
    ror = 0x7A,
    vrol2 = 0x7B,
    vror2 = 0x7C,
    lea = 0x7D, // lea [dst0], [dst1] + 32bit address (consumes 64 bits)
    bn = 0x7E,
    bnt = 0x7F,
    bnf = 0x80,
    push32 = 0x81,
    pop32 = 0x82,
};

// TODO: Separate saturiting and wrapping variants
// for math and for vector math

pub const ReduceCode = enum(u8) {
    Add = 0,
    Sub = 1,
    Mul = 2,
    And = 3,
    Or = 4,
    BitAnd = 5,
    BitOr = 6,
    BitXor = 7,
    Max = 8,
    Min = 9,
};

pub const Instruction = packed struct(u32) { opcode: u8, payload: u24 };
pub const InstructionDst = packed struct(u32) { opcode: u8, dst: u5, payload: u19 };
pub const InstructionDstSrc = packed struct(u32) { opcode: u8, dst: u5, src: u5, payload: u14 };
pub const InstructionDstAddrSrc = packed struct(u32) { opcode: u8, dPOR: u5, src: u5, offset: i9, reserved: u5 };
pub const InstructionDstAddrXSrc = packed struct(u32) { opcode: u8, dPSR: u5, dPOR: u5, src: u5, offset: i9 };
pub const InstructionDstSrcAddr = packed struct(u32) { opcode: u8, dst: u5, sPOR: u5, offset: i9, reserved: u5 };
pub const InstructionDstSrcAddrX = packed struct(u32) { opcode: u8, dst: u5, sPSR: u5, sPOR: u5, offset: i9 };
pub const InstructionDst2Src2 = packed struct(u32) { opcode: u8, dst0: u5, dst1: u5, src0: u5, src1: u5, reserved: u4 };
pub const InstructionDstSrc2 = packed struct(u32) { opcode: u8, dst: u5, src0: u5, src1: u5, reserved: u9 };
pub const InstructionDstSrc3 = packed struct(u32) { opcode: u8, dst: u5, src0: u5, src1: u5, src2: u5, reserved: u4 };
