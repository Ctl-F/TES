const std = @import("std");
const lexer = @import("lexer.zig");
const preprocessor = @import("preprocessor.zig");
const parser = @import("parser.zig");
const sym_mod = @import("symbols.zig");

const ally = std.testing.allocator;

// ── Test harness ───────────────────────────────────────────────────────────────

const Assembled = struct {
    p:   parser.Parser,
    /// preprocessed source — token .text slices point into this
    src: []u8,
    /// token slice produced by lexer
    toks: []lexer.Token,

    pub fn deinit(self: *@This()) void {
        self.p.deinit();
        ally.free(self.toks);
        ally.free(self.src);
    }

    pub fn instructions(self: *@This()) []u32 {
        return self.p.tbfWriter.instructions.items;
    }
};

fn assemble(src_text: []const u8) !Assembled {
    const io = std.Io.Threaded.global_single_threaded.io();
    var prep = preprocessor.Preprocessor.init(ally, io);
    defer prep.deinit();

    // Keep preprocessed source alive — token text slices point into it
    const expanded = try prep.process(src_text, "<test>");
    errdefer ally.free(expanded);

    var lx = lexer.Lexer.init(expanded);
    const toks = try lx.tokenize(ally);
    errdefer ally.free(toks);

    var p = parser.Parser.init(ally, toks, true);
    errdefer p.deinit();
    try p.parse();

    return Assembled{ .p = p, .src = expanded, .toks = toks };
}

// ── Lexer ─────────────────────────────────────────────────────────────────────

test "lexer: integer literals" {
    var lx = lexer.Lexer.init("42 0xFF 0b1010 0o17");
    const toks = try lx.tokenize(ally);
    defer ally.free(toks);

    try std.testing.expectEqual(@as(u64, 42),   toks[0].int_value);
    try std.testing.expectEqual(@as(u64, 0xFF), toks[1].int_value);
    try std.testing.expectEqual(@as(u64, 10),   toks[2].int_value);
    try std.testing.expectEqual(@as(u64, 15),   toks[3].int_value);
}

test "lexer: section tokens" {
    var lx = lexer.Lexer.init("[Meta]\n[Data(1:0x200)]\n[Program]");
    const toks = try lx.tokenize(ally);
    defer ally.free(toks);

    var i: usize = 0;
    while (toks[i].kind == .Newline) i += 1;
    try std.testing.expectEqual(lexer.TokenKind.SectionMeta,    toks[i].kind); i += 1;
    while (toks[i].kind == .Newline) i += 1;
    try std.testing.expectEqual(lexer.TokenKind.SectionData,    toks[i].kind);
    try std.testing.expectEqual(@as(u8,  1),      toks[i].data_page);
    try std.testing.expectEqual(@as(u16, 0x200),  toks[i].data_offset);
    i += 1;
    while (toks[i].kind == .Newline) i += 1;
    try std.testing.expectEqual(lexer.TokenKind.SectionProgram, toks[i].kind);
}

// ── Preprocessor ──────────────────────────────────────────────────────────────

test "preprocessor: define substitution and expr" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var prep = preprocessor.Preprocessor.init(ally, io);
    defer prep.deinit();
    const out = try prep.process("#define WIDTH 64\n#define HEIGHT 32\n${WIDTH * HEIGHT}", "<test>");
    defer ally.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2048") != null);
}

test "preprocessor: integer division" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var prep = preprocessor.Preprocessor.init(ally, io);
    defer prep.deinit();
    const out = try prep.process("#define A 10\n${A / 3}", "<test>");
    defer ally.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "3") != null);
}

// ── Symbol table ──────────────────────────────────────────────────────────────

test "struct: field layout" {
    var sym = sym_mod.SymbolTable.init(ally);
    defer sym.deinit();

    var fields: std.ArrayList(sym_mod.FieldDef) = .empty;
    try fields.append(ally, .{ .name = try ally.dupe(u8,"x"), .prim=.u16, .struct_name=null, .offset=0, .size=2 });
    try fields.append(ally, .{ .name = try ally.dupe(u8,"y"), .prim=.u16, .struct_name=null, .offset=2, .size=2 });
    try sym.defineStruct(.{ .name="Point", .fields=fields, .total_size=4 });

    const sd = sym.getStruct("Point").?;
    try std.testing.expectEqual(@as(u16, 0), sd.findField("x").?.offset);
    try std.testing.expectEqual(@as(u16, 2), sd.findField("y").?.offset);
    try std.testing.expectEqual(@as(u16, 4), sd.total_size);
}

test "struct: dotted field address resolution" {
    var sym = sym_mod.SymbolTable.init(ally);
    defer sym.deinit();

    var fields: std.ArrayList(sym_mod.FieldDef) = .empty;
    try fields.append(ally, .{ .name=try ally.dupe(u8,"x"), .prim=.u16, .struct_name=null, .offset=0, .size=2 });
    try fields.append(ally, .{ .name=try ally.dupe(u8,"y"), .prim=.u16, .struct_name=null, .offset=2, .size=2 });
    try sym.defineStruct(.{ .name="Point", .fields=fields, .total_size=4 });

    try sym.defineData("Ball", .{
        .page=0, .offset=0x100, .size=4,
        .prim=.Struct, .struct_name="Point",
        .struct_def=sym.getStruct("Point"),
    });

    try std.testing.expectEqual(@as(u32, 0x0000_0100), try sym.resolveAddress("Ball.x"));
    try std.testing.expectEqual(@as(u32, 0x0000_0102), try sym.resolveAddress("Ball.y"));
}

// ── Full assembly ─────────────────────────────────────────────────────────────

test "assemble: nop and hlt" {
    var res = try assemble(
        \\[Program]
        \\nop
        \\hlt
    );
    defer res.deinit();
    const insns = res.instructions();
    try std.testing.expectEqual(@as(usize, 2), insns.len);
    try std.testing.expectEqual(@as(u32, 0x00), insns[0]);
    try std.testing.expectEqual(@as(u32, 0x40), insns[1]);
}

test "assemble: mov r0, r1" {
    var res = try assemble("[Program]\nmov r0, r1");
    defer res.deinit();
    // opcode=0x01, dst=0, src=1
    try std.testing.expectEqual(@as(u32, 0x01 | (0<<8) | (1<<13)), res.instructions()[0]);
}

test "assemble: add r2, r3" {
    var res = try assemble("[Program]\nadd r2, r3");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x0B | (2<<8) | (3<<13)), res.instructions()[0]);
}

test "assemble: div r0, r1, r2, r3" {
    var res = try assemble("[Program]\ndiv r0, r1, r2, r3");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x0E | (0<<8) | (1<<13) | (2<<18) | (3<<23)), res.instructions()[0]);
}

test "assemble: seteq r4, r5, r6" {
    var res = try assemble("[Program]\nseteq r4, r5, r6");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x25 | (4<<8) | (5<<13) | (6<<18)), res.instructions()[0]);
}

test "assemble: mov_c r0, 10" {
    var res = try assemble("[Program]\nmov_c r0, 10");
    defer res.deinit();
    // opcode=0x02, dst=0, payload19=10
    try std.testing.expectEqual(@as(u32, 0x02 | (0<<8) | (10<<13)), res.instructions()[0]);
}

test "assemble: backward branch" {
    var res = try assemble(
        \\[Program]
        \\loop:
        \\  nop
        \\  bn loop
    );
    defer res.deinit();
    const insns = res.instructions();
    try std.testing.expectEqual(@as(usize, 2), insns.len);
    // bn at index 1, target=0, offset=-1 as i14
    const off14: u32 = @as(u14, @bitCast(@as(i14, -1)));
    try std.testing.expectEqual(@as(u32, 0x7E | (off14<<13)), insns[1]);
}

test "assemble: forward branch" {
    var res = try assemble(
        \\[Program]
        \\  bnt r0, done
        \\  nop
        \\done:
        \\  hlt
    );
    defer res.deinit();
    const insns = res.instructions();
    try std.testing.expectEqual(@as(usize, 3), insns.len);
    // bnt at 0, target=2, offset=+2
    const off14: u32 = @as(u14, @bitCast(@as(i14, 2)));
    try std.testing.expectEqual(@as(u32, 0x7F | (0<<8) | (off14<<13)), insns[0]);
    try std.testing.expectEqual(@as(u32, 0x00), insns[1]);
    try std.testing.expectEqual(@as(u32, 0x40), insns[2]);
}

test "assemble: lea two words" {
    var res = try assemble("[Program]\nlea r0, r1, 0xDEADBEEF");
    defer res.deinit();
    const insns = res.instructions();
    try std.testing.expectEqual(@as(usize, 2), insns.len);
    try std.testing.expectEqual(@as(u32, 0x7D | (0<<8) | (1<<13)), insns[0]);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF),               insns[1]);
}

test "assemble: select instruction" {
    var res = try assemble("[Program]\nselect r0, r1, r2, r3");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x6C | (0<<8) | (1<<13) | (2<<18) | (3<<23)), res.instructions()[0]);
}

test "assemble: struct and data section" {
    var res = try assemble(
        \\[Meta]
        \\struct Point {
        \\  x: u16;
        \\  y: u16;
        \\}
        \\[Data(0:0x200)]
        \\Ball: .Point .{10, 20}
        \\[Program]
        \\hlt
    );
    defer res.deinit();

    const sym = res.p.sym.getSymbol("Ball").?;
    try std.testing.expectEqual(@as(u8,  0),      sym.Data.page);
    try std.testing.expectEqual(@as(u16, 0x200),  sym.Data.offset);
    try std.testing.expectEqual(@as(u16, 4),      sym.Data.size);

    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 0x0A), dp.data[0]); // 10 lo
    try std.testing.expectEqual(@as(u8, 0x00), dp.data[1]); // 10 hi
    try std.testing.expectEqual(@as(u8, 0x14), dp.data[2]); // 20 lo
    try std.testing.expectEqual(@as(u8, 0x00), dp.data[3]); // 20 hi
}

test "assemble: TBF magic and instruction count" {
    var res = try assemble("[Program]\nhlt");
    defer res.deinit();

    var aw = std.Io.Writer.Allocating.init(ally);
    defer aw.deinit();
    try res.p.tbfWriter.write(&aw.writer);

    const written = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expectEqualSlices(u8, "TESB", written[0..4]);
    try std.testing.expectEqual(@as(u8, 1), written[4]); // count=1 LE
    try std.testing.expectEqual(@as(u8, 0), written[5]);
    try std.testing.expectEqual(@as(u8, 0), written[6]);
    try std.testing.expectEqual(@as(u8, 0), written[7]);
    try std.testing.expectEqual(@as(u8, 0x40), written[8]); // hlt
}

// ── Smart mov dispatch ────────────────────────────────────────────────────────

test "assemble: mov smart dispatch - reg to reg" {
    var res = try assemble("[Program]\nmov r0, r1");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x01 | (0<<8) | (1<<13)), res.instructions()[0]);
}

test "assemble: mov smart dispatch - reg immediate" {
    var res = try assemble("[Program]\nmov r0, 42");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x02 | (0<<8) | (42<<13)), res.instructions()[0]);
}

test "assemble: mov smart dispatch - write to memory" {
    var res = try assemble("[Program]\nmov [r0], r1");
    defer res.deinit();
    // opcode=0x03 DstAddrSrc: dPOR=r0, src=r1, offset=0
    try std.testing.expectEqual(@as(u32, 0x03 | (0<<8) | (1<<13)), res.instructions()[0]);
}

test "assemble: mov smart dispatch - read from memory" {
    var res = try assemble("[Program]\nmov r1, [r0]");
    defer res.deinit();
    // opcode=0x04 DstSrcAddr: dst=r1, sPOR=r0, offset=0
    try std.testing.expectEqual(@as(u32, 0x04 | (1<<8) | (0<<13)), res.instructions()[0]);
}

test "assemble: mov smart dispatch - half-width write" {
    var res = try assemble("[Program]\nmov [r0], (byte) r1");
    defer res.deinit();
    // opcode=0x07 DstAddrSrc half: dPOR=r0, src=r1
    try std.testing.expectEqual(@as(u32, 0x07 | (0<<8) | (1<<13)), res.instructions()[0]);
}

test "assemble: mov smart dispatch - half-width read" {
    var res = try assemble("[Program]\nmov r1, (byte)[r0]");
    defer res.deinit();
    // opcode=0x08 DstSrcAddr half: dst=r1, sPOR=r0
    try std.testing.expectEqual(@as(u32, 0x08 | (1<<8) | (0<<13)), res.instructions()[0]);
}

test "assemble: mov smart dispatch - extended write" {
    var res = try assemble("[Program]\nmov [r0, r1], r2");
    defer res.deinit();
    // opcode=0x05 DstAddrXSrc: psr=r0, por=r1, src=r2
    try std.testing.expectEqual(@as(u32, 0x05 | (0<<8) | (1<<13) | (2<<18)), res.instructions()[0]);
}

test "assemble: mov smart dispatch - extended read" {
    var res = try assemble("[Program]\nmov r2, [r0, r1]");
    defer res.deinit();
    // opcode=0x06 DstSrcAddrX: dst=r2, psr=r0, por=r1
    try std.testing.expectEqual(@as(u32, 0x06 | (2<<8) | (0<<13) | (1<<18)), res.instructions()[0]);
}

// ── Compound address offsets ───────────────────────────────────────────────────

test "assemble: compound address offset" {
    var res = try assemble("[Program]\nmov r0, [r1 + 2 - 1 + 3]");
    defer res.deinit();
    // offset = 2-1+3 = 4, opcode=0x04
    const off4: u32 = @as(u9, @bitCast(@as(i9, 4)));
    try std.testing.expectEqual(@as(u32, 0x04 | (0<<8) | (1<<13) | (off4<<18)), res.instructions()[0]);
}

// ── bump/push/pop consolidation ───────────────────────────────────────────────

test "assemble: bump with register" {
    var res = try assemble("[Program]\nbump r0, r1");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x32 | (0<<8) | (1<<13)), res.instructions()[0]);
}

test "assemble: bump with immediate" {
    var res = try assemble("[Program]\nbump r0, 8");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x33 | (0<<8) | (8<<13)), res.instructions()[0]);
}

test "assemble: push default (16-bit)" {
    var res = try assemble("[Program]\npush r0");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x2F | (0<<8)), res.instructions()[0]);
}

test "assemble: push byte" {
    var res = try assemble("[Program]\npush (byte) r0");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x2E | (0<<8)), res.instructions()[0]);
}

test "assemble: push dword" {
    var res = try assemble("[Program]\npush (dword) r0");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x81 | (0<<8)), res.instructions()[0]);
}

test "assemble: pop default (16-bit)" {
    var res = try assemble("[Program]\npop r0");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x31 | (0<<8)), res.instructions()[0]);
}

// ── resume consolidation ──────────────────────────────────────────────────────

test "assemble: resume (skip)" {
    var res = try assemble("[Program]\nresume");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x42), res.instructions()[0]);
}

test "assemble: resume at" {
    var res = try assemble("[Program]\nresume at");
    defer res.deinit();
    try std.testing.expectEqual(@as(u32, 0x43), res.instructions()[0]);
}

// ── Arrays in data section ────────────────────────────────────────────────────

test "assemble: u8 array field in struct" {
    var res = try assemble(
        \\[Meta]
        \\struct Buf {
        \\  data: u8[4];
        \\}
        \\[Data(0:0x100)]
        \\B: .Buf .{1, 2, 3, 4}
        \\[Program]
        \\hlt
    );
    defer res.deinit();
    const sym = res.p.sym.getSymbol("B").?;
    try std.testing.expectEqual(@as(u16, 4), sym.Data.size);
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 1), dp.data[0]);
    try std.testing.expectEqual(@as(u8, 2), dp.data[1]);
    try std.testing.expectEqual(@as(u8, 3), dp.data[2]);
    try std.testing.expectEqual(@as(u8, 4), dp.data[3]);
}

test "assemble: bare u8 array in data section" {
    var res = try assemble("[Data(0:0)]\nBuf: .u8[3]");
    defer res.deinit();
    const sym = res.p.sym.getSymbol("Buf").?;
    try std.testing.expectEqual(@as(u16, 3), sym.Data.size);
}

// ── String and char literals ──────────────────────────────────────────────────

test "lexer: char literal" {
    var lx = lexer.Lexer.init("'A' '\\n' '\\0'");
    const toks = try lx.tokenize(ally);
    defer ally.free(toks);
    try std.testing.expectEqual(lexer.TokenKind.CharLit, toks[0].kind);
    try std.testing.expectEqual(@as(u64, 'A'),  toks[0].int_value);
    try std.testing.expectEqual(lexer.TokenKind.CharLit, toks[1].kind);
    try std.testing.expectEqual(@as(u64, '\n'), toks[1].int_value);
    try std.testing.expectEqual(lexer.TokenKind.CharLit, toks[2].kind);
    try std.testing.expectEqual(@as(u64, 0),    toks[2].int_value);
}

test "assemble: char literal in data" {
    var res = try assemble("[Data(0:0)]\nCh: .u8 'A'");
    defer res.deinit();
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 'A'), dp.data[0]);
}

test "assemble: string literal as data" {
    var res = try assemble("[Data(0:0)]\nGreeting: \"Hi\\0\"");
    defer res.deinit();
    const sym = res.p.sym.getSymbol("Greeting").?;
    try std.testing.expectEqual(@as(u16, 3), sym.Data.size); // H i \0
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 'H'),  dp.data[0]);
    try std.testing.expectEqual(@as(u8, 'i'),  dp.data[1]);
    try std.testing.expectEqual(@as(u8, 0),    dp.data[2]);
}

// ── @bind / @{ scope } ───────────────────────────────────────────────────────

test "scope: basic @bind used as register operand" {
    var res = try assemble(
        \\[Program]
        \\_start: @{
        \\  @bind x : r0;
        \\  @bind y : r1;
        \\  mov x, y
        \\}
    );
    defer res.deinit();
    // mov r0, r1 — opcode 0x01
    try std.testing.expectEqual(
        @as(u32, 0x01 | (0<<8) | (1<<13)),
        res.instructions()[2], // [0]=bn prologue, [1]=hlt prologue
    );
}

test "scope: alias resolves to correct register in instruction" {
    var res = try assemble(
        \\[Program]
        \\_start: @{
        \\  @bind dst : r3;
        \\  mov dst, 42
        \\}
    );
    defer res.deinit();
    // mov_c r3, 42 — opcode 0x02, dst=3, payload=42
    try std.testing.expectEqual(
        @as(u32, 0x02 | (3<<8) | (42<<13)),
        res.instructions()[2],
    );
}

test "scope: aliases die at closing brace" {
    // After }, 'x' should no longer be defined; raw register r0 still works.
    var res = try assemble(
        \\[Program]
        \\_start:
        \\@{
        \\  @bind x : r0;
        \\}
        \\  mov r0, r1
    );
    defer res.deinit();
    try std.testing.expectEqual(
        @as(u32, 0x01 | (0<<8) | (1<<13)),
        res.instructions()[2],
    );
}

test "scope: nested scopes shadow outer alias" {
    var res = try assemble(
        \\[Program]
        \\_start: @{
        \\  @bind x : r0;
        \\  @{
        \\    @bind x : r5;
        \\    mov x, r2
        \\  }
        \\  mov x, r2
        \\}
    );
    defer res.deinit();
    // First mov: x=r5 in inner scope
    try std.testing.expectEqual(
        @as(u32, 0x01 | (5<<8) | (2<<13)),
        res.instructions()[2],
    );
    // Second mov: x=r0 restored in outer scope
    try std.testing.expectEqual(
        @as(u32, 0x01 | (0<<8) | (2<<13)),
        res.instructions()[3],
    );
}

test "scope: named close label is accepted" {
    var res = try assemble(
        \\[Program]
        \\myFn: @{
        \\  @bind x : r0;
        \\  mov x, r1
        \\}@myFn
    );
    defer res.deinit();
    try std.testing.expectEqual(
        @as(u32, 0x01 | (0<<8) | (1<<13)),
        res.instructions()[2],
    );
}

test "scope: re-bind in same scope updates alias" {
    var res = try assemble(
        \\[Program]
        \\_start: @{
        \\  @bind x : r0;
        \\  @bind x : r7;
        \\  mov x, r1
        \\}
    );
    defer res.deinit();
    // x is now r7
    try std.testing.expectEqual(
        @as(u32, 0x01 | (7<<8) | (1<<13)),
        res.instructions()[2],
    );
}

// ── $sizeOf / $offsetOf builtins ─────────────────────────────────────────────

test "assemble: $sizeOf struct in data" {
    var res = try assemble(
        \\[Meta]
        \\struct Vec2 { x: u16; y: u16; }
        \\[Data(0:0)]
        \\Sz: .u16 $sizeOf(Vec2)
        \\[Program]
        \\hlt
    );
    defer res.deinit();
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 4), dp.data[0]); // 4 lo
    try std.testing.expectEqual(@as(u8, 0), dp.data[1]); // 4 hi
}

test "assemble: $sizeOf primitive" {
    var res = try assemble("[Data(0:0)]\nSz: .u8 $sizeOf(u16)\n[Program]\nhlt");
    defer res.deinit();
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 2), dp.data[0]);
}

test "assemble: $offsetOf struct field" {
    var res = try assemble(
        \\[Meta]
        \\struct Point { x: u16; y: u16; }
        \\[Data(0:0)]
        \\Off: .u16 $offsetOf(Point, y)
        \\[Program]
        \\hlt
    );
    defer res.deinit();
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 2), dp.data[0]); // y is at byte 2
    try std.testing.expectEqual(@as(u8, 0), dp.data[1]);
}

test "assemble: array field index in mem operand" {
    var res = try assemble(
        \\[Meta]
        \\struct GFXHeader { layers: u16[4]; flags: u16; }
        \\[Program]
        \\_start:
        \\  mov r0, [(GFXHeader.layers[2])r1]
    );
    defer res.deinit();
    // layers starts at offset 0, each element is 2 bytes, index 2 → offset 4
    // opcode=0x04 DstSrcAddr: dst=r0, sPOR=r1, offset=4
    const off: u32 = @as(u9, @bitCast(@as(i9, 4)));
    try std.testing.expectEqual(
        @as(u32, 0x04 | (0<<8) | (1<<13) | (off<<18)),
        res.instructions()[2], // instructions()[0]=bn, [1]=hlt prologue
    );
}

test "assemble: array field index in ext mem operand" {
    var res = try assemble(
        \\[Meta]
        \\struct GFXHeader { layers: u16[4]; flags: u16; }
        \\[Program]
        \\_start:
        \\  mov r0, [r1, (GFXHeader.layers[1])r2]
    );
    defer res.deinit();
    // layers[1] → offset 2
    const off: u32 = @as(u9, @bitCast(@as(i9, 2)));
    try std.testing.expectEqual(
        @as(u32, 0x06 | (0<<8) | (1<<13) | (2<<18) | (off<<23)),
        res.instructions()[2],
    );
}

test "assemble: $offsetOf with array index" {
    var res = try assemble(
        \\[Meta]
        \\struct GFXHeader { layers: u16[4]; flags: u16; }
        \\[Data(0:0)]
        \\Off: .u16 $offsetOf(GFXHeader, layers[3])
        \\[Program]
        \\hlt
    );
    defer res.deinit();
    // layers[3] → offset 6
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 6), dp.data[0]);
    try std.testing.expectEqual(@as(u8, 0), dp.data[1]);
}

test "assemble: $offsetOf data instance field" {
    var res = try assemble(
        \\[Meta]
        \\struct Point { x: u16; y: u16; }
        \\[Data(0:0x100)]
        \\P: .Point .{1, 2}
        \\[Data(0:0x200)]
        \\Off: .u16 $offsetOf(P, y)
        \\[Program]
        \\hlt
    );
    defer res.deinit();
    // offsetOf(instance, field) returns the field offset within the struct (not abs addr)
    const dp = res.p.tbfWriter.data_pages.items[1];
    try std.testing.expectEqual(@as(u8, 2), dp.data[0]);
    try std.testing.expectEqual(@as(u8, 0), dp.data[1]);
}

test "assemble: preprocessor define used in data" {
    var res = try assemble(
        \\[Data(0:512)]
        \\#define HALF 128
        \\PosX: .u16 ${HALF}
    );
    defer res.deinit();
    const dp = res.p.tbfWriter.data_pages.items[0];
    try std.testing.expectEqual(@as(u8, 128), dp.data[0]);
    try std.testing.expectEqual(@as(u8,   0), dp.data[1]);
}
