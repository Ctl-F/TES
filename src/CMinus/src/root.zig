const std = @import("std");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const sema_mod = @import("sema.zig");
const codegen_mod = @import("codegen.zig");

pub fn compileSource(gpa: std.mem.Allocator, source: []const u8, filename: []const u8, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lex = lexer.Lexer.init(source, filename);
    const tokens = try lex.tokenize(alloc);

    var p = parser_mod.Parser.init(alloc, tokens, filename);
    const file = try p.parse();

    var sema = sema_mod.Sema.init(alloc);
    try sema.analyze(&file);

    var cg = codegen_mod.Codegen.init(alloc, &sema);
    try cg.generate(&file, writer);
}
