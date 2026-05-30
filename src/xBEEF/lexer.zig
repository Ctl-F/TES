const std = @import("std");

pub const TokenKind = enum {
    Identifier,
    Integer,
    StringLit,
    CharLit,
    Colon,
    Semicolon,
    Comma,
    Dot,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    LParen,
    RParen,
    Hash,
    At,
    Dollar,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Ampersand,
    Pipe,
    Caret,
    Tilde,
    ShiftLeft,
    ShiftRight,
    SectionMeta,
    SectionData,
    SectionProgram,
    KwStruct,
    Newline,
    Eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
    col: u32,
    source_file: []const u8 = "",
    int_value: u64 = 0,
    data_page: u8 = 0,
    data_offset: u16 = 0,
    data_explicit: bool = false,
};

pub const LexError = error{
    UnexpectedChar,
    InvalidInteger,
    UnterminatedString,
    InvalidSection,
    OutOfMemory,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    source_file: []const u8,

    pub fn init(src: []const u8) @This() {
        return .{ .src = src, .pos = 0, .line = 1, .col = 1, .source_file = "" };
    }

    pub fn initWithFile(src: []const u8, source_file: []const u8) @This() {
        return .{ .src = src, .pos = 0, .line = 1, .col = 1, .source_file = source_file };
    }

    fn peek(self: *@This()) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn peek2(self: *@This()) ?u8 {
        if (self.pos + 1 >= self.src.len) return null;
        return self.src[self.pos + 1];
    }

    fn advance(self: *@This()) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') { self.line += 1; self.col = 1; } else { self.col += 1; }
        return c;
    }

    fn skipLineComment(self: *@This()) void {
        while (self.peek()) |c| { if (c == '\n') break; _ = self.advance(); }
    }

    fn skipBlockComment(self: *@This()) void {
        while (self.peek()) |c| {
            _ = self.advance();
            if (c == '*' and self.peek() == '/') { _ = self.advance(); return; }
        }
    }

    fn skipWS(self: *@This()) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r' => _ = self.advance(),
                ';' => self.skipLineComment(),
                '/' => {
                    if (self.peek2() == '/') { self.skipLineComment(); }
                    else if (self.peek2() == '*') { _ = self.advance(); _ = self.advance(); self.skipBlockComment(); }
                    else break;
                },
                else => break,
            }
        }
    }

    fn lexInt(self: *@This(), start: usize, sl: u32, sc: u32, sf: []const u8) LexError!Token {
        var base: u64 = 10;
        var value: u64 = 0;

        if (self.src[start] == '0' and self.peek() != null) {
            switch (self.peek().?) {
                'x', 'X' => { _ = self.advance(); base = 16; },
                'b', 'B' => { _ = self.advance(); base = 2;  },
                'o', 'O' => { _ = self.advance(); base = 8;  },
                else     => value = self.src[start] - '0',
            }
        } else {
            value = self.src[start] - '0';
        }

        while (self.peek()) |c| {
            const d: ?u64 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => if (base == 16) @as(u64, c - 'a' + 10) else null,
                'A'...'F' => if (base == 16) @as(u64, c - 'A' + 10) else null,
                '_'       => { _ = self.advance(); continue; },
                else      => null,
            };
            if (d) |dv| {
                if (dv >= base) return LexError.InvalidInteger;
                value = value * base + dv;
                _ = self.advance();
            } else break;
        }
        return Token{ .kind = .Integer, .text = self.src[start..self.pos], .line = sl, .col = sc, .source_file = sf, .int_value = value };
    }

    fn lexSection(self: *@This(), sl: u32, sc: u32, sf: []const u8) LexError!Token {
        const saved_pos  = self.pos;
        const saved_line = self.line;
        const saved_col  = self.col;

        const ns = self.pos;
        while (self.peek()) |c| { if (c == ']' or c == '(') break; _ = self.advance(); }
        const name = std.mem.trim(u8, self.src[ns..self.pos], " \t");

        if (std.ascii.eqlIgnoreCase(name, "Meta")) {
            if (self.peek() == ']') _ = self.advance();
            return Token{ .kind = .SectionMeta, .text = "Meta", .line = sl, .col = sc, .source_file = sf };
        }
        if (std.ascii.eqlIgnoreCase(name, "Program")) {
            // consume optional (page:offset) — same syntax as Data, values ignored for now
            if (self.peek() == '(') {
                while (self.peek()) |c| { if (c == ')') { _ = self.advance(); break; } _ = self.advance(); }
            }
            if (self.peek() == ']') _ = self.advance();
            return Token{ .kind = .SectionProgram, .text = "Program", .line = sl, .col = sc, .source_file = sf };
        }
        if (std.ascii.eqlIgnoreCase(name, "Data")) {
            var page: u8 = 0;
            var offset: u16 = 0;
            var had_parens = false;
            if (self.peek() == '(') {
                had_parens = true;
                _ = self.advance();
                var pv: u64 = 0;
                while (self.peek()) |c| { if (c >= '0' and c <= '9') { pv = pv*10+(c-'0'); _ = self.advance(); } else break; }
                page = @truncate(pv);
                if (self.peek() == ':') _ = self.advance();
                var ov: u64 = 0;
                if (self.peek() == '0' and (self.peek2() == 'x' or self.peek2() == 'X')) {
                    _ = self.advance(); _ = self.advance();
                    while (self.peek()) |c| {
                        const d: ?u64 = switch(c) { '0'...'9'=>c-'0', 'a'...'f'=>c-'a'+10, 'A'...'F'=>c-'A'+10, else=>null };
                        if (d) |v| { ov=ov*16+v; _ = self.advance(); } else break;
                    }
                } else {
                    while (self.peek()) |c| { if (c>='0' and c<='9') { ov=ov*10+(c-'0'); _ = self.advance(); } else break; }
                }
                offset = @truncate(ov);
                if (self.peek() == ')') _ = self.advance();
            }
            if (self.peek() == ']') _ = self.advance();
            return Token{ .kind = .SectionData, .text = "Data", .line = sl, .col = sc, .source_file = sf, .data_page = page, .data_offset = offset, .data_explicit = had_parens };
        }

        // Not a known section header — treat '[' as a plain bracket token.
        self.pos  = saved_pos;
        self.line = saved_line;
        self.col  = saved_col;
        return Token{ .kind = .LBracket, .text = "[", .line = sl, .col = sc, .source_file = sf };
    }

    /// Parse a `#line N "file"` directive emitted by the preprocessor.
    /// Updates self.line and self.source_file; consumes through end-of-line.
    fn parseLineMark(self: *@This()) void {
        // skip whitespace after "#line"
        while (self.peek()) |c| { if (c == ' ' or c == '\t') _ = self.advance() else break; }
        // parse line number
        var n: u32 = 0;
        while (self.peek()) |c| {
            if (c >= '0' and c <= '9') { n = n * 10 + (c - '0'); _ = self.advance(); }
            else break;
        }
        // Set to n-1 so that the trailing '\n' (consumed by the caller via advance())
        // increments self.line to exactly n, making the NEXT real token land on line n.
        if (n > 0) self.line = n - 1;
        // skip whitespace
        while (self.peek()) |c| { if (c == ' ' or c == '\t') _ = self.advance() else break; }
        // parse optional quoted filename
        if (self.peek() == '"') {
            _ = self.advance();
            const fs = self.pos;
            while (self.peek()) |c| { if (c == '"' or c == '\n') break; _ = self.advance(); }
            self.source_file = self.src[fs..self.pos];
            if (self.peek() == '"') _ = self.advance();
        }
        // consume rest of line
        while (self.peek()) |c| { if (c == '\n') break; _ = self.advance(); }
    }

    pub fn next(self: *@This()) LexError!Token {
        self.skipWS();
        // Handle #line directives emitted by the preprocessor
        while (self.pos + 5 < self.src.len and
               std.mem.eql(u8, self.src[self.pos..self.pos+5], "#line") and
               (self.src[self.pos+5] == ' ' or self.src[self.pos+5] == '\t'))
        {
            self.pos += 5;
            self.parseLineMark();
            self.skipWS();
        }
        const sl = self.line;
        const sc = self.col;
        const sf = self.source_file;
        const c = self.peek() orelse return Token{ .kind = .Eof, .text = "", .line = sl, .col = sc, .source_file = sf };

        if (c == '\n') { _ = self.advance(); return Token{ .kind = .Newline, .text = "\n", .line = sl, .col = sc, .source_file = sf }; }
        if (c == '[') { _ = self.advance(); return self.lexSection(sl, sc, sf); }
        if (c == '"') {
            _ = self.advance();
            const start = self.pos;
            while (self.peek()) |ch| {
                if (ch == '"') {
                    const end = self.pos;
                    _ = self.advance();
                    return Token{ .kind = .StringLit, .text = self.src[start..end], .line = sl, .col = sc, .source_file = sf };
                }
                if (ch == '\\') _ = self.advance();
                _ = self.advance();
            }
            return LexError.UnterminatedString;
        }
        if (c == '\'') {
            _ = self.advance(); // skip opening '
            const cstart = self.pos;
            var value: u64 = 0;
            if (self.peek()) |ch| {
                if (ch == '\\') {
                    _ = self.advance();
                    if (self.peek()) |esc| {
                        value = switch (esc) {
                            'n'  => '\n',
                            'r'  => '\r',
                            't'  => '\t',
                            '\\' => '\\',
                            '\'' => '\'',
                            '0'  => 0,
                            else => @as(u64, esc),
                        };
                        _ = self.advance();
                    }
                } else {
                    value = @as(u64, ch);
                    _ = self.advance();
                }
            }
            const cend = self.pos;
            if (self.peek() == '\'') _ = self.advance();
            return Token{ .kind = .CharLit, .text = self.src[cstart..cend], .line = sl, .col = sc, .source_file = sf, .int_value = value };
        }
        if (c >= '0' and c <= '9') { const s = self.pos; _ = self.advance(); return self.lexInt(s, sl, sc, sf); }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const s = self.pos;
            while (self.peek()) |ch| { if (std.ascii.isAlphanumeric(ch) or ch == '_') { _ = self.advance(); } else break; }
            const text = self.src[s..self.pos];
            const kind: TokenKind = if (std.mem.eql(u8, text, "struct")) .KwStruct else .Identifier;
            return Token{ .kind = kind, .text = text, .line = sl, .col = sc, .source_file = sf };
        }
        _ = self.advance();
        return switch (c) {
            ':' => Token{ .kind = .Colon,     .text = ":",  .line = sl, .col = sc, .source_file = sf },
            ';' => Token{ .kind = .Semicolon,  .text = ";",  .line = sl, .col = sc, .source_file = sf },
            ',' => Token{ .kind = .Comma,      .text = ",",  .line = sl, .col = sc, .source_file = sf },
            '.' => Token{ .kind = .Dot,        .text = ".",  .line = sl, .col = sc, .source_file = sf },
            '{' => Token{ .kind = .LBrace,     .text = "{",  .line = sl, .col = sc, .source_file = sf },
            '}' => Token{ .kind = .RBrace,     .text = "}",  .line = sl, .col = sc, .source_file = sf },
            '[' => Token{ .kind = .LBracket,   .text = "[",  .line = sl, .col = sc, .source_file = sf },
            ']' => Token{ .kind = .RBracket,   .text = "]",  .line = sl, .col = sc, .source_file = sf },
            '(' => Token{ .kind = .LParen,     .text = "(",  .line = sl, .col = sc, .source_file = sf },
            ')' => Token{ .kind = .RParen,     .text = ")",  .line = sl, .col = sc, .source_file = sf },
            '#' => Token{ .kind = .Hash,       .text = "#",  .line = sl, .col = sc, .source_file = sf },
            '@' => Token{ .kind = .At,         .text = "@",  .line = sl, .col = sc, .source_file = sf },
            '$' => Token{ .kind = .Dollar,     .text = "$",  .line = sl, .col = sc, .source_file = sf },
            '+' => Token{ .kind = .Plus,       .text = "+",  .line = sl, .col = sc, .source_file = sf },
            '-' => Token{ .kind = .Minus,      .text = "-",  .line = sl, .col = sc, .source_file = sf },
            '*' => Token{ .kind = .Star,       .text = "*",  .line = sl, .col = sc, .source_file = sf },
            '/' => Token{ .kind = .Slash,      .text = "/",  .line = sl, .col = sc, .source_file = sf },
            '%' => Token{ .kind = .Percent,    .text = "%",  .line = sl, .col = sc, .source_file = sf },
            '&' => Token{ .kind = .Ampersand,  .text = "&",  .line = sl, .col = sc, .source_file = sf },
            '|' => Token{ .kind = .Pipe,       .text = "|",  .line = sl, .col = sc, .source_file = sf },
            '^' => Token{ .kind = .Caret,      .text = "^",  .line = sl, .col = sc, .source_file = sf },
            '~' => Token{ .kind = .Tilde,      .text = "~",  .line = sl, .col = sc, .source_file = sf },
            '<' => if (self.peek() == '<') blk: { _ = self.advance(); break :blk Token{ .kind = .ShiftLeft,  .text = "<<", .line = sl, .col = sc, .source_file = sf }; }
                   else Token{ .kind = .Identifier, .text = "<", .line = sl, .col = sc, .source_file = sf },
            '>' => if (self.peek() == '>') blk: { _ = self.advance(); break :blk Token{ .kind = .ShiftRight, .text = ">>", .line = sl, .col = sc, .source_file = sf }; }
                   else Token{ .kind = .Identifier, .text = ">", .line = sl, .col = sc, .source_file = sf },
            else => LexError.UnexpectedChar,
        };
    }

    /// Tokenize the entire source into a caller-owned slice.
    /// Caller must free with allocator.free().
    pub fn tokenize(self: *@This(), allocator: std.mem.Allocator) LexError![]Token {
        var list: std.ArrayList(Token) = .empty;
        errdefer list.deinit(allocator);
        while (true) {
            const tok = try self.next();
            try list.append(allocator, tok);
            if (tok.kind == .Eof) break;
        }
        return list.toOwnedSlice(allocator) catch return LexError.OutOfMemory;
    }
};
