const std = @import("std");

pub const Loc = struct {
    file: []const u8,
    line: u32,
    col: u32,
};

pub const TokenKind = enum {
    int_lit, string_lit, ident,
    // keywords
    kw_fn, kw_inline, kw_for, kw_while, kw_do,
    kw_if, kw_else, kw_return,
    kw_struct, kw_union,
    kw_const, kw_reg, kw_asm,
    kw_import, kw_void, kw_undefined,
    kw_page, kw_offset,
    // type keywords
    ty_u8, ty_u16, ty_i8, ty_i16, ty_u8_vec2, ty_i8_vec2,
    // preprocessor / assembler passthrough
    prep_passthrough, // any #directive line — passed verbatim to asm output
    dollar_ident,     // $TOKEN or ${EXPRESSION} — passed verbatim inside asm lines
    // punctuation
    l_brace, r_brace, l_paren, r_paren, l_bracket, r_bracket,
    semi, comma, colon, dot, star, amp,
    plus, minus, slash, percent,
    caret, pipe, tilde, bang, question, lt, gt, eq,
    // compound operators
    eq_eq, bang_eq, lt_eq, gt_eq,
    plus_plus, minus_minus,
    plus_eq, minus_eq, star_eq, slash_eq, percent_eq,
    amp_eq, pipe_eq, caret_eq,
    lt_lt, gt_gt, lt_lt_eq, gt_gt_eq,
    amp_amp, pipe_pipe, dot_dot,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    loc: Loc,
};

fn lookupKeyword(text: []const u8) ?TokenKind {
    const pairs = [_]struct { []const u8, TokenKind }{
        .{ "fn",        .kw_fn },
        .{ "inline",    .kw_inline },
        .{ "for",       .kw_for },
        .{ "while",     .kw_while },
        .{ "do",        .kw_do },
        .{ "if",        .kw_if },
        .{ "else",      .kw_else },
        .{ "return",    .kw_return },
        .{ "struct",    .kw_struct },
        .{ "union",     .kw_union },
        .{ "const",     .kw_const },
        .{ "reg",       .kw_reg },
        .{ "asm",       .kw_asm },
        .{ "import",    .kw_import },
        .{ "void",      .kw_void },
        .{ "undefined", .kw_undefined },
        .{ "__page",    .kw_page },
        .{ "__offset",  .kw_offset },
        .{ "u8",        .ty_u8 },
        .{ "u16",       .ty_u16 },
        .{ "i8",        .ty_i8 },
        .{ "i16",       .ty_i16 },
        .{ "u8_vec2",   .ty_u8_vec2 },
        .{ "i8_vec2",   .ty_i8_vec2 },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, text, p[0])) return p[1];
    }
    return null;
}

fn isHex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub const LexError = error{ UnexpectedChar, UnterminatedString, OutOfMemory };

pub const Lexer = struct {
    src: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    file: []const u8,

    pub fn init(src: []const u8, file: []const u8) Lexer {
        return .{ .src = src, .pos = 0, .line = 1, .col = 1, .file = file };
    }

    fn cur(self: *Lexer) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }
    fn look(self: *Lexer, n: usize) u8 {
        const i = self.pos + n;
        return if (i < self.src.len) self.src[i] else 0;
    }
    fn bump(self: *Lexer) void {
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n') { self.line += 1; self.col = 1; }
            else self.col += 1;
            self.pos += 1;
        }
    }

    fn skipWs(self: *Lexer) void {
        while (true) {
            const c = self.cur();
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.bump();
            } else if (c == '/' and self.look(1) == '/') {
                while (self.cur() != '\n' and self.cur() != 0) self.bump();
            } else if (c == '/' and self.look(1) == '*') {
                self.bump(); self.bump();
                while (self.pos < self.src.len) {
                    if (self.cur() == '*' and self.look(1) == '/') { self.bump(); self.bump(); break; }
                    self.bump();
                }
            } else break;
        }
    }

    pub fn next(self: *Lexer) LexError!Token {
        self.skipWs();
        const s = self.pos;
        const l = self.line;
        const c2 = self.col;
        if (self.pos >= self.src.len)
            return Token{ .kind = .eof, .text = "", .loc = .{ .file = self.file, .line = l, .col = c2 } };

        const c = self.cur();

        if (c == '#') {
            // Consume the rest of the line verbatim and pass it through to the assembler.
            while (self.cur() != '\n' and self.cur() != 0) self.bump();
            return Token{ .kind = .prep_passthrough, .text = self.src[s..self.pos], .loc = .{ .file = self.file, .line = l, .col = c2 } };
        }

        if (c == '$') {
            self.bump(); // consume '$'
            if (self.cur() == '{') {
                // ${expression} — read until the matching '}'
                self.bump(); // consume '{'
                var depth: usize = 1;
                while (self.pos < self.src.len and depth > 0) {
                    if (self.cur() == '{') depth += 1;
                    if (self.cur() == '}') depth -= 1;
                    self.bump();
                }
            } else {
                // $identifier
                while (std.ascii.isAlphanumeric(self.cur()) or self.cur() == '_') self.bump();
            }
            return Token{ .kind = .dollar_ident, .text = self.src[s..self.pos], .loc = .{ .file = self.file, .line = l, .col = c2 } };
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (std.ascii.isAlphanumeric(self.cur()) or self.cur() == '_') self.bump();
            const text = self.src[s..self.pos];
            const kind = lookupKeyword(text) orelse .ident;
            return Token{ .kind = kind, .text = text, .loc = .{ .file = self.file, .line = l, .col = c2 } };
        }

        if (std.ascii.isDigit(c)) {
            if (c == '0' and (self.look(1) == 'x' or self.look(1) == 'X')) {
                self.bump(); self.bump();
                while (isHex(self.cur())) self.bump();
            } else if (c == '0' and (self.look(1) == 'b' or self.look(1) == 'B')) {
                self.bump(); self.bump();
                while (self.cur() == '0' or self.cur() == '1') self.bump();
            } else {
                while (std.ascii.isDigit(self.cur())) self.bump();
            }
            return Token{ .kind = .int_lit, .text = self.src[s..self.pos], .loc = .{ .file = self.file, .line = l, .col = c2 } };
        }

        if (c == '"') {
            self.bump();
            while (true) {
                const ch = self.cur();
                if (ch == '"') { self.bump(); break; }
                if (ch == 0 or ch == '\n') return LexError.UnterminatedString;
                if (ch == '\\') self.bump();
                self.bump();
            }
            return Token{ .kind = .string_lit, .text = self.src[s..self.pos], .loc = .{ .file = self.file, .line = l, .col = c2 } };
        }

        self.bump();
        const kind: TokenKind = switch (c) {
            '{' => .l_brace, '}' => .r_brace,
            '(' => .l_paren, ')' => .r_paren,
            '[' => .l_bracket, ']' => .r_bracket,
            ';' => .semi, ',' => .comma, ':' => .colon,
            '~' => .tilde, '?' => .question,
            '.' => if (self.cur() == '.') b: { self.bump(); break :b .dot_dot; } else .dot,
            '*' => if (self.cur() == '=') b: { self.bump(); break :b .star_eq; } else .star,
            '&' => if (self.cur() == '&') b: { self.bump(); break :b .amp_amp; }
                   else if (self.cur() == '=') b: { self.bump(); break :b .amp_eq; } else .amp,
            '+' => if (self.cur() == '+') b: { self.bump(); break :b .plus_plus; }
                   else if (self.cur() == '=') b: { self.bump(); break :b .plus_eq; } else .plus,
            '-' => if (self.cur() == '-') b: { self.bump(); break :b .minus_minus; }
                   else if (self.cur() == '=') b: { self.bump(); break :b .minus_eq; } else .minus,
            '/' => if (self.cur() == '=') b: { self.bump(); break :b .slash_eq; } else .slash,
            '%' => if (self.cur() == '=') b: { self.bump(); break :b .percent_eq; } else .percent,
            '^' => if (self.cur() == '=') b: { self.bump(); break :b .caret_eq; } else .caret,
            '|' => if (self.cur() == '|') b: { self.bump(); break :b .pipe_pipe; }
                   else if (self.cur() == '=') b: { self.bump(); break :b .pipe_eq; } else .pipe,
            '!' => if (self.cur() == '=') b: { self.bump(); break :b .bang_eq; } else .bang,
            '=' => if (self.cur() == '=') b: { self.bump(); break :b .eq_eq; } else .eq,
            '<' => if (self.cur() == '<') b: {
                    self.bump();
                    break :b if (self.cur() == '=') b2: { self.bump(); break :b2 .lt_lt_eq; } else .lt_lt;
                } else if (self.cur() == '=') b: { self.bump(); break :b .lt_eq; } else .lt,
            '>' => if (self.cur() == '>') b: {
                    self.bump();
                    break :b if (self.cur() == '=') b2: { self.bump(); break :b2 .gt_gt_eq; } else .gt_gt;
                } else if (self.cur() == '=') b: { self.bump(); break :b .gt_eq; } else .gt,
            else => return LexError.UnexpectedChar,
        };
        return Token{ .kind = kind, .text = self.src[s..self.pos], .loc = .{ .file = self.file, .line = l, .col = c2 } };
    }

    pub fn tokenize(self: *Lexer, gpa: std.mem.Allocator) LexError![]Token {
        var list: std.ArrayList(Token) = .empty;
        while (true) {
            const tok = try self.next();
            try list.append(gpa, tok);
            if (tok.kind == .eof) break;
        }
        return list.toOwnedSlice(gpa);
    }
};
