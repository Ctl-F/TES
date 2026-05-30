const std = @import("std");

pub const RegID = enum(u5) {
    R0=0,R1=1,R2=2,R3=3,R4=4,R5=5,R6=6,R7=7,
    R8=8,R9=9,RA=10,RB=11,RC=12,RD=13,RE=14,RF=15,
    IP=16, IPH=17, JR=18, JRH=19,
    FCL=20,FCH=21,GCL=22,GCH=23,
    SH=24,SB=25,SP=26,

    pub fn fromStr(s: []const u8) ?@This() {
        var buf: [8]u8 = undefined;
        if (s.len == 0 or s.len > 8) return null;
        const lower = std.ascii.lowerString(buf[0..s.len], s);
        inline for (.{
            .{"r0",.R0},  .{"r1",.R1},  .{"r2",.R2},  .{"r3",.R3},
            .{"r4",.R4},  .{"r5",.R5},  .{"r6",.R6},  .{"r7",.R7},
            .{"r8",.R8},  .{"r9",.R9},  .{"ra",.RA},  .{"rb",.RB},
            .{"rc",.RC},  .{"rd",.RD},  .{"re",.RE},  .{"rf",.RF},
            .{"ip",.IP},  .{"jr",.JR},
            .{"fcl",.FCL},.{"fch",.FCH},.{"gcl",.GCL},.{"gch",.GCH},
            .{"sh",.SH},  .{"sb",.SB},  .{"sp",.SP},
        }) |pair| {
            if (std.mem.eql(u8, lower, pair[0])) return pair[1];
        }
        return null;
    }
};

pub const Format = enum {
    Bare, Dst, DstSrc,
    DstAddrSrc, DstAddrXSrc, DstSrcAddr, DstSrcAddrX,
    Dst2Src2, Dst2Src2Len, DstSrc2, DstSrc3,
    DstConst2,  // opcode | (dst<<8) | (c0<<13) | (c1<<21)  — reg + two 8-bit constants
    LeaWide,
    BranchReg, BranchRegCond, BranchNear, BranchNearCond,
    Syscall,
    ResumeReg,  // opcode | (hi_reg<<8) | (lo_reg<<13)  — address from register pair
    VReduce,    // opcode | (dst<<8) | (src<<13) | (reduce_code<<18)
};

pub const OpcodeInfo = struct {
    opcode: u8,
    format: Format,
    mnemonic: []const u8,
};

pub const opcodes = [_]OpcodeInfo{
    .{.opcode=0x00,.format=.Bare,         .mnemonic="nop"},
    .{.opcode=0x01,.format=.DstSrc,       .mnemonic="mov"},
    .{.opcode=0x02,.format=.Dst,          .mnemonic="mov_c"},
    .{.opcode=0x03,.format=.DstAddrSrc,   .mnemonic="mov_av"},
    .{.opcode=0x04,.format=.DstSrcAddr,   .mnemonic="mov_ra"},
    .{.opcode=0x05,.format=.DstAddrXSrc,  .mnemonic="mov_aev"},
    .{.opcode=0x06,.format=.DstSrcAddrX,  .mnemonic="mov_rae"},
    .{.opcode=0x07,.format=.DstAddrSrc,   .mnemonic="mov_hav"},
    .{.opcode=0x08,.format=.DstSrcAddr,   .mnemonic="mov_hra"},
    .{.opcode=0x09,.format=.DstAddrXSrc,  .mnemonic="mov_heav"},
    .{.opcode=0x0A,.format=.DstSrcAddrX,  .mnemonic="mov_hrae"},
    .{.opcode=0x0B,.format=.DstSrc,       .mnemonic="add"},
    .{.opcode=0x0C,.format=.DstSrc,       .mnemonic="sub"},
    .{.opcode=0x0D,.format=.DstSrc,       .mnemonic="mul"},
    .{.opcode=0x0E,.format=.Dst2Src2,     .mnemonic="div"},
    .{.opcode=0x0F,.format=.DstSrc,       .mnemonic="shr"},
    .{.opcode=0x10,.format=.DstSrc,       .mnemonic="shl"},
    .{.opcode=0x11,.format=.DstSrc,       .mnemonic="and"},
    .{.opcode=0x12,.format=.DstSrc,       .mnemonic="or"},
    .{.opcode=0x13,.format=.DstSrc,       .mnemonic="xor"},
    .{.opcode=0x14,.format=.Dst,          .mnemonic="not"},
    .{.opcode=0x15,.format=.DstSrc,       .mnemonic="land"},
    .{.opcode=0x16,.format=.DstSrc,       .mnemonic="lor"},
    .{.opcode=0x17,.format=.Dst,          .mnemonic="lnot"},
    .{.opcode=0x18,.format=.Dst,          .mnemonic="neg"},
    .{.opcode=0x19,.format=.DstSrc,       .mnemonic="vadd2"},
    .{.opcode=0x1A,.format=.DstSrc,       .mnemonic="vsub2"},
    .{.opcode=0x1B,.format=.DstSrc,       .mnemonic="vmul2"},
    .{.opcode=0x1C,.format=.DstSrc,       .mnemonic="vshr2"},
    .{.opcode=0x1D,.format=.DstSrc,       .mnemonic="vshl2"},
    .{.opcode=0x1E,.format=.DstSrc,       .mnemonic="vand2"},
    .{.opcode=0x1F,.format=.DstSrc,       .mnemonic="vor2"},
    .{.opcode=0x20,.format=.DstSrc,       .mnemonic="vxor2"},
    .{.opcode=0x21,.format=.Dst,          .mnemonic="vnot2"},
    .{.opcode=0x22,.format=.Dst,          .mnemonic="vneg2"},
    .{.opcode=0x23,.format=.Dst,          .mnemonic="inc"},
    .{.opcode=0x24,.format=.Dst,          .mnemonic="dec"},
    .{.opcode=0x25,.format=.DstSrc2,      .mnemonic="seteq"},
    .{.opcode=0x26,.format=.DstSrc2,      .mnemonic="setneq"},
    .{.opcode=0x27,.format=.DstSrc2,      .mnemonic="setlt"},
    .{.opcode=0x28,.format=.DstSrc2,      .mnemonic="setle"},
    .{.opcode=0x29,.format=.DstSrc2,      .mnemonic="setgt"},
    .{.opcode=0x2A,.format=.DstSrc2,      .mnemonic="setge"},
    .{.opcode=0x2B,.format=.BranchReg,    .mnemonic="b"},
    .{.opcode=0x2C,.format=.BranchRegCond,.mnemonic="bt"},
    .{.opcode=0x2D,.format=.BranchRegCond,.mnemonic="bf"},
    .{.opcode=0x2E,.format=.Dst,          .mnemonic="push8"},
    .{.opcode=0x2F,.format=.Dst,          .mnemonic="push16"},
    .{.opcode=0x30,.format=.Dst,          .mnemonic="pop8"},
    .{.opcode=0x31,.format=.Dst,          .mnemonic="pop16"},
    .{.opcode=0x32,.format=.Dst,          .mnemonic="bump_r"},
    .{.opcode=0x33,.format=.Dst,          .mnemonic="bump_c"},
    .{.opcode=0x34,.format=.DstAddrXSrc,  .mnemonic="mov_aevi"},
    .{.opcode=0x35,.format=.DstSrcAddrX,  .mnemonic="mov_raei"},
    .{.opcode=0x36,.format=.DstAddrXSrc,  .mnemonic="mov_haevi"},
    .{.opcode=0x37,.format=.DstSrcAddrX,  .mnemonic="mov_hraei"},
    .{.opcode=0x38,.format=.DstAddrXSrc,  .mnemonic="mov_aevd"},
    .{.opcode=0x39,.format=.DstSrcAddrX,  .mnemonic="mov_raed"},
    .{.opcode=0x3A,.format=.DstAddrXSrc,  .mnemonic="mov_haevd"},
    .{.opcode=0x3B,.format=.DstSrcAddrX,  .mnemonic="mov_hraed"},
    .{.opcode=0x3C,.format=.DstSrc2,      .mnemonic="fma"},
    .{.opcode=0x3D,.format=.DstSrc,       .mnemonic="stackset"},
    .{.opcode=0x3E,.format=.Dst,          .mnemonic="int"},
    .{.opcode=0x3F,.format=.Syscall,      .mnemonic="syscall"},
    .{.opcode=0x40,.format=.Bare,         .mnemonic="hlt"},
    .{.opcode=0x41,.format=.Bare,         .mnemonic="yield"},
    .{.opcode=0x42,.format=.Bare,         .mnemonic="resume_skip"},
    .{.opcode=0x43,.format=.ResumeReg,    .mnemonic="resume_at"},
    .{.opcode=0x44,.format=.Bare,         .mnemonic="retry"},
    .{.opcode=0x45,.format=.DstSrc,       .mnemonic="sync_mov"},
    .{.opcode=0x46,.format=.DstAddrXSrc,  .mnemonic="sync_write"},
    .{.opcode=0x47,.format=.DstAddrXSrc,  .mnemonic="sync_hwrite"},
    .{.opcode=0x48,.format=.DstSrcAddrX,  .mnemonic="sync_read"},
    .{.opcode=0x49,.format=.DstSrcAddrX,  .mnemonic="sync_hread"},
    .{.opcode=0x4A,.format=.Dst,          .mnemonic="extz"},
    .{.opcode=0x4B,.format=.Dst,          .mnemonic="exts"},
    .{.opcode=0x4C,.format=.Dst,          .mnemonic="truncz"},
    .{.opcode=0x4D,.format=.Dst,          .mnemonic="clamp"},
    .{.opcode=0x4E,.format=.DstSrc,       .mnemonic="swap"},
    .{.opcode=0x4F,.format=.DstSrc2,      .mnemonic="bittest"},
    .{.opcode=0x50,.format=.DstSrc,       .mnemonic="vseteq2"},
    .{.opcode=0x51,.format=.DstSrc,       .mnemonic="vsetneq2"},
    .{.opcode=0x52,.format=.DstSrc,       .mnemonic="vsetlt2"},
    .{.opcode=0x53,.format=.DstSrc,       .mnemonic="vsetle2"},
    .{.opcode=0x54,.format=.DstSrc,       .mnemonic="vsetgt2"},
    .{.opcode=0x55,.format=.DstSrc,       .mnemonic="vsetge2"},
    .{.opcode=0x56,.format=.VReduce,      .mnemonic="vreduce2"},
    .{.opcode=0x57,.format=.Dst,          .mnemonic="vsplat2"},
    .{.opcode=0x58,.format=.DstConst2,    .mnemonic="vldc2"},
    .{.opcode=0x59,.format=.Bare,         .mnemonic="trap"},
    .{.opcode=0x5A,.format=.DstSrc,       .mnemonic="iadd"},
    .{.opcode=0x5B,.format=.DstSrc,       .mnemonic="isub"},
    .{.opcode=0x5C,.format=.DstSrc,       .mnemonic="imul"},
    .{.opcode=0x5D,.format=.Dst2Src2,     .mnemonic="idiv"},
    .{.opcode=0x5E,.format=.DstSrc2,      .mnemonic="isetlt"},
    .{.opcode=0x5F,.format=.DstSrc2,      .mnemonic="isetle"},
    .{.opcode=0x60,.format=.DstSrc2,      .mnemonic="isetgt"},
    .{.opcode=0x61,.format=.DstSrc2,      .mnemonic="isetge"},
    .{.opcode=0x62,.format=.DstSrc,       .mnemonic="viadd2"},
    .{.opcode=0x63,.format=.DstSrc,       .mnemonic="visub2"},
    .{.opcode=0x64,.format=.DstSrc,       .mnemonic="vimul2"},
    .{.opcode=0x65,.format=.DstSrc,       .mnemonic="visetlt2"},
    .{.opcode=0x66,.format=.DstSrc,       .mnemonic="visetle2"},
    .{.opcode=0x67,.format=.DstSrc,       .mnemonic="visetgt2"},
    .{.opcode=0x68,.format=.DstSrc,       .mnemonic="visetge2"},
    .{.opcode=0x69,.format=.Dst2Src2Len,  .mnemonic="mcpy"},
    .{.opcode=0x6A,.format=.Dst2Src2,     .mnemonic="mset"},
    .{.opcode=0x6B,.format=.Dst2Src2Len,  .mnemonic="mmov"},
    .{.opcode=0x6C,.format=.DstSrc3,      .mnemonic="select"},
    .{.opcode=0x6D,.format=.DstSrc3,      .mnemonic="vselect2"},
    .{.opcode=0x6E,.format=.Dst,          .mnemonic="vswap2"},
    .{.opcode=0x6F,.format=.DstSrc,       .mnemonic="sar"},
    .{.opcode=0x70,.format=.DstSrc,       .mnemonic="vsar2"},
    .{.opcode=0x71,.format=.Dst,          .mnemonic="abs"},
    .{.opcode=0x72,.format=.Dst,          .mnemonic="sign"},
    .{.opcode=0x73,.format=.DstSrc,       .mnemonic="min"},
    .{.opcode=0x74,.format=.DstSrc,       .mnemonic="max"},
    .{.opcode=0x75,.format=.Dst,          .mnemonic="vabs2"},
    .{.opcode=0x76,.format=.Dst,          .mnemonic="vsign2"},
    .{.opcode=0x77,.format=.DstSrc,       .mnemonic="vmin2"},
    .{.opcode=0x78,.format=.DstSrc,       .mnemonic="vmax2"},
    .{.opcode=0x79,.format=.DstSrc,       .mnemonic="rol"},
    .{.opcode=0x7A,.format=.DstSrc,       .mnemonic="ror"},
    .{.opcode=0x7B,.format=.DstSrc,       .mnemonic="vrol2"},
    .{.opcode=0x7C,.format=.DstSrc,       .mnemonic="vror2"},
    .{.opcode=0x7D,.format=.LeaWide,      .mnemonic="lea"},
    .{.opcode=0x7E,.format=.BranchNear,   .mnemonic="bn"},
    .{.opcode=0x7F,.format=.BranchNearCond,.mnemonic="bnt"},
    .{.opcode=0x80,.format=.BranchNearCond,.mnemonic="bnf"},
    .{.opcode=0x81,.format=.DstSrc,        .mnemonic="push32"},
    .{.opcode=0x82,.format=.DstSrc,        .mnemonic="pop32"},
    .{.opcode=0x83,.format=.Dst2Src2,     .mnemonic="ivs"},
    .{.opcode=0x84,.format=.DstSrc,       .mnemonic="mov_b"},
    .{.opcode=0x85,.format=.DstSrc,       .mnemonic="vimin2"},
    .{.opcode=0x86,.format=.DstSrc,       .mnemonic="vimax2"},
};

pub const reduce_codes = [_]struct { name: []const u8, code: u4 }{
    .{ .name = "add",    .code = 0 },
    .{ .name = "sub",    .code = 1 },
    .{ .name = "mul",    .code = 2 },
    .{ .name = "and",    .code = 3 },
    .{ .name = "or",     .code = 4 },
    .{ .name = "bitand", .code = 5 },
    .{ .name = "bitor",  .code = 6 },
    .{ .name = "bitxor", .code = 7 },
    .{ .name = "max",    .code = 8 },
    .{ .name = "min",    .code = 9 },
};

pub fn findReduceCode(name: []const u8) ?u4 {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    for (reduce_codes) |rc| {
        if (std.mem.eql(u8, rc.name, lower)) return rc.code;
    }
    return null;
}

pub fn reduceCodeName(code: u4) []const u8 {
    for (reduce_codes) |rc| {
        if (rc.code == code) return rc.name;
    }
    return "?";
}

pub fn findOpcode(mnemonic: []const u8) ?OpcodeInfo {
    var buf: [32]u8 = undefined;
    if (mnemonic.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..mnemonic.len], mnemonic);
    for (opcodes) |info| {
        if (std.mem.eql(u8, info.mnemonic, lower)) return info;
    }
    return null;
}
