const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const Token = lexer.Token;
pub const TokenKind = lexer.TokenKind;
pub const Loc = lexer.Loc;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidType,
    InvalidExpression,
    OutOfMemory,
    TooManyParams,
    UnsupportedFeature,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    tokens: []const Token,
    pos: usize,
    filename: []const u8,
    had_error: bool = false,

    pub fn init(gpa: std.mem.Allocator, tokens: []const Token, filename: []const u8) Parser {
        return .{ .gpa = gpa, .tokens = tokens, .pos = 0, .filename = filename };
    }

    // ─── token helpers ────────────────────────────────────────────────────────

    fn peek(self: *Parser) Token {
        if (self.pos >= self.tokens.len) return self.tokens[self.tokens.len - 1]; // eof
        return self.tokens[self.pos];
    }

    fn peekAt(self: *Parser, n: usize) Token {
        const i = self.pos + n;
        if (i >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[i];
    }

    fn advance(self: *Parser) Token {
        const t = self.peek();
        if (self.pos < self.tokens.len) self.pos += 1;
        return t;
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn eat(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) { _ = self.advance(); return true; }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (!self.check(kind)) {
            const t = self.peek();
            self.err(t.loc, "expected {s}, got '{s}'", .{ @tagName(kind), t.text });
            return ParseError.UnexpectedToken;
        }
        return self.advance();
    }

    fn err(self: *Parser, loc: Loc, comptime fmt: []const u8, args: anytype) void {
        self.had_error = true;
        std.debug.print("{s}:{}:{}: error: " ++ fmt ++ "\n", .{ loc.file, loc.line, loc.col } ++ args);
    }

    fn isTypeStart(self: *Parser) bool {
        return switch (self.peek().kind) {
            .ty_u8, .ty_u16, .ty_i8, .ty_i16, .ty_u8_vec2, .ty_i8_vec2, .kw_void => true,
            .l_bracket => true,
            .ident => {
                // ident followed by another ident → named type declaration
                const next = self.peekAt(1);
                return next.kind == .ident or next.kind == .kw_reg;
            },
            else => false,
        };
    }

    // ─── type parsing ─────────────────────────────────────────────────────────

    fn parseTypeExpr(self: *Parser) ParseError!ast.TypeExpr {
        const t = self.peek();
        switch (t.kind) {
            .ty_u8 => { _ = self.advance(); return .u8; },
            .ty_u16 => { _ = self.advance(); return .u16; },
            .ty_i8 => { _ = self.advance(); return .i8; },
            .ty_i16 => { _ = self.advance(); return .i16; },
            .ty_u8_vec2 => { _ = self.advance(); return .u8_vec2; },
            .ty_i8_vec2 => { _ = self.advance(); return .i8_vec2; },
            .kw_void => { _ = self.advance(); return .void; },
            .l_bracket => {
                _ = self.advance(); // [
                if (self.check(.star)) {
                    // [*]type — flex array
                    _ = self.advance(); // *
                    _ = try self.expect(.r_bracket);
                    const elem = try self.gpa.create(ast.TypeExpr);
                    elem.* = try self.parseTypeExpr();
                    return .{ .flex_array = elem };
                } else {
                    // [N]type — fixed array
                    const sz_tok = try self.expect(.int_lit);
                    const size = parseIntLit(sz_tok.text) catch 0;
                    _ = try self.expect(.r_bracket);
                    const elem = try self.gpa.create(ast.TypeExpr);
                    elem.* = try self.parseTypeExpr();
                    return .{ .array = .{ .size = @intCast(size), .elem = elem } };
                }
            },
            .ident => {
                _ = self.advance();
                return .{ .named = t.text };
            },
            else => {
                self.err(t.loc, "expected type, got '{s}'", .{t.text});
                return ParseError.InvalidType;
            },
        }
    }

    // ─── top-level ────────────────────────────────────────────────────────────

    pub fn parse(self: *Parser) ParseError!ast.File {
        var decls: std.ArrayList(ast.Decl) = .empty;
        while (!self.check(.eof)) {
            if (try self.parseDecl()) |d| {
                try decls.append(self.gpa, d);
            }
        }
        return ast.File{
            .name = self.filename,
            .decls = try decls.toOwnedSlice(self.gpa),
        };
    }

    fn parseDecl(self: *Parser) ParseError!?ast.Decl {
        const t = self.peek();
        switch (t.kind) {
            .prep_passthrough => {
                const tok = self.advance();
                return .{ .passthrough = tok.text };
            },
            .kw_import => {
                _ = self.advance();
                if (self.check(.string_lit)) _ = self.advance();
                return null;
            },
            .kw_struct => return .{ .struct_decl = try self.parseStructDecl(false) },
            .kw_union => return .{ .struct_decl = try self.parseStructDecl(true) },
            .kw_inline => {
                _ = self.advance();
                if (self.check(.kw_fn)) {
                    return .{ .fn_decl = try self.parseFnDecl(true) };
                }
                self.err(t.loc, "expected 'fn' after 'inline'", .{});
                return ParseError.UnexpectedToken;
            },
            .kw_fn => return .{ .fn_decl = try self.parseFnDecl(false) },
            .kw_const => return .{ .global_var = try self.parseGlobalVar(true) },
            .kw_page => {
                _ = self.advance();
                // __page(N) { __offset(off) decls... }
                // For now, parse and ignore page/offset hints
                _ = try self.expect(.l_paren);
                _ = try self.expect(.int_lit);
                _ = try self.expect(.r_paren);
                _ = try self.expect(.l_brace);
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    if (self.check(.kw_offset)) {
                        _ = self.advance();
                        _ = try self.expect(.l_paren);
                        _ = try self.expect(.int_lit);
                        _ = try self.expect(.r_paren);
                    }
                    if (try self.parseDecl()) |_| {}
                }
                _ = try self.expect(.r_brace);
                return null;
            },
            else => {
                if (self.isTypeStart()) {
                    return .{ .global_var = try self.parseGlobalVar(false) };
                }
                self.err(t.loc, "unexpected top-level token '{s}'", .{t.text});
                _ = self.advance();
                return null;
            },
        }
    }

    fn parseStructDecl(self: *Parser, is_union: bool) ParseError!ast.StructDecl {
        const kw = self.advance(); // struct or union
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.l_brace);
        var fields: std.ArrayList(ast.StructField) = .empty;
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const fname = try self.expect(.ident);
            _ = try self.expect(.colon);
            const ftype = try self.parseTypeExpr();
            _ = try self.expect(.semi);
            try fields.append(self.gpa, .{ .name = fname.text, .type_expr = ftype });
        }
        _ = try self.expect(.r_brace);
        _ = self.eat(.semi);
        return .{
            .name = name_tok.text,
            .fields = try fields.toOwnedSlice(self.gpa),
            .is_union = is_union,
            .loc = kw.loc,
        };
    }

    fn parseFnDecl(self: *Parser, is_inline: bool) ParseError!ast.FnDecl {
        const kw = self.advance(); // fn
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.l_paren);
        var params: std.ArrayList(ast.Param) = .empty;
        while (!self.check(.r_paren) and !self.check(.eof)) {
            if (params.items.len > 0) _ = try self.expect(.comma);
            const param = try self.parseParam();
            try params.append(self.gpa, param);
        }
        _ = try self.expect(.r_paren);
        const ret = try self.parseTypeExpr();
        const body = try self.parseBlock();
        return .{
            .name = name_tok.text,
            .params = try params.toOwnedSlice(self.gpa),
            .return_type = ret,
            .body = body,
            .is_inline = is_inline,
            .loc = kw.loc,
        };
    }

    fn parseParam(self: *Parser) ParseError!ast.Param {
        const t = self.peek();
        var reg_hint: ?[]const u8 = null;

        // Check for reg(RX) prefix before name:type
        // But spec shows: param: type or reg(RX) param_name : type
        // Actually spec: "addrPage: reg(R0) u8"  — reg comes AFTER the colon
        // So we parse: name : [reg(RX)] type
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.colon);

        if (self.check(.kw_reg)) {
            _ = self.advance(); // reg
            _ = try self.expect(.l_paren);
            const reg_tok = try self.expect(.ident);
            reg_hint = reg_tok.text;
            _ = try self.expect(.r_paren);
        }

        const type_expr = try self.parseTypeExpr();
        return .{
            .name = name_tok.text,
            .type_expr = type_expr,
            .reg_hint = reg_hint,
            .loc = t.loc,
        };
    }

    fn parseGlobalVar(self: *Parser, is_const: bool) ParseError!ast.GlobalVar {
        const t = self.peek();
        if (is_const) _ = self.advance(); // const
        const type_expr = try self.parseTypeExpr();
        const name_tok = try self.expect(.ident);
        var init_expr: ?*ast.Expr = null;
        if (self.eat(.eq)) {
            init_expr = try self.parseExpr();
        }
        _ = try self.expect(.semi);
        return .{
            .name = name_tok.text,
            .type_expr = type_expr,
            .init = init_expr,
            .is_const = is_const,
            .loc = t.loc,
        };
    }

    // ─── statements ───────────────────────────────────────────────────────────

    /// True when the current token is `(` and the next is a type keyword,
    /// indicating `(type name, type name) = expr` pair-declaration syntax.
    fn isPairDeclStart(self: *Parser) bool {
        return switch (self.peekAt(1).kind) {
            .ty_u8, .ty_u16, .ty_i8, .ty_i16, .ty_u8_vec2, .ty_i8_vec2 => true,
            else => false,
        };
    }

    /// Parse `(type1 name1, type2 name2) = expr;` and desugar it into a block:
    ///   type1 name1 = undefined;
    ///   type2 name2 = undefined;
    ///   (name1, name2) = expr;
    fn parsePairDecl(self: *Parser, loc: Loc) ParseError!ast.Stmt {
        _ = self.advance(); // consume '('

        const type1 = try self.parseTypeExpr();
        const name1 = (try self.expect(.ident)).text;
        _ = try self.expect(.comma);
        const type2 = try self.parseTypeExpr();
        const name2 = (try self.expect(.ident)).text;
        _ = try self.expect(.r_paren);
        _ = try self.expect(.eq);
        const rhs = try self.parseExpr();
        _ = try self.expect(.semi);

        // var decl 1
        const undef1 = try self.gpa.create(ast.Expr);
        undef1.* = .{ .undefined_val = loc };
        const s1 = try self.gpa.create(ast.Stmt);
        s1.* = .{ .var_decl = .{ .type_expr = type1, .name = name1, .reg_hint = null, .init = undef1, .loc = loc } };

        // var decl 2
        const undef2 = try self.gpa.create(ast.Expr);
        undef2.* = .{ .undefined_val = loc };
        const s2 = try self.gpa.create(ast.Stmt);
        s2.* = .{ .var_decl = .{ .type_expr = type2, .name = name2, .reg_hint = null, .init = undef2, .loc = loc } };

        // (name1, name2) = rhs
        const page_e = try self.gpa.create(ast.Expr);
        page_e.* = .{ .ident = .{ .name = name1, .loc = loc } };
        const addr_e = try self.gpa.create(ast.Expr);
        addr_e.* = .{ .ident = .{ .name = name2, .loc = loc } };
        const lhs_e = try self.gpa.create(ast.Expr);
        lhs_e.* = .{ .ext_ptr = .{ .page_expr = page_e, .addr_expr = addr_e, .loc = loc } };
        const assign_e = try self.gpa.create(ast.Expr);
        assign_e.* = .{ .binary = .{ .op = .assign, .lhs = lhs_e, .rhs = rhs, .loc = loc } };
        const s3 = try self.gpa.create(ast.Stmt);
        s3.* = .{ .expr_stmt = assign_e };

        const stmts = try self.gpa.alloc(*ast.Stmt, 3);
        stmts[0] = s1;
        stmts[1] = s2;
        stmts[2] = s3;
        return .{ .block = stmts };
    }

    fn parseBlock(self: *Parser) ParseError![]*ast.Stmt {
        _ = try self.expect(.l_brace);
        var stmts: std.ArrayList(*ast.Stmt) = .empty;
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const s = try self.parseStmt();
            try stmts.append(self.gpa, s);
        }
        _ = try self.expect(.r_brace);
        return stmts.toOwnedSlice(self.gpa);
    }

    fn parseStmt(self: *Parser) ParseError!*ast.Stmt {
        const t = self.peek();
        const s = try self.gpa.create(ast.Stmt);

        switch (t.kind) {
            .kw_const => {
                _ = self.advance();
                const name_tok = try self.expect(.ident);
                _ = try self.expect(.eq);
                const val = try self.parseExpr();
                _ = try self.expect(.semi);
                s.* = .{ .const_decl = .{ .name = name_tok.text, .value = val, .loc = t.loc } };
            },
            .kw_if => {
                _ = self.advance();
                _ = try self.expect(.l_paren);
                const cond = try self.parseExpr();
                _ = try self.expect(.r_paren);
                const then_body = try self.parseBlock();
                const then_s = try self.gpa.create(ast.Stmt);
                then_s.* = .{ .block = then_body };

                var else_s: ?*ast.Stmt = null;
                if (self.eat(.kw_else)) {
                    if (self.check(.kw_if)) {
                        else_s = try self.parseStmt();
                    } else {
                        const else_body = try self.parseBlock();
                        const es = try self.gpa.create(ast.Stmt);
                        es.* = .{ .block = else_body };
                        else_s = es;
                    }
                }
                s.* = .{ .if_stmt = .{ .cond = cond, .then_stmt = then_s, .else_stmt = else_s, .loc = t.loc } };
            },
            .kw_while => {
                _ = self.advance();
                _ = try self.expect(.l_paren);
                const cond = try self.parseExpr();
                _ = try self.expect(.r_paren);
                const body_stmts = try self.parseBlock();
                const body_s = try self.gpa.create(ast.Stmt);
                body_s.* = .{ .block = body_stmts };
                s.* = .{ .while_stmt = .{ .cond = cond, .body = body_s, .loc = t.loc } };
            },
            .kw_do => {
                _ = self.advance();
                const body_stmts = try self.parseBlock();
                const body_s = try self.gpa.create(ast.Stmt);
                body_s.* = .{ .block = body_stmts };
                _ = try self.expect(.kw_while);
                _ = try self.expect(.l_paren);
                const cond = try self.parseExpr();
                _ = try self.expect(.r_paren);
                _ = try self.expect(.semi);
                s.* = .{ .do_while = .{ .body = body_s, .cond = cond, .loc = t.loc } };
            },
            .kw_for => {
                s.* = try self.parseFor(t.loc);
            },
            .kw_inline => {
                _ = self.advance();
                if (self.check(.kw_for)) {
                    s.* = try self.parseInlineFor(t.loc);
                } else {
                    // inline fn at statement level — shouldn't happen, error
                    self.err(t.loc, "'inline' only valid for 'for' at statement level", .{});
                    return ParseError.UnexpectedToken;
                }
            },
            .kw_return => {
                _ = self.advance();
                var val: ?*ast.Expr = null;
                if (!self.check(.semi)) {
                    val = try self.parseExpr();
                }
                _ = try self.expect(.semi);
                s.* = .{ .return_stmt = .{ .value = val, .loc = t.loc } };
            },
            .kw_asm => {
                s.* = try self.parseAsmBlock(t.loc);
            },
            .l_brace => {
                const stmts = try self.parseBlock();
                s.* = .{ .block = stmts };
            },
            .kw_undefined => {
                // bare `undefined;` is odd but legal as a nop
                _ = self.advance();
                _ = try self.expect(.semi);
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .undefined_val = t.loc };
                s.* = .{ .expr_stmt = e };
            },
            else => {
                // (type name, type name) = expr  — paired ext-ptr declaration shorthand
                if (t.kind == .l_paren and self.isPairDeclStart()) {
                    s.* = try self.parsePairDecl(t.loc);
                } else if (self.isTypeStart()) {
                    s.* = try self.parseLocalVarDecl();
                } else {
                    const e = try self.parseExpr();
                    _ = try self.expect(.semi);
                    s.* = .{ .expr_stmt = e };
                }
            },
        }
        return s;
    }

    fn parseFor(self: *Parser, loc: Loc) ParseError!ast.Stmt {
        _ = self.advance(); // for
        _ = try self.expect(.l_paren);

        // init
        var init_stmt: ?*ast.Stmt = null;
        if (!self.check(.semi)) {
            const is = try self.gpa.create(ast.Stmt);
            if (self.isTypeStart()) {
                is.* = try self.parseLocalVarDecl();
            } else {
                const e = try self.parseExpr();
                _ = try self.expect(.semi);
                is.* = .{ .expr_stmt = e };
            }
            init_stmt = is;
        } else {
            _ = self.advance(); // ;
        }

        // condition
        var cond_expr: ?*ast.Expr = null;
        if (!self.check(.semi)) {
            cond_expr = try self.parseExpr();
        }
        _ = try self.expect(.semi);

        // update
        var update_expr: ?*ast.Expr = null;
        if (!self.check(.r_paren)) {
            update_expr = try self.parseExpr();
        }
        _ = try self.expect(.r_paren);

        const body_stmts = try self.parseBlock();
        const body_s = try self.gpa.create(ast.Stmt);
        body_s.* = .{ .block = body_stmts };

        return .{ .for_stmt = .{
            .init = init_stmt,
            .cond = cond_expr,
            .update = update_expr,
            .body = body_s,
            .loc = loc,
        }};
    }

    fn parseInlineFor(self: *Parser, loc: Loc) ParseError!ast.Stmt {
        _ = self.advance(); // for
        _ = try self.expect(.l_paren);
        const iter_type = try self.parseTypeExpr();
        const iter_name = try self.expect(.ident);
        _ = try self.expect(.colon);
        const start = try self.parseExpr();
        _ = try self.expect(.dot_dot);
        const end = try self.parseExpr();
        _ = try self.expect(.r_paren);
        const body_stmts = try self.parseBlock();
        const body_s = try self.gpa.create(ast.Stmt);
        body_s.* = .{ .block = body_stmts };
        return .{ .inline_for = .{
            .iter_type = iter_type,
            .iter_name = iter_name.text,
            .start = start,
            .end = end,
            .body = body_s,
            .loc = loc,
        }};
    }

    fn parseLocalVarDecl(self: *Parser) ParseError!ast.Stmt {
        const t = self.peek();
        const type_expr = try self.parseTypeExpr();

        // Optional reg hint after type: `reg(RX) name`
        var reg_hint: ?[]const u8 = null;
        if (self.check(.kw_reg)) {
            _ = self.advance();
            _ = try self.expect(.l_paren);
            const reg_tok = try self.expect(.ident);
            reg_hint = reg_tok.text;
            _ = try self.expect(.r_paren);
        }

        const name_tok = try self.expect(.ident);
        var init_expr: ?*ast.Expr = null;
        if (self.eat(.eq)) {
            init_expr = try self.parseExpr();
        }
        _ = try self.expect(.semi);
        return .{ .var_decl = .{
            .type_expr = type_expr,
            .name = name_tok.text,
            .reg_hint = reg_hint,
            .init = init_expr,
            .loc = t.loc,
        }};
    }

    fn parseAsmBlock(self: *Parser, loc: Loc) ParseError!ast.Stmt {
        _ = self.advance(); // asm
        _ = try self.expect(.l_brace);
        var lines: std.ArrayList([]const u8) = .empty;
        // Collect lines until matching }
        // We scan the raw source since tokens don't preserve asm content well.
        // Instead, collect all token texts until we hit a closing brace at depth 0.
        var depth: usize = 1;
        var line_buf: std.ArrayList(u8) = .empty;
        while (!self.check(.eof)) {
            const tok = self.peek();
            if (tok.kind == .l_brace) depth += 1;
            if (tok.kind == .r_brace) {
                depth -= 1;
                if (depth == 0) break;
            }
            // accumulate line
            if (line_buf.items.len > 0) try line_buf.append(self.gpa, ' ');
            try line_buf.appendSlice(self.gpa, tok.text);
            _ = self.advance();
        }
        if (line_buf.items.len > 0) {
            try lines.append(self.gpa, try line_buf.toOwnedSlice(self.gpa));
        }
        _ = try self.expect(.r_brace);
        return .{ .asm_block = .{
            .lines = try lines.toOwnedSlice(self.gpa),
            .loc = loc,
        }};
    }

    // ─── expressions ──────────────────────────────────────────────────────────

    fn parseExpr(self: *Parser) ParseError!*ast.Expr {
        return self.parseAssign();
    }

    fn parseAssign(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseTernary();

        const op_tok = self.peek();
        const op: ?ast.BinOp = switch (op_tok.kind) {
            .eq => .assign,
            .plus_eq => .add_assign,
            .minus_eq => .sub_assign,
            .star_eq => .mul_assign,
            .slash_eq => .div_assign,
            .percent_eq => .mod_assign,
            .amp_eq => .band_assign,
            .pipe_eq => .bor_assign,
            .caret_eq => .bxor_assign,
            .lt_lt_eq => .shl_assign,
            .gt_gt_eq => .shr_assign,
            else => null,
        };

        if (op) |o| {
            _ = self.advance();
            const rhs = try self.parseAssign(); // right-associative
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = o, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseTernary(self: *Parser) ParseError!*ast.Expr {
        const cond = try self.parseOr();
        if (!self.eat(.question)) return cond;
        const then_val = try self.parseExpr();
        _ = try self.expect(.colon);
        const else_val = try self.parseTernary();
        const e = try self.gpa.create(ast.Expr);
        e.* = .{ .ternary = .{ .cond = cond, .then_val = then_val, .else_val = else_val, .loc = cond.getLoc() } };
        return e;
    }

    fn parseOr(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseAnd();
        while (self.check(.pipe_pipe)) {
            const op_tok = self.advance();
            const rhs = try self.parseAnd();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = .lor, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseBitOr();
        while (self.check(.amp_amp)) {
            const op_tok = self.advance();
            const rhs = try self.parseBitOr();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = .land, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseBitOr(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseBitXor();
        while (self.check(.pipe)) {
            const op_tok = self.advance();
            const rhs = try self.parseBitXor();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = .bor, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseBitXor(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseBitAnd();
        while (self.check(.caret)) {
            const op_tok = self.advance();
            const rhs = try self.parseBitAnd();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = .bxor, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseBitAnd(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseEquality();
        while (self.check(.amp)) {
            const op_tok = self.advance();
            const rhs = try self.parseEquality();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = .band, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseEquality(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseComparison();
        while (true) {
            const op_tok = self.peek();
            const op: ast.BinOp = switch (op_tok.kind) {
                .eq_eq => .eq, .bang_eq => .neq, else => break,
            };
            _ = self.advance();
            const rhs = try self.parseComparison();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseComparison(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseShift();
        while (true) {
            const op_tok = self.peek();
            const op: ast.BinOp = switch (op_tok.kind) {
                .lt => .lt, .gt => .gt, .lt_eq => .le, .gt_eq => .ge, else => break,
            };
            _ = self.advance();
            const rhs = try self.parseShift();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseShift(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseAdd();
        while (true) {
            const op_tok = self.peek();
            const op: ast.BinOp = switch (op_tok.kind) {
                .lt_lt => .shl, .gt_gt => .shr, else => break,
            };
            _ = self.advance();
            const rhs = try self.parseAdd();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseAdd(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseMul();
        while (true) {
            const op_tok = self.peek();
            const op: ast.BinOp = switch (op_tok.kind) {
                .plus => .add, .minus => .sub, else => break,
            };
            _ = self.advance();
            const rhs = try self.parseMul();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseMul(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseUnary();
        while (true) {
            const op_tok = self.peek();
            const op: ast.BinOp = switch (op_tok.kind) {
                .star => .mul, .slash => .div, .percent => .mod, else => break,
            };
            _ = self.advance();
            const rhs = try self.parseUnary();
            const e = try self.gpa.create(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .loc = op_tok.loc } };
            lhs = e;
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Expr {
        const t = self.peek();
        switch (t.kind) {
            .minus => {
                _ = self.advance();
                const operand = try self.parseUnary();
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .unary = .{ .op = .neg, .operand = operand, .loc = t.loc } };
                return e;
            },
            .tilde => {
                _ = self.advance();
                const operand = try self.parseUnary();
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .unary = .{ .op = .bnot, .operand = operand, .loc = t.loc } };
                return e;
            },
            .bang => {
                _ = self.advance();
                const operand = try self.parseUnary();
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .unary = .{ .op = .lnot, .operand = operand, .loc = t.loc } };
                return e;
            },
            .amp => {
                _ = self.advance();
                const operand = try self.parseUnary();
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .unary = .{ .op = .addr_of, .operand = operand, .loc = t.loc } };
                return e;
            },
            .star => {
                _ = self.advance();
                // *(page, addr) or *simple_ptr
                if (self.check(.l_paren)) {
                    _ = self.advance();
                    const pg = try self.parseExpr();
                    _ = try self.expect(.comma);
                    const addr = try self.parseExpr();
                    _ = try self.expect(.r_paren);
                    const e = try self.gpa.create(ast.Expr);
                    e.* = .{ .ext_deref = .{ .page_expr = pg, .addr_expr = addr, .loc = t.loc } };
                    return e;
                }
                const operand = try self.parseUnary();
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .unary = .{ .op = .deref, .operand = operand, .loc = t.loc } };
                return e;
            },
            .plus_plus => {
                _ = self.advance();
                const operand = try self.parseUnary();
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .unary = .{ .op = .pre_inc, .operand = operand, .loc = t.loc } };
                return e;
            },
            .minus_minus => {
                _ = self.advance();
                const operand = try self.parseUnary();
                const e = try self.gpa.create(ast.Expr);
                e.* = .{ .unary = .{ .op = .pre_dec, .operand = operand, .loc = t.loc } };
                return e;
            },
            else => return self.parsePostfix(),
        }
    }

    fn parsePostfix(self: *Parser) ParseError!*ast.Expr {
        var base = try self.parsePrimary();
        while (true) {
            const t = self.peek();
            switch (t.kind) {
                .l_paren => {
                    // function call
                    _ = self.advance();
                    var args: std.ArrayList(*ast.Expr) = .empty;
                    while (!self.check(.r_paren) and !self.check(.eof)) {
                        if (args.items.len > 0) _ = try self.expect(.comma);
                        try args.append(self.gpa, try self.parseExpr());
                    }
                    _ = try self.expect(.r_paren);
                    const e = try self.gpa.create(ast.Expr);
                    e.* = .{ .call = .{
                        .callee = base,
                        .args = try args.toOwnedSlice(self.gpa),
                        .loc = t.loc,
                    }};
                    base = e;
                },
                .l_bracket => {
                    _ = self.advance();
                    const idx = try self.parseExpr();
                    _ = try self.expect(.r_bracket);
                    const e = try self.gpa.create(ast.Expr);
                    e.* = .{ .index = .{ .base = base, .idx = idx, .loc = t.loc } };
                    base = e;
                },
                .dot => {
                    _ = self.advance();
                    const field_tok = try self.expect(.ident);
                    if (std.mem.eql(u8, field_tok.text, "len")) {
                        const e = try self.gpa.create(ast.Expr);
                        e.* = .{ .dot_len = .{ .base = base, .loc = t.loc } };
                        base = e;
                    } else {
                        const e = try self.gpa.create(ast.Expr);
                        e.* = .{ .field = .{ .base = base, .name = field_tok.text, .loc = t.loc } };
                        base = e;
                    }
                },
                .plus_plus => {
                    _ = self.advance();
                    const e = try self.gpa.create(ast.Expr);
                    e.* = .{ .unary = .{ .op = .post_inc, .operand = base, .loc = t.loc } };
                    base = e;
                },
                .minus_minus => {
                    _ = self.advance();
                    const e = try self.gpa.create(ast.Expr);
                    e.* = .{ .unary = .{ .op = .post_dec, .operand = base, .loc = t.loc } };
                    base = e;
                },
                else => break,
            }
        }
        return base;
    }

    fn parsePrimary(self: *Parser) ParseError!*ast.Expr {
        const t = self.peek();
        const e = try self.gpa.create(ast.Expr);

        switch (t.kind) {
            .int_lit => {
                _ = self.advance();
                const val = parseIntLit(t.text) catch 0;
                e.* = .{ .int_lit = .{ .value = @intCast(val), .loc = t.loc } };
                return e;
            },
            .string_lit => {
                _ = self.advance();
                e.* = .{ .string_lit = .{ .raw = t.text, .loc = t.loc } };
                return e;
            },
            .kw_undefined => {
                _ = self.advance();
                e.* = .{ .undefined_val = t.loc };
                return e;
            },
            .ident => {
                _ = self.advance();
                e.* = .{ .ident = .{ .name = t.text, .loc = t.loc } };
                return e;
            },
            .l_paren => {
                _ = self.advance();
                const first = try self.parseExpr();
                if (self.eat(.comma)) {
                    // extended pointer: (page_expr, addr_expr)
                    const addr = try self.parseExpr();
                    _ = try self.expect(.r_paren);
                    if (self.check(.l_paren)) {
                        // extended call: (page, addr)(args...)
                        _ = self.advance();
                        var args: std.ArrayList(*ast.Expr) = .empty;
                        while (!self.check(.r_paren) and !self.check(.eof)) {
                            if (args.items.len > 0) _ = try self.expect(.comma);
                            try args.append(self.gpa, try self.parseExpr());
                        }
                        _ = try self.expect(.r_paren);
                        e.* = .{ .ext_call = .{
                            .page_expr = first,
                            .addr_expr = addr,
                            .args = try args.toOwnedSlice(self.gpa),
                            .loc = t.loc,
                        }};
                    } else {
                        e.* = .{ .ext_ptr = .{ .page_expr = first, .addr_expr = addr, .loc = t.loc } };
                    }
                    return e;
                }
                _ = try self.expect(.r_paren);
                return first;
            },
            else => {
                self.err(t.loc, "expected expression, got '{s}'", .{t.text});
                return ParseError.InvalidExpression;
            },
        }
    }
};

pub fn parseIntLit(text: []const u8) !i64 {
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        return @intCast(try std.fmt.parseInt(u64, text[2..], 16));
    }
    if (text.len > 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B')) {
        return @intCast(try std.fmt.parseInt(u64, text[2..], 2));
    }
    return std.fmt.parseInt(i64, text, 10);
}
