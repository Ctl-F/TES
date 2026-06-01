/// TES Assembler — Parser + Code Emitter (Zig 0.14+ / 0.16+)
///
/// Two-pass design:
///   Pass 1 — parse all sections, build symbol table, emit instruction words.
///             Forward-reference branches are emitted as placeholder words and
///             recorded for fixup in pass 2.
///   Pass 2 — patch placeholder branch words now that all labels are known.
const std = @import("std");
const lexer = @import("lexer.zig");
const sym_mod = @import("symbols.zig");
const encoder = @import("encoder.zig");
const tbf = @import("tbf.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const SymbolTable = sym_mod.SymbolTable;
const StructDef = sym_mod.StructDef;
const FieldDef = sym_mod.FieldDef;
const PrimType = sym_mod.PrimType;
const DataSymbol = sym_mod.DataSymbol;
const RegID = encoder.RegID;
const OpcodeInfo = encoder.OpcodeInfo;
const Format = encoder.Format;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidType,
    InvalidOperand,
    InvalidMemoryOperand,
    OffsetOutOfRange,
    LabelNotFound,
    StructNotFound,
    OutOfMemory,
    DuplicateSymbol,
    UndefinedSymbol,
    TypeMismatch,
    FieldNotFound,
    UndefinedStruct,
    InvalidInitializer,
    BranchTooFar,
    PageOverflow,
    SectionOverlap,
};

const BranchKind = enum { Near, NearCond };

const TempLabelEntry = struct {
    /// Globally-unique internal name (e.g. "__tmp_3_loop"); heap-allocated,
    /// tracked in Parser.temp_label_strings for deallocation.
    internal_name: []const u8,
    /// False until @name: is actually declared (may start as a forward-ref reservation).
    defined: bool,
};

const SectionRange = struct {
    page: u8,
    start: u16,
    end: u16,
    source_file: []const u8,
    line: u32,
};

const ForwardRef = struct {
    instr_idx:   u32,
    from_idx:    u32,
    label:       []u8,   // heap-allocated; freed in deinit
    kind:        BranchKind,
    cond_reg:    RegID,
    line:        u32,
    col:         u32,
    source_file: []const u8,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    pos: usize,

    sym: SymbolTable,
    tbfWriter: tbf.TBFWriter,

    forward_refs: std.ArrayList(ForwardRef),

    /// Per-page byte accumulation buffers
    data_buf: std.AutoHashMapUnmanaged(u8, std.ArrayList(u8)),
    /// Next free byte offset per page
    page_cursors: std.AutoHashMapUnmanaged(u8, u16),
    /// High-water mark (max cursor ever reached) per page — used to start implicit [Data] sections
    page_high_water: std.AutoHashMapUnmanaged(u8, u16),
    /// Recorded ranges of all data sections for overlap detection
    section_ranges: std.ArrayList(SectionRange),

    emit_debug: bool,

    /// Stack of register alias scopes opened by @{ ... }.
    /// Each entry maps alias name (heap-allocated) → RegID.
    alias_stack: std.ArrayList(std.StringHashMapUnmanaged(RegID)),
    /// Stack of scoped-constant scopes. Each entry maps bare name (heap-allocated) → i64 value.
    const_stack: std.ArrayList(std.StringHashMapUnmanaged(i64)),
    /// Stack of temp-label scopes. Each entry maps bare name (heap-allocated) → TempLabelEntry.
    temp_label_stack: std.ArrayList(std.StringHashMapUnmanaged(TempLabelEntry)),
    /// All internal_name strings ever allocated for temp labels; freed in deinit.
    temp_label_strings: std.ArrayList([]u8),
    /// Counter for generating unique temp-label internal names.
    temp_label_counter: u32,
    /// Stack of scoped-struct name lists. Each entry holds the names of structs
    /// defined with @struct in that scope; they are removed from sym on scope close.
    struct_scope_stack: std.ArrayList(std.ArrayList([]u8)),
    /// Stack of scoped-enum name lists. Each entry holds the names of enums
    /// defined with @enum in that scope; they are removed from sym on scope close.
    enum_scope_stack: std.ArrayList(std.ArrayList([]u8)),

    /// Optional map from source filename → original source text, used to
    /// display the source line and a caret underline in error messages.
    source_map: ?*const std.StringHashMapUnmanaged([]const u8),

    // ── init / deinit ──────────────────────────────────────────────────────

    pub fn init(
        allocator: std.mem.Allocator,
        tokens: []const Token,
        emit_debug: bool,
        source_map: ?*const std.StringHashMapUnmanaged([]const u8),
    ) @This() {
        return .{
            .allocator    = allocator,
            .tokens       = tokens,
            .pos          = 0,
            .sym          = SymbolTable.init(allocator),
            .tbfWriter    = tbf.TBFWriter.init(allocator),
            .forward_refs = .empty,
            .data_buf       = .{},
            .page_cursors   = .{},
            .page_high_water = .{},
            .section_ranges = .empty,
            .emit_debug          = emit_debug,
            .alias_stack         = .empty,
            .const_stack         = .empty,
            .temp_label_stack    = .empty,
            .temp_label_strings  = .empty,
            .temp_label_counter  = 0,
            .struct_scope_stack  = .empty,
            .enum_scope_stack    = .empty,
            .source_map          = source_map,
        };
    }

    // ── Source context helpers ─────────────────────────────────────────────

    /// Print the source line and a caret underline for `tok`.
    fn printSourceContext(self: *const @This(), tok: Token) void {
        self.printSourceContextAt(tok.source_file, tok.line, tok.col, tok.text.len);
    }

    /// Print the source line at (source_file, line) with a caret at (col, span_len).
    /// col is 1-based; span_len is the number of characters to underline (clamped to ≥1).
    fn printSourceContextAt(
        self: *const @This(),
        source_file: []const u8,
        line: u32,
        col: u32,
        span_len: usize,
    ) void {
        const map = self.source_map orelse return;
        const src = map.get(source_file) orelse return;

        // Walk to the requested line (1-based).
        var line_no: u32 = 1;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw| : (line_no += 1) {
            if (line_no != line) continue;
            const text = std.mem.trimEnd(u8, raw, "\r");
            std.debug.print("    {s}\n", .{text});

            // Build the underline: 4 spaces of prefix, (col-1) spaces, then ^~~~
            const prefix: usize = 4;
            const col0: usize   = if (col > 0) col - 1 else 0;
            const width: usize  = @max(span_len, 1);

            var buf: [1024]u8 = undefined;
            const available = buf.len;
            const total = @min(prefix + col0 + width, available);
            if (total == 0) return;
            @memset(buf[0..total], ' ');
            const caret_pos = @min(prefix + col0, total - 1);
            buf[caret_pos] = '^';
            if (caret_pos + 1 < total) @memset(buf[caret_pos + 1 .. total], '~');
            std.debug.print("{s}\n", .{buf[0..total]});
            return;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.sym.deinit();
        self.tbfWriter.deinit();
        for (self.forward_refs.items) |*ref| self.allocator.free(ref.label);
        self.forward_refs.deinit(self.allocator);
        var it = self.data_buf.valueIterator();
        while (it.next()) |buf| buf.deinit(self.allocator);
        self.data_buf.deinit(self.allocator);
        self.page_cursors.deinit(self.allocator);
        self.page_high_water.deinit(self.allocator);
        self.section_ranges.deinit(self.allocator);
        for (self.alias_stack.items) |*scope| {
            var kit = scope.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
            scope.deinit(self.allocator);
        }
        self.alias_stack.deinit(self.allocator);
        for (self.const_stack.items) |*scope| {
            var kit = scope.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
            scope.deinit(self.allocator);
        }
        self.const_stack.deinit(self.allocator);
        for (self.temp_label_stack.items) |*scope| {
            var kit = scope.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
            scope.deinit(self.allocator);
        }
        self.temp_label_stack.deinit(self.allocator);
        for (self.temp_label_strings.items) |s| self.allocator.free(s);
        self.temp_label_strings.deinit(self.allocator);
        for (self.struct_scope_stack.items) |*list| {
            for (list.items) |name| self.allocator.free(name);
            list.deinit(self.allocator);
        }
        self.struct_scope_stack.deinit(self.allocator);
        for (self.enum_scope_stack.items) |*list| {
            for (list.items) |name| self.allocator.free(name);
            list.deinit(self.allocator);
        }
        self.enum_scope_stack.deinit(self.allocator);
    }

    // ── Token helpers ──────────────────────────────────────────────────────

    fn peek(self: *const @This()) Token {
        var i = self.pos;
        while (i < self.tokens.len) : (i += 1) {
            if (self.tokens[i].kind != .Newline) return self.tokens[i];
        }
        return eofTok();
    }

    fn peekRaw(self: *const @This()) Token {
        return if (self.pos < self.tokens.len) self.tokens[self.pos] else eofTok();
    }

    fn advance(self: *@This()) Token {
        while (self.pos < self.tokens.len and self.tokens[self.pos].kind == .Newline)
            self.pos += 1;
        if (self.pos >= self.tokens.len) return eofTok();
        defer self.pos += 1;
        return self.tokens[self.pos];
    }

    fn advanceRaw(self: *@This()) Token {
        if (self.pos >= self.tokens.len) return eofTok();
        defer self.pos += 1;
        return self.tokens[self.pos];
    }

    fn skipNewlines(self: *@This()) void {
        while (self.pos < self.tokens.len and self.tokens[self.pos].kind == .Newline)
            self.pos += 1;
    }

    fn skipToEOL(self: *@This()) void {
        while (self.pos < self.tokens.len) {
            const k = self.tokens[self.pos].kind;
            if (k == .Newline or k == .Semicolon or k == .Eof) break;
            self.pos += 1;
        }
    }

    fn consumeEOL(self: *@This()) void {
        while (self.pos < self.tokens.len) {
            const k = self.tokens[self.pos].kind;
            if (k == .Semicolon or k == .Newline) { self.pos += 1; } else break;
        }
    }

    fn expect(self: *@This(), kind: TokenKind) ParseError!Token {
        const t = self.advance();
        if (t.kind != kind) {
            std.debug.print("{s}:{}:{}: error: expected '{s}', got '{s}'\n", .{
                t.source_file, t.line, t.col, @tagName(kind), t.text,
            });
            self.printSourceContext(t);
            return ParseError.UnexpectedToken;
        }
        return t;
    }

    fn expectIdent(self: *@This()) ParseError!Token {
        const t = self.advance();
        if (t.kind != .Identifier) {
            std.debug.print("{s}:{}:{}: error: expected identifier, got '{s}'\n", .{
                t.source_file, t.line, t.col, t.text,
            });
            self.printSourceContext(t);
            return ParseError.UnexpectedToken;
        }
        return t;
    }

    fn tryConsume(self: *@This(), kind: TokenKind) bool {
        if (self.peek().kind == kind) { _ = self.advance(); return true; }
        return false;
    }

    fn eofTok() Token {
        return .{ .kind = .Eof, .text = "", .line = 0, .col = 0 };
    }

    fn isSection(kind: TokenKind) bool {
        return kind == .SectionMeta or kind == .SectionData or kind == .SectionProgram;
    }

    // ── Public entry ───────────────────────────────────────────────────────

    pub fn parse(self: *@This()) ParseError!void {
        try self.pass1();
        self.sym.resolveStructRefs() catch |e| return switch (e) {
            sym_mod.SymbolError.UndefinedStruct => ParseError.UndefinedStruct,
            else => ParseError.OutOfMemory,
        };
        try self.pass2FixupRefs();
        // Verify _start was defined somewhere
        _ = self.sym.resolveLabel("_start") catch {
            std.debug.print("Error: '_start' label is not defined\n", .{});
            return ParseError.LabelNotFound;
        };
        try self.flushDataPages();
    }

    // ══════════════════════════════════════════════════════════════════════
    // PASS 1
    // ══════════════════════════════════════════════════════════════════════

    fn pass1(self: *@This()) ParseError!void {
        // Emit prologue: bn _start (instr 0) + hlt (instr 1).
        // The bn is patched in pass2 once _start is resolved.
        // The hlt guards against falling through if execution ever
        // reaches the top of the instruction stream unexpectedly.
        const start_label = self.allocator.dupe(u8, "_start") catch return ParseError.OutOfMemory;
        try self.emitWord(@as(u32, 0x7E)); // bn placeholder
        self.forward_refs.append(self.allocator, .{
            .instr_idx = 0, .from_idx = 0,
            .label = start_label, .kind = .Near, .cond_reg = .R0, .line = 0, .col = 0, .source_file = "",
        }) catch return ParseError.OutOfMemory;
        try self.emitWord(@as(u32, 0x40)); // hlt
        while (true) {
            self.skipNewlines();
            const t = self.peekRaw();
            switch (t.kind) {
                .Eof            => break,
                .SectionMeta    => { _ = self.advanceRaw(); try self.parseMeta(); },
                .SectionData    => { const st = self.advanceRaw(); try self.parseData(st.data_page, st.data_offset, st.data_explicit, st.source_file, st.line); },
                .SectionProgram => { _ = self.advanceRaw(); try self.parseProgram(); },
                .Newline        => self.pos += 1,
                else => {
                    std.debug.print("{s}:{}:{}: warning: unexpected top-level token '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
                    self.printSourceContext(t);
                    self.skipToEOL();
                },
            }
        }
    }

    // ── [Meta] ────────────────────────────────────────────────────────────

    fn parseMeta(self: *@This()) ParseError!void {
        while (true) {
            self.skipNewlines();
            const t = self.peekRaw();
            if (isSection(t.kind) or t.kind == .Eof) break;
            if (t.kind == .Newline) { self.pos += 1; continue; }
            if (t.kind == .KwStruct) { try self.parseStruct(); continue; }
            if (t.kind == .KwEnum)   { try self.parseEnum();   continue; }
            std.debug.print("{s}:{}:{}: warning: unexpected token in [Meta]: '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
            self.printSourceContext(t);
            self.skipToEOL();
        }
        self.sym.resolveForwardStructRefs();
    }

    fn parseStruct(self: *@This()) ParseError!void {
        _ = self.advance(); // 'struct'
        const name_tok = try self.expectIdent();
        try self.parseStructCore(name_tok);
    }

    fn parseStructCore(self: *@This(), name_tok: Token) ParseError!void {
        _ = try self.expect(.LBrace);

        var fields: std.ArrayList(FieldDef) = .empty;
        errdefer {
            for (fields.items) |f| {
                self.allocator.free(f.name);
                if (f.struct_name) |sn| self.allocator.free(sn);
            }
            fields.deinit(self.allocator);
        }

        var byte_offset: u16 = 0;
        var max_align: u16 = 1;
        while (true) {
            self.skipNewlines();
            if (self.peek().kind == .RBrace) { _ = self.advance(); break; }
            if (self.peek().kind == .Eof) return ParseError.UnexpectedEof;

            const fname_tok = try self.expectIdent();
            _ = try self.expect(.Colon);

            // Accept optional prefix-array syntax: [N]type  (Zig-style)
            var count: u16 = 1;
            if (self.peek().kind == .LBracket) {
                _ = self.advance();
                const n_tok = try self.expect(.Integer);
                count = @truncate(n_tok.int_value);
                _ = try self.expect(.RBracket);
            }

            const type_tok = try self.expectIdent();

            const fname = self.allocator.dupe(u8, fname_tok.text) catch return ParseError.OutOfMemory;
            errdefer self.allocator.free(fname);

            var prim: PrimType = undefined;
            var sname: ?[]u8 = null;
            var fsz: u16 = undefined;
            var falign: u16 = 1;

            if (PrimType.fromStr(type_tok.text)) |p| {
                prim = p;
                // Also accept legacy suffix-array syntax: u8[N]
                if (count == 1 and self.peek().kind == .LBracket) {
                    _ = self.advance();
                    const n_tok = try self.expect(.Integer);
                    count = @truncate(n_tok.int_value);
                    _ = try self.expect(.RBracket);
                }
                fsz = p.size() * count;
                falign = p.alignment();
            } else {
                prim  = .Struct;
                sname = self.allocator.dupe(u8, type_tok.text) catch return ParseError.OutOfMemory;
                if (self.sym.getStruct(type_tok.text)) |sd| {
                    fsz = sd.total_size * count;
                    falign = sd.alignment;
                } else {
                    std.debug.print("Warning: field '{s}' references unknown struct '{s}'\n", .{ fname, type_tok.text });
                    fsz = 0;
                    falign = 1;
                }
            }

            // Apply natural alignment padding before this field
            byte_offset = @intCast(((@as(u32, byte_offset) + falign - 1) / falign) * falign);
            if (falign > max_align) max_align = falign;

            fields.append(self.allocator, .{
                .name = fname, .prim = prim, .struct_name = sname,
                .offset = byte_offset, .size = fsz, .count = count,
            }) catch return ParseError.OutOfMemory;

            byte_offset += fsz;
            _ = self.tryConsume(.Semicolon);
        }
        _ = self.tryConsume(.Semicolon);

        // Pad total size to struct alignment (matching C/Zig extern struct)
        const total_size: u16 = @intCast(((@as(u32, byte_offset) + max_align - 1) / max_align) * max_align);

        // defineStruct dupes the name, so we can pass token text directly
        self.sym.defineStruct(.{
            .name = name_tok.text, .fields = fields, .total_size = total_size, .alignment = max_align,
        }) catch |e| return switch (e) {
            sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
            else => ParseError.OutOfMemory,
        };
        // fields is now owned by the StructDef in the symbol table; don't deinit it here
        // (errdefer above won't fire on success)
    }

    /// Parse `@struct Name { ... };` — caller has already consumed `@` and `struct`.
    /// Defines the struct in the symbol table for the duration of the current scope,
    /// then removes it when the scope closes.
    fn parseAtStruct(self: *@This()) ParseError!void {
        if (self.struct_scope_stack.items.len == 0) {
            const t = self.peek();
            std.debug.print("{s}:{}:{}: error: @struct used outside of a '@{{' scope\n",
                .{ t.source_file, t.line, t.col });
            self.printSourceContext(t);
            self.skipToEOL();
            return ParseError.UnexpectedToken;
        }
        const name_tok = try self.expectIdent();
        // Shadowing check: no existing struct or symbol with this name.
        if (self.sym.getStruct(name_tok.text) != null) {
            std.debug.print("{s}:{}:{}: error: '@struct {s}' shadows an existing struct\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
            self.printSourceContext(name_tok);
            return ParseError.DuplicateSymbol;
        }
        if (self.sym.getSymbol(name_tok.text) != null) {
            std.debug.print("{s}:{}:{}: error: '@struct {s}' shadows existing symbol '{s}'\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text, name_tok.text });
            self.printSourceContext(name_tok);
            return ParseError.DuplicateSymbol;
        }
        try self.parseStructCore(name_tok);
        // Resolve any within-scope forward struct refs (e.g. Outer referencing Inner).
        self.sym.resolveForwardStructRefs();
        // Track this struct name so it can be removed when the scope closes.
        const name_copy = self.allocator.dupe(u8, name_tok.text) catch return ParseError.OutOfMemory;
        const top = &self.struct_scope_stack.items[self.struct_scope_stack.items.len - 1];
        top.append(self.allocator, name_copy) catch {
            self.allocator.free(name_copy);
            return ParseError.OutOfMemory;
        };
    }

    // ── enum parsing ──────────────────────────────────────────────────────

    /// Parse `enum Name { ... };` body. Caller has already consumed `enum`.
    /// Defines the enum globally (for use in [Meta] sections).
    fn parseEnum(self: *@This()) ParseError!void {
        _ = self.advance(); // 'enum'
        const name_tok = try self.expectIdent();
        try self.parseEnumCore(name_tok, false);
    }

    /// Parse `@enum Name { ... };` body. Caller has already consumed `@` and `enum`.
    /// Defines the enum for the duration of the current scope.
    fn parseAtEnum(self: *@This()) ParseError!void {
        if (self.enum_scope_stack.items.len == 0) {
            const t = self.peek();
            std.debug.print("{s}:{}:{}: error: @enum used outside of a '@{{' scope\n",
                .{ t.source_file, t.line, t.col });
            self.printSourceContext(t);
            self.skipToEOL();
            return ParseError.UnexpectedToken;
        }
        const name_tok = try self.expectIdent();
        // Shadowing check
        if (self.sym.getEnum(name_tok.text) != null) {
            std.debug.print("{s}:{}:{}: error: '@enum {s}' shadows an existing enum\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
            self.printSourceContext(name_tok);
            return ParseError.DuplicateSymbol;
        }
        if (self.sym.getStruct(name_tok.text) != null or self.sym.getSymbol(name_tok.text) != null) {
            std.debug.print("{s}:{}:{}: error: '@enum {s}' shadows an existing symbol\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
            self.printSourceContext(name_tok);
            return ParseError.DuplicateSymbol;
        }
        try self.parseEnumCore(name_tok, true);
        // Track so it can be removed when the scope closes.
        const name_copy = self.allocator.dupe(u8, name_tok.text) catch return ParseError.OutOfMemory;
        const top = &self.enum_scope_stack.items[self.enum_scope_stack.items.len - 1];
        top.append(self.allocator, name_copy) catch {
            self.allocator.free(name_copy);
            return ParseError.OutOfMemory;
        };
    }

    /// Shared body for both parseEnum and parseAtEnum.
    /// Expects the name token to already be consumed; parses `{ field; field = val; ... }`.
    fn parseEnumCore(self: *@This(), name_tok: Token, is_scoped: bool) ParseError!void {
        _ = is_scoped;
        _ = try self.expect(.LBrace);

        var fields: std.ArrayList(sym_mod.EnumField) = .empty;
        errdefer {
            for (fields.items) |f| self.allocator.free(f.name);
            fields.deinit(self.allocator);
        }

        var cur_val: i64 = 0;
        var max_val: i64 = 0;
        var first = true;

        while (true) {
            self.skipNewlines();
            if (self.peek().kind == .RBrace) { _ = self.advance(); break; }
            if (self.peek().kind == .Eof) return ParseError.UnexpectedEof;

            const fname_tok = try self.expectIdent();
            // Reject reserved implicit field names
            if (std.mem.eql(u8, fname_tok.text, "count") or std.mem.eql(u8, fname_tok.text, "max")) {
                std.debug.print("{s}:{}:{}: error: '{s}' is a reserved enum field name\n",
                    .{ fname_tok.source_file, fname_tok.line, fname_tok.col, fname_tok.text });
                self.printSourceContext(fname_tok);
                return ParseError.DuplicateSymbol;
            }

            // Optional `= value`
            if (self.peek().kind == .Equals) {
                _ = self.advance(); // consume '='
                cur_val = try self.parseConstExpr();
            }

            const fname = self.allocator.dupe(u8, fname_tok.text) catch return ParseError.OutOfMemory;
            fields.append(self.allocator, .{ .name = fname, .value = cur_val }) catch {
                self.allocator.free(fname);
                return ParseError.OutOfMemory;
            };

            if (first or cur_val > max_val) max_val = cur_val;
            first = false;
            cur_val += 1;
        }

        const count: u32 = @intCast(fields.items.len);
        self.sym.defineEnum(.{
            .name   = name_tok.text,
            .fields = fields,
            .count  = count,
            .max    = max_val,
        }) catch |e| return switch (e) {
            sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
            else => ParseError.OutOfMemory,
        };
        // fields is now owned by the EnumDef in the symbol table
    }

    // ── [Data] ────────────────────────────────────────────────────────────

    fn parseData(self: *@This(), page: u8, section_offset: u16, explicit: bool, sec_source_file: []const u8, sec_line: u32) ParseError!void {
        if (explicit) {
            self.page_cursors.put(self.allocator, page, section_offset) catch return ParseError.OutOfMemory;
        } else {
            const hw = self.page_high_water.get(page) orelse 0;
            self.page_cursors.put(self.allocator, page, hw) catch return ParseError.OutOfMemory;
        }
        const section_start = self.page_cursors.get(page) orelse section_offset;

        while (true) {
            self.skipNewlines();
            const t = self.peekRaw();
            if (isSection(t.kind) or t.kind == .Eof) break;
            if (t.kind == .Newline) { self.pos += 1; continue; }
            if (t.kind == .Hash) { self.skipToEOL(); continue; }
            if (t.kind != .Identifier) {
                std.debug.print("{s}:{}:{}: warning: unexpected token in [Data]: '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
                self.printSourceContext(t);
                self.skipToEOL();
                continue;
            }
            try self.parseDataDecl(page);
        }

        const section_end = self.page_cursors.get(page) orelse section_start;

        // Update high-water mark
        const cur_hw = self.page_high_water.get(page) orelse 0;
        if (section_end > cur_hw)
            self.page_high_water.put(self.allocator, page, section_end) catch return ParseError.OutOfMemory;

        // Validate overlaps with previously-recorded sections
        if (section_end > section_start) {
            for (self.section_ranges.items) |prev| {
                if (prev.page != page) continue;
                if (section_start < prev.end and section_end > prev.start) {
                    std.debug.print("{s}:{}: error: data section [Data({d}:0x{X:0>4})] (0x{X:0>4}..0x{X:0>4}) overlaps with section at {s}:{} (0x{X:0>4}..0x{X:0>4})\n", .{
                        sec_source_file, sec_line, page, section_start,
                        section_start, section_end,
                        prev.source_file, prev.line, prev.start, prev.end,
                    });
                    return ParseError.SectionOverlap;
                }
            }
        }

        self.section_ranges.append(self.allocator, .{
            .page = page, .start = section_start, .end = section_end,
            .source_file = sec_source_file, .line = sec_line,
        }) catch return ParseError.OutOfMemory;
    }

    fn pageDataBuf(self: *@This(), page: u8) ParseError!*std.ArrayList(u8) {
        const r = self.data_buf.getOrPut(self.allocator, page) catch return ParseError.OutOfMemory;
        if (!r.found_existing) r.value_ptr.* = .empty;
        return r.value_ptr;
    }

    fn parseDataDecl(self: *@This(), page: u8) ParseError!void {
        const name_tok = try self.expectIdent();
        _ = try self.expect(.Colon);

        // Bare string literal: Label: "hello\0"
        if (self.peek().kind == .StringLit) {
            try self.parseStringData(page, name_tok);
            return;
        }

        // Bare label: Label:  (no type or value — zero-size address marker)
        const next_kind = self.peek().kind;
        if (next_kind == .Newline or next_kind == .Eof or next_kind == .Semicolon or
            next_kind == .SectionMeta or next_kind == .SectionData or next_kind == .SectionProgram) {
            const sym_offset = self.page_cursors.get(page) orelse 0;
            self.sym.defineData(name_tok.text, DataSymbol{
                .page = page, .offset = sym_offset, .size = 0,
                .prim = .u8, .struct_name = null, .struct_def = null,
            }) catch |e| return switch (e) {
                sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
                else => ParseError.OutOfMemory,
            };
            _ = self.tryConsume(.Semicolon);
            return;
        }

        _ = try self.expect(.Dot);
        const type_tok = try self.expectIdent();

        const prim: PrimType = PrimType.fromStr(type_tok.text) orelse .Struct;
        const sname: ?[]const u8 = if (prim == .Struct) type_tok.text else null;

        var type_size: u16 = undefined;
        var elem_count: u16 = 1;
        if (prim == .Struct) {
            const sd = self.sym.getStruct(type_tok.text) orelse {
                std.debug.print("{s}:{}:{}: error: unknown type '{s}'\n", .{ type_tok.source_file, type_tok.line, type_tok.col, type_tok.text });
                self.printSourceContext(type_tok);
                return ParseError.InvalidType;
            };
            type_size = sd.total_size;
        } else {
            // Check for array count: .u8[N]
            if (self.peek().kind == .LBracket) {
                _ = self.advance();
                const n_tok = try self.expect(.Integer);
                elem_count = @truncate(n_tok.int_value);
                _ = try self.expect(.RBracket);
            }
            type_size = prim.size() * elem_count;
        }

        const sym_offset = self.page_cursors.get(page) orelse 0;

        self.sym.defineData(name_tok.text, DataSymbol{
            .page = page, .offset = sym_offset, .size = type_size,
            .prim = prim, .struct_name = sname,
            .struct_def = if (prim == .Struct) self.sym.getStruct(type_tok.text) else null,
        }) catch |e| return switch (e) {
            sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
            else => ParseError.OutOfMemory,
        };

        if (self.emit_debug)
            self.tbfWriter.addDebugSymbol((@as(u32, page) << 16) | sym_offset, name_tok.text)
                catch return ParseError.OutOfMemory;

        const buf = try self.pageDataBuf(page);
        const buf_saved = buf.items.len;
        if (sym_offset > buf.items.len) {
            buf.ensureTotalCapacity(self.allocator, sym_offset) catch return ParseError.OutOfMemory;
            const gap_start = buf.items.len;
            buf.items.len = sym_offset;
            @memset(buf.items[gap_start..], 0);
        } else if (sym_offset < buf.items.len) {
            buf.ensureTotalCapacity(self.allocator, sym_offset + type_size) catch return ParseError.OutOfMemory;
            buf.items.len = sym_offset;
        }

        // No initializer = zero-fill (arrays with no init, or optional omission)
        const next = self.peek();
        if (next.kind == .Dot or next.kind == .Integer or next.kind == .Minus or
            next.kind == .Identifier or next.kind == .CharLit)
        {
            if (elem_count > 1 and next.kind == .Dot and self.peekIsDotBrace()) {
                // .{v1, v2, ...} for explicit array init
                _ = self.advance(); // consume '.'
                _ = try self.expect(.LBrace);
                var i: u16 = 0;
                while (i < elem_count) : (i += 1) {
                    if (i > 0) _ = self.tryConsume(.Comma);
                    const val = try self.parseConstExpr();
                    try self.appendValue(buf, prim, val);
                }
                _ = try self.expect(.RBrace);
            } else if (elem_count > 1) {
                // Single value fills all elements
                const val = try self.parseConstExpr();
                var i: u16 = 0;
                while (i < elem_count) : (i += 1) try self.appendValue(buf, prim, val);
            } else {
                try self.parseInitializer(buf, prim, sname);
            }
        } else {
            // Zero-fill
            var i: u16 = 0;
            while (i < type_size) : (i += 1)
                buf.append(self.allocator, 0) catch return ParseError.OutOfMemory;
        }

        if (buf.items.len < buf_saved) buf.items.len = buf_saved;

        const new_cursor = @addWithOverflow(sym_offset, type_size);
        if (new_cursor[1] != 0) {
            std.debug.print("{s}:{}:{}: error: symbol '{s}' overflows page {d} (offset 0x{X:0>4} + size {} = 0x{X} exceeds 64KB)\n", .{
                name_tok.source_file, name_tok.line, name_tok.col,
                name_tok.text, page, sym_offset, type_size,
                @as(u32, sym_offset) + @as(u32, type_size),
            });
            self.printSourceContext(name_tok);
            return ParseError.PageOverflow;
        }
        self.page_cursors.put(self.allocator, page, new_cursor[0]) catch return ParseError.OutOfMemory;
        _ = self.tryConsume(.Semicolon);
    }

    fn peekIsBrace(self: *const @This()) bool {
        var i = self.pos;
        while (i < self.tokens.len and self.tokens[i].kind == .Newline) i += 1;
        return i < self.tokens.len and self.tokens[i].kind == .LBrace;
    }

    /// Returns true when the current token is '.' and the next non-newline
    /// token is '{' — i.e. the sequence ".{" that starts an array initializer.
    fn peekIsDotBrace(self: *const @This()) bool {
        var i = self.pos + 1; // skip the '.' at self.pos
        while (i < self.tokens.len and self.tokens[i].kind == .Newline) i += 1;
        return i < self.tokens.len and self.tokens[i].kind == .LBrace;
    }

    fn parseStringData(self: *@This(), page: u8, name_tok: Token) ParseError!void {
        const str_tok = self.advance();
        const str = str_tok.text; // raw bytes between quotes (no surrounding quotes)

        const sym_offset = self.page_cursors.get(page) orelse 0;
        const buf = try self.pageDataBuf(page);
        const buf_saved = buf.items.len;
        if (sym_offset > buf.items.len) {
            buf.ensureTotalCapacity(self.allocator, sym_offset) catch return ParseError.OutOfMemory;
            const gap_start = buf.items.len;
            buf.items.len = sym_offset;
            @memset(buf.items[gap_start..], 0);
        } else if (sym_offset < buf.items.len) {
            buf.items.len = sym_offset;
        }

        const before = buf.items.len;
        try self.emitStringBytes(buf, str);
        const str_size: u16 = @truncate(buf.items.len - before);
        if (buf.items.len < buf_saved) buf.items.len = buf_saved;

        self.sym.defineData(name_tok.text, DataSymbol{
            .page = page, .offset = sym_offset, .size = str_size,
            .prim = .u8, .struct_name = null, .struct_def = null,
        }) catch |e| return switch (e) {
            sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
            else => ParseError.OutOfMemory,
        };

        if (self.emit_debug)
            self.tbfWriter.addDebugSymbol((@as(u32, page) << 16) | sym_offset, name_tok.text)
                catch return ParseError.OutOfMemory;

        self.page_cursors.put(self.allocator, page, sym_offset + str_size) catch return ParseError.OutOfMemory;
        _ = self.tryConsume(.Semicolon);
    }

    fn emitStringBytes(self: *@This(), buf: *std.ArrayList(u8), str: []const u8) ParseError!void {
        var i: usize = 0;
        while (i < str.len) {
            if (str[i] == '\\' and i + 1 < str.len) {
                const byte: u8 = switch (str[i + 1]) {
                    'n'  => '\n',
                    'r'  => '\r',
                    't'  => '\t',
                    '\\' => '\\',
                    '"'  => '"',
                    '\'' => '\'',
                    '0'  => 0,
                    else => str[i + 1],
                };
                buf.append(self.allocator, byte) catch return ParseError.OutOfMemory;
                i += 2;
            } else {
                buf.append(self.allocator, str[i]) catch return ParseError.OutOfMemory;
                i += 1;
            }
        }
    }

    fn parseInitializer(self: *@This(), buf: *std.ArrayList(u8), prim: PrimType, sname: ?[]const u8) ParseError!void {
        if (self.peek().kind == .Dot) {
            _ = self.advance();
            _ = try self.expect(.LBrace);
            if (prim == .Struct) {
                const sd = self.sym.getStruct(sname.?) orelse return ParseError.StructNotFound;
                for (sd.fields.items, 0..) |field, fi| {
                    if (fi > 0) _ = self.tryConsume(.Comma);
                    if (field.count > 1) {
                        var ci: u16 = 0;
                        while (ci < field.count) : (ci += 1) {
                            if (ci > 0) _ = self.tryConsume(.Comma);
                            const val = try self.parseConstExpr();
                            try self.appendValue(buf, field.prim, val);
                        }
                    } else {
                        try self.parseInitializer(buf, field.prim, field.struct_name);
                    }
                }
            } else {
                const val = try self.parseConstExpr();
                try self.appendValue(buf, prim, val);
            }
            _ = try self.expect(.RBrace);
            return;
        }
        // Struct type with a scalar initializer (e.g. `myVar: .Pawn 0`).
        // Only `0` is accepted — it zero-fills the entire struct.
        if (prim == .Struct) {
            const sd = self.sym.getStruct(sname.?) orelse return ParseError.StructNotFound;
            const val = try self.parseConstExpr();
            if (val != 0) return ParseError.InvalidInitializer;
            var i: u16 = 0;
            while (i < sd.total_size) : (i += 1)
                buf.append(self.allocator, 0) catch return ParseError.OutOfMemory;
            return;
        }
        const val = try self.parseConstExpr();
        try self.appendValue(buf, prim, val);
    }

    fn appendValue(self: *@This(), buf: *std.ArrayList(u8), prim: PrimType, val: i64) ParseError!void {
        switch (prim) {
            .u8  => buf.append(self.allocator, @truncate(@as(u64, @bitCast(val)))) catch return ParseError.OutOfMemory,
            .i8  => buf.append(self.allocator, @bitCast(@as(i8, @truncate(val))))  catch return ParseError.OutOfMemory,
            .u16 => {
                var tmp: [2]u8 = undefined;
                std.mem.writeInt(u16, &tmp, @truncate(@as(u64, @bitCast(val))), .little);
                buf.appendSlice(self.allocator, &tmp) catch return ParseError.OutOfMemory;
            },
            .i16 => {
                var tmp: [2]u8 = undefined;
                const v16: i16 = @truncate(val);
                std.mem.writeInt(u16, &tmp, @bitCast(v16), .little);
                buf.appendSlice(self.allocator, &tmp) catch return ParseError.OutOfMemory;
            },
            .Struct => return ParseError.InvalidInitializer,
        }
    }

    fn parseConstExpr(self: *@This()) ParseError!i64 {
        var negate = false;
        if (self.peek().kind == .Minus) { _ = self.advance(); negate = true; }
        const t = self.advance();
        var val: i64 = switch (t.kind) {
            .Integer    => @bitCast(t.int_value),
            .CharLit    => @as(i64, @intCast(t.int_value)),
            .Dollar     => blk: {
                const name_tok = try self.expectIdent();
                break :blk try self.parseBuiltinConst(name_tok);
            },
            .At => blk: {
                const name_tok = try self.expectIdent();
                if (self.lookupScopedConst(name_tok.text)) |v| break :blk v;
                std.debug.print("{s}:{}:{}: error: '@{s}' is not a scoped constant\n",
                    .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
                self.printSourceContext(name_tok);
                return ParseError.UndefinedSymbol;
            },
            .Identifier => blk: {
                var full: std.ArrayList(u8) = .empty;
                defer full.deinit(self.allocator);
                full.appendSlice(self.allocator, t.text) catch return ParseError.OutOfMemory;
                while (self.peekRaw().kind == .Dot) {
                    _ = self.advanceRaw();
                    const f = try self.expectIdent();
                    full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                    full.appendSlice(self.allocator, f.text) catch return ParseError.OutOfMemory;
                }
                // Try enum first (EnumName.field)
                if (self.sym.resolveEnumField(full.items)) |ev| break :blk ev;
                break :blk @intCast(self.sym.resolveAddress(full.items) catch {
                    std.debug.print("{s}:{}:{}: error: undefined symbol '{s}'\n", .{ t.source_file, t.line, t.col, full.items });
                    self.printSourceContext(t);
                    return ParseError.UndefinedSymbol;
                });
            },
            else => {
                std.debug.print("{s}:{}:{}: error: expected constant expression, got '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
                self.printSourceContext(t);
                return ParseError.InvalidOperand;
            },
        };
        if (negate) val = -val;
        return val;
    }

    fn parseBuiltinConst(self: *@This(), name_tok: Token) ParseError!i64 {
        if (std.mem.eql(u8, name_tok.text, "nSizeOf")) {
            _ = try self.expect(.LParen);
            const arg = try self.expectIdent();
            _ = try self.expect(.RParen);
            if (sym_mod.PrimType.fromStr(arg.text)) |p| return -@as(i64, @intCast(p.size()));
            if (self.sym.getStruct(arg.text)) |sd| return -@as(i64, @intCast(sd.total_size));
            if (self.sym.getSymbol(arg.text)) |sym| switch (sym.*) {
                .Data  => |d| return -@as(i64, @intCast(d.size)),
                .Label => {
                    std.debug.print("{s}:{}:{}: error: $nSizeOf: '{s}' is a label, not a type\n",
                        .{ arg.source_file, arg.line, arg.col, arg.text });
                    self.printSourceContext(arg);
                    return ParseError.TypeMismatch;
                },
            };
            std.debug.print("{s}:{}:{}: error: $nSizeOf: unknown type or symbol '{s}'\n",
                .{ arg.source_file, arg.line, arg.col, arg.text });
            self.printSourceContext(arg);
            return ParseError.UndefinedSymbol;
        }
        if (std.mem.eql(u8, name_tok.text, "sizeOfAligned") or
            std.mem.eql(u8, name_tok.text, "nSizeOfAligned"))
        {
            _ = try self.expect(.LParen);
            const arg = try self.expectIdent();
            _ = try self.expect(.Comma);
            const align_tok = try self.expect(.Integer);
            _ = try self.expect(.RParen);
            const sz: i64 = blk: {
                if (sym_mod.PrimType.fromStr(arg.text)) |p| break :blk @intCast(p.size());
                if (self.sym.getStruct(arg.text)) |sd| break :blk @intCast(sd.total_size);
                if (self.sym.getSymbol(arg.text)) |sym| switch (sym.*) {
                    .Data  => |d| break :blk @intCast(d.size),
                    .Label => {
                        std.debug.print("{s}:{}:{}: error: ${s}: '{s}' is a label, not a type\n",
                            .{ arg.source_file, arg.line, arg.col, name_tok.text, arg.text });
                        self.printSourceContext(arg);
                        return ParseError.TypeMismatch;
                    },
                };
                std.debug.print("{s}:{}:{}: error: ${s}: unknown type or symbol '{s}'\n",
                    .{ arg.source_file, arg.line, arg.col, name_tok.text, arg.text });
                self.printSourceContext(arg);
                return ParseError.UndefinedSymbol;
            };
            const alignment = @as(i64, @intCast(align_tok.int_value));
            if (alignment <= 0) {
                std.debug.print("{s}:{}:{}: error: ${s}: alignment must be positive\n",
                    .{ align_tok.source_file, align_tok.line, align_tok.col, name_tok.text });
                self.printSourceContext(align_tok);
                return ParseError.InvalidOperand;
            }
            const aligned_sz = @divTrunc(sz + alignment - 1, alignment) * alignment;
            return if (std.mem.eql(u8, name_tok.text, "nSizeOfAligned")) -aligned_sz else aligned_sz;
        }
        if (std.mem.eql(u8, name_tok.text, "sizeOf")) {
            _ = try self.expect(.LParen);
            const arg = try self.expectIdent();
            _ = try self.expect(.RParen);
            if (sym_mod.PrimType.fromStr(arg.text)) |p| return @intCast(p.size());
            if (self.sym.getStruct(arg.text)) |sd| return @intCast(sd.total_size);
            if (self.sym.getSymbol(arg.text)) |sym| switch (sym.*) {
                .Data  => |d| return @intCast(d.size),
                .Label => {
                    std.debug.print("{s}:{}:{}: error: $sizeOf: '{s}' is a label, not a type\n",
                        .{ arg.source_file, arg.line, arg.col, arg.text });
                    self.printSourceContext(arg);
                    return ParseError.TypeMismatch;
                },
            };
            std.debug.print("{s}:{}:{}: error: $sizeOf: unknown type or symbol '{s}'\n",
                .{ arg.source_file, arg.line, arg.col, arg.text });
            self.printSourceContext(arg);
            return ParseError.UndefinedSymbol;
        }
        if (std.mem.eql(u8, name_tok.text, "offsetOf")) {
            _ = try self.expect(.LParen);
            const base_tok = try self.expectIdent();
            _ = try self.expect(.Comma);
            const field_tok = try self.expectIdent();
            var full: std.ArrayList(u8) = .empty;
            defer full.deinit(self.allocator);
            full.appendSlice(self.allocator, base_tok.text) catch return ParseError.OutOfMemory;
            full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
            full.appendSlice(self.allocator, field_tok.text) catch return ParseError.OutOfMemory;
            while (self.peekRaw().kind == .Dot) {
                _ = self.advanceRaw();
                const sub = try self.expectIdent();
                full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                full.appendSlice(self.allocator, sub.text) catch return ParseError.OutOfMemory;
            }
            var index_extra: i64 = 0;
            if (self.peekRaw().kind == .LBracket) {
                _ = self.advanceRaw();
                const idx_tok = try self.expect(.Integer);
                _ = try self.expect(.RBracket);
                const elem_size = self.sym.resolveFieldElemSize(full.items) catch |e| {
                    switch (e) {
                        sym_mod.SymbolError.FieldNotFound => {
                            std.debug.print("{s}:{}:{}: error: $offsetOf: '{s}' is not an array field\n", .{ field_tok.source_file, field_tok.line, field_tok.col, full.items });
                            self.printSourceContext(field_tok);
                            return ParseError.FieldNotFound;
                        },
                        sym_mod.SymbolError.UndefinedSymbol => {
                            std.debug.print("{s}:{}:{}: error: $offsetOf: undefined symbol '{s}'\n", .{ base_tok.source_file, base_tok.line, base_tok.col, full.items });
                            self.printSourceContext(base_tok);
                            return ParseError.UndefinedSymbol;
                        },
                        else => return ParseError.InvalidOperand,
                    }
                };
                index_extra = @as(i64, @intCast(idx_tok.int_value)) * @as(i64, @intCast(elem_size));
            }
            _ = try self.expect(.RParen);
            const off = self.sym.resolveFieldOffset(full.items) catch |e| {
                switch (e) {
                    sym_mod.SymbolError.UndefinedSymbol => {
                        std.debug.print("{s}:{}:{}: error: $offsetOf: undefined symbol '{s}'\n", .{ base_tok.source_file, base_tok.line, base_tok.col, full.items });
                        self.printSourceContext(base_tok);
                        return ParseError.UndefinedSymbol;
                    },
                    sym_mod.SymbolError.FieldNotFound => {
                        std.debug.print("{s}:{}:{}: error: $offsetOf: field '{s}' not found\n", .{ field_tok.source_file, field_tok.line, field_tok.col, full.items });
                        self.printSourceContext(field_tok);
                        return ParseError.FieldNotFound;
                    },
                    sym_mod.SymbolError.TypeMismatch => {
                        std.debug.print("{s}:{}:{}: error: $offsetOf: '{s}' is a label, not a struct\n", .{ base_tok.source_file, base_tok.line, base_tok.col, base_tok.text });
                        self.printSourceContext(base_tok);
                        return ParseError.TypeMismatch;
                    },
                    else => return ParseError.InvalidOperand,
                }
            };
            return @as(i64, off) + index_extra;
        }
        std.debug.print("{s}:{}:{}: error: unknown builtin '${s}'\n",
            .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
        self.printSourceContext(name_tok);
        return ParseError.InvalidOperand;
    }

    // ── [Program] ─────────────────────────────────────────────────────────

    fn parseProgram(self: *@This()) ParseError!void {
        try self.parseProgramInner(self.tokens.len);
        if (self.alias_stack.items.len > 0) {
            std.debug.print("warning: {} unclosed '@{{' scope(s) at end of [Program]\n",
                .{self.alias_stack.items.len});
            while (self.alias_stack.items.len > 0) {
                var scope = self.alias_stack.pop().?;
                var kit = scope.keyIterator();
                while (kit.next()) |k| self.allocator.free(k.*);
                scope.deinit(self.allocator);
            }
            while (self.const_stack.items.len > 0) {
                var scope = self.const_stack.pop().?;
                var kit = scope.keyIterator();
                while (kit.next()) |k| self.allocator.free(k.*);
                scope.deinit(self.allocator);
            }
            while (self.temp_label_stack.items.len > 0) {
                var scope = self.temp_label_stack.pop().?;
                var kit = scope.keyIterator();
                while (kit.next()) |k| self.allocator.free(k.*);
                scope.deinit(self.allocator);
            }
            while (self.struct_scope_stack.items.len > 0) {
                var sscope = self.struct_scope_stack.pop().?;
                for (sscope.items) |name| {
                    self.sym.removeStruct(name);
                    self.allocator.free(name);
                }
                sscope.deinit(self.allocator);
            }
            while (self.enum_scope_stack.items.len > 0) {
                var escope = self.enum_scope_stack.pop().?;
                for (escope.items) |name| {
                    self.sym.removeEnum(name);
                    self.allocator.free(name);
                }
                escope.deinit(self.allocator);
            }
        }
    }

    /// Inner program parsing loop. Processes tokens from self.pos up to (not including)
    /// stop_pos, handling labels, scope directives, and instructions. Does not clean up
    /// unclosed scopes — the caller is responsible for that.
    fn parseProgramInner(self: *@This(), stop_pos: usize) ParseError!void {
        while (true) {
            // Skip newlines, but don't advance past stop_pos
            while (self.pos < stop_pos and self.pos < self.tokens.len and
                   self.tokens[self.pos].kind == .Newline)
                self.pos += 1;
            if (self.pos >= stop_pos) break;
            const t = self.peekRaw();
            if (isSection(t.kind) or t.kind == .Eof) break;
            if (t.kind == .Newline) { self.pos += 1; continue; }

            if (t.kind == .Identifier and self.isLabelDecl()) {
                _ = self.advanceRaw();
                self.skipNewlines();
                _ = self.advanceRaw(); // ':'
                const instr_idx: u32 = @intCast(self.tbfWriter.instructions.items.len);
                self.sym.defineLabel(t.text, instr_idx) catch |e| return switch (e) {
                    sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
                    else => ParseError.OutOfMemory,
                };
                if (self.emit_debug)
                    self.tbfWriter.addDebugSymbol(instr_idx, t.text) catch return ParseError.OutOfMemory;
                continue;
            }

            // Named scope open: ScopeName@{  (name is informative only)
            if (t.kind == .Identifier and self.isNamedScopeOpen()) {
                _ = self.advanceRaw(); // consume name
                _ = self.advanceRaw(); // consume '@'
                _ = self.advanceRaw(); // consume '{'
                self.alias_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
                self.const_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
                self.temp_label_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
                self.struct_scope_stack.append(self.allocator, .empty) catch return ParseError.OutOfMemory;
                self.enum_scope_stack.append(self.allocator, .empty) catch return ParseError.OutOfMemory;
                self.consumeEOL();
                continue;
            }

            // @{ — open a new alias scope
            // @bind name : reg — declare alias (requires open scope)
            if (t.kind == .At) {
                _ = self.advanceRaw();
                const next = self.peekRaw();
                if (next.kind == .LBrace) {
                    _ = self.advanceRaw();
                    self.alias_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
                    self.const_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
                    self.temp_label_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
                    self.struct_scope_stack.append(self.allocator, .empty) catch return ParseError.OutOfMemory;
                    self.enum_scope_stack.append(self.allocator, .empty) catch return ParseError.OutOfMemory;
                    self.consumeEOL();
                    continue;
                }
                if (next.kind == .Identifier and std.mem.eql(u8, next.text, "bind")) {
                    _ = self.advanceRaw();
                    try self.parseAtBind();
                    continue;
                }
                if (next.kind == .Identifier and std.mem.eql(u8, next.text, "const")) {
                    _ = self.advanceRaw();
                    try self.parseAtConst();
                    continue;
                }
                if (next.kind == .KwStruct) {
                    _ = self.advanceRaw();
                    try self.parseAtStruct();
                    continue;
                }
                if (next.kind == .KwEnum) {
                    _ = self.advanceRaw();
                    try self.parseAtEnum();
                    continue;
                }
                if (next.kind == .Identifier and std.mem.eql(u8, next.text, "repeat")) {
                    _ = self.advanceRaw();
                    try self.parseAtRepeat();
                    continue;
                }
                // @name: — temp label declaration
                if (next.kind == .Identifier and self.isLabelDecl()) {
                    _ = self.advanceRaw(); // consume identifier
                    self.skipNewlines();
                    _ = self.advanceRaw(); // consume ':'
                    try self.defineTempLabel(next);
                    continue;
                }
                std.debug.print("{s}:{}:{}: warning: unknown '@' directive '{s}'\n",
                    .{ next.source_file, next.line, next.col, next.text });
                self.printSourceContext(next);
                self.skipToEOL();
                continue;
            }

            // } — close the current alias scope
            // Optional same-line }@name label is consumed but ignored (informative only)
            if (t.kind == .RBrace) {
                _ = self.advanceRaw();
                if (self.alias_stack.items.len == 0) {
                    std.debug.print("{s}:{}:{}: error: '}}' without matching '@{{'\n",
                        .{ t.source_file, t.line, t.col });
                    self.printSourceContext(t);
                    return ParseError.UnexpectedToken;
                }
                var scope = self.alias_stack.pop().?;
                var kit = scope.keyIterator();
                while (kit.next()) |k| self.allocator.free(k.*);
                scope.deinit(self.allocator);
                // Pop const scope
                var cscope = self.const_stack.pop().?;
                var ckit = cscope.keyIterator();
                while (ckit.next()) |k| self.allocator.free(k.*);
                cscope.deinit(self.allocator);
                // Pop temp-label scope; validate every entry was actually declared
                var tscope = self.temp_label_stack.pop().?;
                var had_unresolved = false;
                var tit = tscope.iterator();
                while (tit.next()) |entry| {
                    if (!entry.value_ptr.defined) {
                        std.debug.print("error: '@{s}' was referenced but never declared in its '@{{...}}' scope\n",
                            .{entry.key_ptr.*});
                        had_unresolved = true;
                    }
                    self.allocator.free(entry.key_ptr.*);
                    // internal_name lives in temp_label_strings; freed in deinit
                }
                tscope.deinit(self.allocator);
                if (had_unresolved) return ParseError.LabelNotFound;
                // Pop scoped-struct scope: remove each struct from the symbol table.
                var sscope = self.struct_scope_stack.pop().?;
                for (sscope.items) |name| {
                    self.sym.removeStruct(name);
                    self.allocator.free(name);
                }
                sscope.deinit(self.allocator);
                // Pop scoped-enum scope: remove each enum from the symbol table.
                var escope = self.enum_scope_stack.pop().?;
                for (escope.items) |name| {
                    self.sym.removeEnum(name);
                    self.allocator.free(name);
                }
                escope.deinit(self.allocator);
                // Consume optional same-line }@label (must be on the same line — no newline between)
                if (self.peekRaw().kind == .At) {
                    _ = self.advanceRaw();
                    if (self.peekRaw().kind == .Identifier) _ = self.advanceRaw();
                }
                self.consumeEOL();
                continue;
            }

            try self.parseInstruction();
        }
    }

    /// Parse `@repeat(count, iter) { body }`.
    /// Caller has already consumed `@` and `repeat`.
    /// Repeats body `count` times; `@iter` is a scoped constant holding the current
    /// iteration index (0-based, upper bound excluded).
    fn parseAtRepeat(self: *@This()) ParseError!void {
        _ = try self.expect(.LParen);
        const count_val = try self.parseConstExpr();
        if (count_val < 0) {
            const t = self.peek();
            std.debug.print("{s}:{}:{}: error: @repeat count must be non-negative, got {}\n",
                .{ t.source_file, t.line, t.col, count_val });
            return ParseError.InvalidOperand;
        }
        const count: usize = @intCast(count_val);
        _ = try self.expect(.Comma);
        const iter_tok = try self.expectIdent();
        _ = try self.expect(.RParen);
        _ = try self.expect(.LBrace);
        self.consumeEOL();

        const body_start = self.pos;

        // Scan for the matching '}' by tracking brace nesting depth.
        var depth: usize = 1;
        var scan: usize = self.pos;
        while (scan < self.tokens.len and depth > 0) {
            switch (self.tokens[scan].kind) {
                .LBrace => depth += 1,
                .RBrace => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
            scan += 1;
        }
        if (depth != 0) {
            std.debug.print("{s}:{}:{}: error: @repeat body is missing closing '}}'\n",
                .{ iter_tok.source_file, iter_tok.line, iter_tok.col });
            return ParseError.UnexpectedEof;
        }
        const body_end = scan; // index of the closing '}'

        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.pos = body_start;

            // Push fresh scopes for this iteration
            self.alias_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
            self.const_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
            self.temp_label_stack.append(self.allocator, .{}) catch return ParseError.OutOfMemory;
            self.struct_scope_stack.append(self.allocator, .empty) catch return ParseError.OutOfMemory;
            self.enum_scope_stack.append(self.allocator, .empty) catch return ParseError.OutOfMemory;

            // Inject iteration variable into the const scope
            const iter_key = self.allocator.dupe(u8, iter_tok.text) catch return ParseError.OutOfMemory;
            const top_const = &self.const_stack.items[self.const_stack.items.len - 1];
            top_const.put(self.allocator, iter_key, @intCast(i)) catch {
                self.allocator.free(iter_key);
                return ParseError.OutOfMemory;
            };

            try self.parseProgramInner(body_end);

            // Pop and clean up all iteration scopes
            var scope = self.alias_stack.pop().?;
            var kit = scope.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
            scope.deinit(self.allocator);

            var cscope = self.const_stack.pop().?;
            var ckit = cscope.keyIterator();
            while (ckit.next()) |k| self.allocator.free(k.*);
            cscope.deinit(self.allocator);

            var tscope = self.temp_label_stack.pop().?;
            var had_unresolved = false;
            var tit = tscope.iterator();
            while (tit.next()) |entry| {
                if (!entry.value_ptr.defined) {
                    std.debug.print("error: '@{s}' was referenced but never declared in @repeat body (iteration {})\n",
                        .{ entry.key_ptr.*, i });
                    had_unresolved = true;
                }
                self.allocator.free(entry.key_ptr.*);
            }
            tscope.deinit(self.allocator);
            if (had_unresolved) return ParseError.LabelNotFound;

            var sscope = self.struct_scope_stack.pop().?;
            for (sscope.items) |name| {
                self.sym.removeStruct(name);
                self.allocator.free(name);
            }
            sscope.deinit(self.allocator);

            var escope = self.enum_scope_stack.pop().?;
            for (escope.items) |name| {
                self.sym.removeEnum(name);
                self.allocator.free(name);
            }
            escope.deinit(self.allocator);
        }

        // Advance past the closing '}'
        self.pos = body_end + 1;
        self.consumeEOL();
    }

    fn parseAtBind(self: *@This()) ParseError!void {
        // Caller has already consumed '@' and 'bind'.
        if (self.alias_stack.items.len == 0) {
            const t = self.peek();
            std.debug.print("{s}:{}:{}: error: @bind used outside of a '@{{' scope\n",
                .{ t.source_file, t.line, t.col });
            self.printSourceContext(t);
            self.skipToEOL();
            return ParseError.UnexpectedToken;
        }
        const name_tok = try self.expectIdent();
        _ = try self.expect(.Colon);
        const reg = try self.parseReg(name_tok.line);
        _ = self.tryConsume(.Semicolon);

        if (RegID.fromStr(name_tok.text) != null) {
            std.debug.print("{s}:{}:{}: warning: @bind '{s}' shadows a register name\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
            self.printSourceContext(name_tok);
        }

        const top = &self.alias_stack.items[self.alias_stack.items.len - 1];
        // Use getOrPut so we reuse the existing key on re-bind, freeing our dupe if found.
        const key = self.allocator.dupe(u8, name_tok.text) catch return ParseError.OutOfMemory;
        const gop = top.getOrPut(self.allocator, key) catch {
            self.allocator.free(key);
            return ParseError.OutOfMemory;
        };
        if (gop.found_existing) {
            // Key already owned by the map — free the new dupe we just made.
            self.allocator.free(key);
        }
        gop.value_ptr.* = reg;
    }

    fn lookupAlias(self: *const @This(), name: []const u8) ?RegID {
        var i = self.alias_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.alias_stack.items[i].get(name)) |reg| return reg;
        }
        return null;
    }

    fn lookupScopedConst(self: *const @This(), name: []const u8) ?i64 {
        var i = self.const_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.const_stack.items[i].get(name)) |val| return val;
        }
        return null;
    }

    /// Walk temp_label_stack top-to-bottom for `name`.  If found, return its
    /// internal name (resolved or reserved for a forward ref).  If not found
    /// and we are inside at least one scope, reserve the name in the current
    /// scope (enabling forward references) and return the freshly-generated
    /// internal name.  If not found and not inside any scope, return null so
    /// the caller can produce a targeted error.
    fn lookupOrReserveTempLabel(self: *@This(), name_tok: Token) ParseError!?[]const u8 {
        const name = name_tok.text;
        var i = self.temp_label_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.temp_label_stack.items[i].get(name)) |entry| return entry.internal_name;
        }
        if (self.temp_label_stack.items.len == 0) return null;
        // Reserve in current scope for a forward reference.
        const internal_name = std.fmt.allocPrint(
            self.allocator, "__tmp_{d}_{s}", .{ self.temp_label_counter, name },
        ) catch return ParseError.OutOfMemory;
        self.temp_label_counter += 1;
        self.temp_label_strings.append(self.allocator, internal_name) catch {
            self.allocator.free(internal_name);
            return ParseError.OutOfMemory;
        };
        const key = self.allocator.dupe(u8, name) catch return ParseError.OutOfMemory;
        const top = &self.temp_label_stack.items[self.temp_label_stack.items.len - 1];
        top.put(self.allocator, key, .{ .internal_name = internal_name, .defined = false }) catch {
            self.allocator.free(key);
            return ParseError.OutOfMemory;
        };
        return internal_name;
    }

    /// Error if `name` already exists in a parent temp-label scope or as a
    /// global symbol (shadowing is forbidden).  `check_up_to` is the number
    /// of parent scopes to check (i.e. all scopes with index < check_up_to).
    fn checkTempLabelShadowing(self: *@This(), name_tok: Token, check_up_to: usize) ParseError!void {
        const name = name_tok.text;
        var i: usize = 0;
        while (i < check_up_to) : (i += 1) {
            if (self.temp_label_stack.items[i].contains(name)) {
                std.debug.print("{s}:{}:{}: error: '@{s}' shadows a temp label in an outer '@{{...}}' scope\n",
                    .{ name_tok.source_file, name_tok.line, name_tok.col, name });
                self.printSourceContext(name_tok);
                return ParseError.DuplicateSymbol;
            }
        }
        if (self.sym.getSymbol(name) != null) {
            std.debug.print("{s}:{}:{}: error: '@{s}' shadows existing symbol '{s}'\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name, name });
            self.printSourceContext(name_tok);
            return ParseError.DuplicateSymbol;
        }
    }

    /// Declare a temp label from `@name:` syntax.
    /// If the name was already reserved by a forward reference in this scope,
    /// reuse the internal name; otherwise generate a fresh one.
    fn defineTempLabel(self: *@This(), name_tok: Token) ParseError!void {
        const name = name_tok.text;
        if (self.temp_label_stack.items.len == 0) {
            std.debug.print("{s}:{}:{}: error: temp label '@{s}' declared outside of any '@{{...}}' scope\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name });
            self.printSourceContext(name_tok);
            return ParseError.UnexpectedToken;
        }
        const top_idx = self.temp_label_stack.items.len - 1;
        const top = &self.temp_label_stack.items[top_idx];

        if (top.getPtr(name)) |entry| {
            if (entry.defined) {
                std.debug.print("{s}:{}:{}: error: '@{s}' already declared in this scope\n",
                    .{ name_tok.source_file, name_tok.line, name_tok.col, name });
                self.printSourceContext(name_tok);
                return ParseError.DuplicateSymbol;
            }
            // Forward-reserved — check parent scopes for shadowing, then confirm.
            try self.checkTempLabelShadowing(name_tok, top_idx);
            entry.defined = true;
            const instr_idx: u32 = @intCast(self.tbfWriter.instructions.items.len);
            self.sym.defineLabel(entry.internal_name, instr_idx) catch |e| return switch (e) {
                sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
                else => ParseError.OutOfMemory,
            };
            if (self.emit_debug)
                self.tbfWriter.addDebugSymbol(instr_idx, entry.internal_name)
                    catch return ParseError.OutOfMemory;
            return;
        }

        // First time seeing this name — shadow-check all parent scopes and globals.
        try self.checkTempLabelShadowing(name_tok, top_idx);

        const internal_name = std.fmt.allocPrint(
            self.allocator, "__tmp_{d}_{s}", .{ self.temp_label_counter, name },
        ) catch return ParseError.OutOfMemory;
        self.temp_label_counter += 1;
        self.temp_label_strings.append(self.allocator, internal_name) catch {
            self.allocator.free(internal_name);
            return ParseError.OutOfMemory;
        };
        const key = self.allocator.dupe(u8, name) catch return ParseError.OutOfMemory;
        top.put(self.allocator, key, .{ .internal_name = internal_name, .defined = true }) catch {
            self.allocator.free(key);
            return ParseError.OutOfMemory;
        };
        const instr_idx: u32 = @intCast(self.tbfWriter.instructions.items.len);
        self.sym.defineLabel(internal_name, instr_idx) catch |e| return switch (e) {
            sym_mod.SymbolError.DuplicateSymbol => ParseError.DuplicateSymbol,
            else => ParseError.OutOfMemory,
        };
        if (self.emit_debug)
            self.tbfWriter.addDebugSymbol(instr_idx, internal_name)
                catch return ParseError.OutOfMemory;
    }

    /// Parse `@const name : expr;` — caller has already consumed `@` and `const`.
    fn parseAtConst(self: *@This()) ParseError!void {
        if (self.const_stack.items.len == 0) {
            const t = self.peek();
            std.debug.print("{s}:{}:{}: error: @const used outside of a '@{{' scope\n",
                .{ t.source_file, t.line, t.col });
            self.printSourceContext(t);
            self.skipToEOL();
            return ParseError.UnexpectedToken;
        }
        const name_tok = try self.expectIdent();
        _ = try self.expect(.Colon);
        const val = try self.parseConstExpr();
        _ = self.tryConsume(.Semicolon);

        const top = &self.const_stack.items[self.const_stack.items.len - 1];
        const key = self.allocator.dupe(u8, name_tok.text) catch return ParseError.OutOfMemory;
        const gop = top.getOrPut(self.allocator, key) catch {
            self.allocator.free(key);
            return ParseError.OutOfMemory;
        };
        if (gop.found_existing) self.allocator.free(key);
        gop.value_ptr.* = val;
    }

    fn isLabelDecl(self: *const @This()) bool {
        var i = self.pos + 1;
        while (i < self.tokens.len and self.tokens[i].kind == .Newline) i += 1;
        return i < self.tokens.len and self.tokens[i].kind == .Colon;
    }

    // True if token is 'jr' literally OR an alias that resolves to JR/JRH — used by branch encoding.
    fn isJrToken(self: *const @This(), t: Token) bool {
        if (t.kind != .Identifier) return false;
        if (std.mem.eql(u8, t.text, "jr")) return true;
        if (self.lookupAlias(t.text)) |r| return r == .JR or r == .JRH;
        return false;
    }

    // Detect `Name@{` — identifier immediately followed by '@' then '{' (same line, no newlines).
    fn isNamedScopeOpen(self: *const @This()) bool {
        const i = self.pos + 1;
        if (i + 1 >= self.tokens.len) return false;
        return self.tokens[i].kind == .At and self.tokens[i + 1].kind == .LBrace;
    }

    // ── Instruction dispatch ───────────────────────────────────────────────

    fn parseInstruction(self: *@This()) ParseError!void {
        const mt = self.advance();
        if (mt.kind == .Eof) return;
        if (mt.kind != .Identifier) {
            std.debug.print("{s}:{}:{}: error: expected mnemonic, got '{s}'\n", .{ mt.source_file, mt.line, mt.col, mt.text });
            self.printSourceContext(mt);
            self.skipToEOL();
            return ParseError.UnexpectedToken;
        }
        // Smart-dispatch mnemonics that share a single keyword
        if (std.mem.eql(u8, mt.text, "mov")) {
            try self.parseMov(mt.line);
            self.consumeEOL();
            return;
        }
        if (std.mem.eql(u8, mt.text, "bump")) {
            try self.parseBump(mt.line);
            self.consumeEOL();
            return;
        }
        if (std.mem.eql(u8, mt.text, "push")) {
            try self.parsePush(mt.line);
            self.consumeEOL();
            return;
        }
        if (std.mem.eql(u8, mt.text, "pop")) {
            try self.parsePop(mt.line);
            self.consumeEOL();
            return;
        }
        if (std.mem.eql(u8, mt.text, "resume")) {
            try self.parseResume(mt.line);
            self.consumeEOL();
            return;
        }
        if (std.mem.eql(u8, mt.text, "movi")) {
            try self.parseMovIncrDecr(mt.line, true);
            self.consumeEOL();
            return;
        }
        if (std.mem.eql(u8, mt.text, "movd")) {
            try self.parseMovIncrDecr(mt.line, false);
            self.consumeEOL();
            return;
        }

        const info = encoder.findOpcode(mt.text) orelse {
            std.debug.print("{s}:{}:{}: error: unknown mnemonic '{s}'\n", .{ mt.source_file, mt.line, mt.col, mt.text });
            self.printSourceContext(mt);
            self.skipToEOL();
            return ParseError.UnexpectedToken;
        };
        const instr_idx: u32 = @intCast(self.tbfWriter.instructions.items.len);
        try self.encodeInstruction(info, instr_idx, mt.line, mt.col, mt.source_file);
        self.consumeEOL();
    }

    fn encodeInstruction(self: *@This(), info: OpcodeInfo, instr_idx: u32, line: u32, col: u32, source_file: []const u8) ParseError!void {
        switch (info.format) {
            .Bare => try self.emitWord(@as(u32, info.opcode)),

            .Dst => {
                const dst = try self.parseReg(line);
                _ = self.tryConsume(.Comma);
                var payload: u32 = 0;
                if (self.peekIsImm()) payload = @truncate(@as(u64, @bitCast(try self.parseImm(line))));
                try self.emitWord(pDst(info.opcode, dst, payload & 0x7FFFF));
            },

            .DstSrc => {
                const dst = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const src = try self.parseReg(line);
                try self.emitWord(pDstSrc(info.opcode, dst, src, 0));
            },

            .DstAddrSrc => {
                const mem = try self.parseMemSimple(line); _ = self.tryConsume(.Comma);
                const src = try self.parseReg(line);
                try self.emitWord(pDstAddrSrc(info.opcode, mem.base, src, mem.offset));
            },

            .DstAddrXSrc => {
                const mem = try self.parseMemExt(line); _ = self.tryConsume(.Comma);
                const src = try self.parseReg(line);
                try self.emitWord(pDstAddrXSrc(info.opcode, mem.page_reg, mem.off_reg, src, mem.offset));
            },

            .DstSrcAddr => {
                const dst = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const mem = try self.parseMemSimple(line);
                try self.emitWord(pDstSrcAddr(info.opcode, dst, mem.base, mem.offset));
            },

            .DstSrcAddrX => {
                const dst = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const mem = try self.parseMemExt(line);
                try self.emitWord(pDstSrcAddrX(info.opcode, dst, mem.page_reg, mem.off_reg, mem.offset));
            },

            .Dst2Src2 => {
                const r0 = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const r1 = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const r2 = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const r3 = try self.parseReg(line);
                try self.emitWord(pDst2Src2(info.opcode, r0, r1, r2, r3));
            },

            .Dst2Src2Len => {
                const r0 = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const r1 = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const r2 = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const r3 = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const len = try self.parseReg(line);
                if (@intFromEnum(len) > 15) {
                    std.debug.print("{s}:{}: error: mcpy/mmov length register must be R0-RF\n",
                        .{ source_file, line });
                    self.printSourceContextAt(source_file, line, 0, 0);
                    return ParseError.InvalidOperand;
                }
                try self.emitWord(pDst2Src2Len(info.opcode, r0, r1, r2, r3, len));
            },

            .DstSrc2 => {
                const dst = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const s0  = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const s1  = try self.parseReg(line);
                try self.emitWord(pDstSrc2(info.opcode, dst, s0, s1));
            },

            .DstSrc3 => {
                const dst = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const s0  = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const s1  = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const s2  = try self.parseReg(line);
                try self.emitWord(pDstSrc3(info.opcode, dst, s0, s1, s2));
            },

            .DstConst2 => {
                const dst = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const c0: u32 = @truncate(@as(u64, @bitCast(try self.parseImm(line)))); _ = self.tryConsume(.Comma);
                const c1: u32 = @truncate(@as(u64, @bitCast(try self.parseImm(line))));
                try self.emitWord(pDst(info.opcode, dst, (c0 & 0xFF) | ((c1 & 0xFF) << 8)));
            },

            .LeaWide => {
                const hi = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const lo = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const addr = try self.parseAddr32(line);
                try self.emitWord(pDstSrc(info.opcode, hi, lo, 0));
                try self.emitWord(addr);
            },

            .BranchReg => {
                const is_jr = self.isJrToken(self.peek());
                if (is_jr) _ = self.advance();
                const hi: RegID = if (is_jr) RegID.JRH else blk: { const r = try self.parseReg(line); _ = self.tryConsume(.Comma); break :blk r; };
                const lo: RegID = if (is_jr) RegID.JR else try self.parseReg(line);
                try self.emitWord(pDstSrc(info.opcode, hi, lo, 0));
            },

            .BranchRegCond => {
                const is_jr = self.isJrToken(self.peek());
                if (is_jr) _ = self.advance();
                const hi: RegID = if (is_jr) RegID.JRH else blk: { const r = try self.parseReg(line); _ = self.tryConsume(.Comma); break :blk r; };
                const lo: RegID = if (is_jr) RegID.JR else try self.parseReg(line);
                _ = self.tryConsume(.Comma);
                const cond = try self.parseReg(line);
                try self.emitWord(pDstSrc2(info.opcode, hi, lo, cond));
            },

            .BranchNear => {
                const loi = try self.parseLabelOrImm(line);
                switch (loi) {
                    .resolved   => |off|  try self.emitWord(pBrNear(info.opcode, off)),
                    .unresolved => |name| {
                        try self.emitWord(@as(u32, info.opcode));
                        self.forward_refs.append(self.allocator, .{
                            .instr_idx = instr_idx, .from_idx = instr_idx,
                            .label = name, .kind = .Near, .cond_reg = .R0, .line = line, .col = col, .source_file = source_file,
                        }) catch return ParseError.OutOfMemory;
                    },
                }
            },

            .BranchNearCond => {
                const cond = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const loi  = try self.parseLabelOrImm(line);
                switch (loi) {
                    .resolved   => |off|  try self.emitWord(pBrNearCond(info.opcode, cond, off)),
                    .unresolved => |name| {
                        try self.emitWord(pDst(info.opcode, cond, 0));
                        self.forward_refs.append(self.allocator, .{
                            .instr_idx = instr_idx, .from_idx = instr_idx,
                            .label = name, .kind = .NearCond, .cond_reg = cond, .line = line, .col = col, .source_file = source_file,
                        }) catch return ParseError.OutOfMemory;
                    },
                }
            },

            .Syscall => {
                const pool:  u32 = @truncate(@as(u64, @bitCast(try self.parseImm(line)))); _ = self.tryConsume(.Comma);
                const event: u32 = @truncate(@as(u64, @bitCast(try self.parseImm(line))));
                try self.emitWord(@as(u32, info.opcode) | ((pool & 0x1FF) << 8) | ((event & 0x7FFF) << 17));
            },

            .ResumeReg => {
                // resume_at [hi, lo]  — address built from register pair
                _ = try self.expect(.LBracket);
                const hi = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const lo = try self.parseReg(line);
                _ = try self.expect(.RBracket);
                try self.emitWord(pDstSrc(info.opcode, hi, lo, 0));
            },

            .VReduce => {
                const dst = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const src = try self.parseReg(line); _ = self.tryConsume(.Comma);
                const rc_tok = try self.expectIdent();
                const rc = encoder.findReduceCode(rc_tok.text) orelse {
                    std.debug.print("{s}:{}:{}: error: unknown reduce code '{s}'\n", .{ rc_tok.source_file, rc_tok.line, rc_tok.col, rc_tok.text });
                    self.printSourceContext(rc_tok);
                    return ParseError.InvalidOperand;
                };
                try self.emitWord(pDstSrc(info.opcode, dst, src, @as(u32, rc)));
            },
        }
    }

    // ── Operand parsers ────────────────────────────────────────────────────

    fn parseReg(self: *@This(), line: u32) ParseError!RegID {
        _ = line;
        const t = self.advance();
        if (t.kind != .Identifier) {
            std.debug.print("{s}:{}:{}: error: expected register, got '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
            self.printSourceContext(t);
            return ParseError.InvalidOperand;
        }
        return RegID.fromStr(t.text) orelse self.lookupAlias(t.text) orelse {
            std.debug.print("{s}:{}:{}: error: '{s}' is not a register or alias\n", .{ t.source_file, t.line, t.col, t.text });
            self.printSourceContext(t);
            return ParseError.InvalidOperand;
        };
    }

    fn parseImm(self: *@This(), line: u32) ParseError!i64 {
        _ = line;
        const negate = self.tryConsume(.Minus);
        const t = self.advance();
        if (t.kind == .Dollar) {
            const name_tok = try self.expectIdent();
            const v = try self.parseBuiltinConst(name_tok);
            return if (negate) -v else v;
        }
        if (t.kind == .At) {
            const name_tok = try self.expectIdent();
            if (self.lookupScopedConst(name_tok.text)) |val| {
                return if (negate) -val else val;
            }
            std.debug.print("{s}:{}:{}: error: '@{s}' is not a scoped constant\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
            self.printSourceContext(name_tok);
            return ParseError.UndefinedSymbol;
        }
        if (t.kind == .Identifier) {
            // EnumName.field — resolve at parse time
            var full: std.ArrayList(u8) = .empty;
            defer full.deinit(self.allocator);
            full.appendSlice(self.allocator, t.text) catch return ParseError.OutOfMemory;
            while (self.peekRaw().kind == .Dot) {
                _ = self.advanceRaw();
                const f = self.advanceRaw();
                if (f.kind != .Identifier) {
                    std.debug.print("{s}:{}:{}: error: expected field name after '.'\n",
                        .{ f.source_file, f.line, f.col });
                    self.printSourceContext(f);
                    return ParseError.InvalidOperand;
                }
                full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                full.appendSlice(self.allocator, f.text) catch return ParseError.OutOfMemory;
            }
            if (self.sym.resolveEnumField(full.items)) |ev| {
                return if (negate) -ev else ev;
            }
            std.debug.print("{s}:{}:{}: error: '{s}' is not an enum field\n",
                .{ t.source_file, t.line, t.col, full.items });
            self.printSourceContext(t);
            return ParseError.UndefinedSymbol;
        }
        if (t.kind != .Integer) {
            std.debug.print("{s}:{}:{}: error: expected integer, got '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
            self.printSourceContext(t);
            return ParseError.InvalidOperand;
        }
        var v: i64 = @bitCast(t.int_value);
        if (negate) v = -v;
        return v;
    }

    fn peekIsImm(self: *const @This()) bool {
        const k = self.peek().kind;
        if (k == .Integer or k == .Minus or k == .Dollar or k == .At) return true;
        // EnumName.field — identifier followed by a dot
        if (k == .Identifier) {
            var i = self.pos;
            while (i < self.tokens.len and self.tokens[i].kind == .Newline) i += 1;
            if (i >= self.tokens.len) return false;
            i += 1; // skip the identifier token
            while (i < self.tokens.len and self.tokens[i].kind == .Newline) i += 1;
            return i < self.tokens.len and self.tokens[i].kind == .Dot;
        }
        return false;
    }

    /// Consume `(qual)` — e.g. `(byte)` or `(dword)` — if present. Returns true if consumed.
    fn tryConsumeSizeQual(self: *@This(), qual: []const u8) bool {
        if (self.peek().kind != .LParen) return false;
        const saved = self.pos;
        _ = self.advance(); // '('
        const id = self.advance();
        if (id.kind != .Identifier or !std.mem.eql(u8, id.text, qual)) { self.pos = saved; return false; }
        const rp = self.advance();
        if (rp.kind != .RParen) { self.pos = saved; return false; }
        return true;
    }

    /// Returns true if the next non-newline token is `[` and there is a `,` inside the brackets.
    fn peekMemIsExt(self: *const @This()) bool {
        var i = self.pos;
        while (i < self.tokens.len and self.tokens[i].kind == .Newline) i += 1;
        if (i >= self.tokens.len or self.tokens[i].kind != .LBracket) return false;
        i += 1;
        while (i < self.tokens.len) {
            switch (self.tokens[i].kind) {
                .RBracket, .Eof => return false,
                .Comma => return true,
                else => i += 1,
            }
        }
        return false;
    }

    const SizeQual = enum { none, byte, dword };
    fn parseSizeQual(self: *@This()) SizeQual {
        if (self.tryConsumeSizeQual("byte"))  return .byte;
        if (self.tryConsumeSizeQual("dword")) return .dword;
        return .none;
    }

    // ── Smart mov dispatch ─────────────────────────────────────────────────

    fn parseMov(self: *@This(), line: u32) ParseError!void {
        const byte_left = self.tryConsumeSizeQual("byte");

        if (self.peek().kind == .LBracket) {
            // Write to memory: mov [addr], src
            if (self.peekMemIsExt()) {
                const mem = try self.parseMemExt(line);
                _ = self.tryConsume(.Comma);
                const byte_right = self.tryConsumeSizeQual("byte");
                const src = try self.parseReg(line);
                const opcode: u8 = if (byte_left or byte_right) 0x09 else 0x05;
                try self.emitWord(pDstAddrXSrc(opcode, mem.page_reg, mem.off_reg, src, mem.offset));
            } else {
                const mem = try self.parseMemSimple(line);
                _ = self.tryConsume(.Comma);
                const byte_right = self.tryConsumeSizeQual("byte");
                const src = try self.parseReg(line);
                const opcode: u8 = if (byte_left or byte_right) 0x07 else 0x03;
                try self.emitWord(pDstAddrSrc(opcode, mem.base, src, mem.offset));
            }
        } else {
            // Destination is a register
            const dst = try self.parseReg(line);
            _ = self.tryConsume(.Comma);
            const byte_right = self.tryConsumeSizeQual("byte");

            if (self.peek().kind == .LBracket) {
                // Read from memory: mov r_dst, [addr]
                if (self.peekMemIsExt()) {
                    const mem = try self.parseMemExt(line);
                    const opcode: u8 = if (byte_left or byte_right) 0x0A else 0x06;
                    try self.emitWord(pDstSrcAddrX(opcode, dst, mem.page_reg, mem.off_reg, mem.offset));
                } else {
                    const mem = try self.parseMemSimple(line);
                    const opcode: u8 = if (byte_left or byte_right) 0x08 else 0x04;
                    try self.emitWord(pDstSrcAddr(opcode, dst, mem.base, mem.offset));
                }
            } else if (self.peekIsImm()) {
                // Immediate: mov r_dst, imm
                const imm = try self.parseImm(line);
                const payload: u32 = @truncate(@as(u64, @bitCast(imm)));
                try self.emitWord(pDst(0x02, dst, payload & 0x7FFFF));
            } else {
                // Check for page-0 data label: mov r_dst, label  →  mov_c offset
                const t = self.peek();
                if (t.kind == .Identifier and
                    RegID.fromStr(t.text) == null and
                    self.lookupAlias(t.text) == null)
                {
                    if (self.sym.getSymbol(t.text)) |sym| {
                        switch (sym.*) {
                            .Data => |d| if (d.page == 0) {
                                _ = self.advance();
                                try self.emitWord(pDst(0x02, dst, d.offset));
                                return;
                            },
                            else => {},
                        }
                    }
                }
                // Register to register: mov r_dst, r_src  /  mov r_dst, (byte)r_src
                const src = try self.parseReg(line);
                const opcode: u8 = if (byte_right) 0x84 else 0x01;
                try self.emitWord(pDstSrc(opcode, dst, src, 0));
            }
        }
    }

    // ── Smart movi/movd dispatch ───────────────────────────────────────────

    fn parseMovIncrDecr(self: *@This(), line: u32, increment: bool) ParseError!void {
        const byte_left = self.tryConsumeSizeQual("byte");

        if (self.peek().kind == .LBracket) {
            // Write: movi/movd [page, off], src
            if (!self.peekMemIsExt()) {
                const t = self.peek();
                std.debug.print("{s}:{}:{}: error: movi/movd requires extended [page, offset] addressing\n",
                    .{ t.source_file, t.line, t.col });
                self.printSourceContext(t);
                return ParseError.InvalidMemoryOperand;
            }
            const mem = try self.parseMemExt(line);
            _ = self.tryConsume(.Comma);
            const byte_right = self.tryConsumeSizeQual("byte");
            const src = try self.parseReg(line);
            const opcode: u8 = if (increment)
                if (byte_left or byte_right) 0x36 else 0x34
            else
                if (byte_left or byte_right) 0x3A else 0x38;
            try self.emitWord(pDstAddrXSrc(opcode, mem.page_reg, mem.off_reg, src, mem.offset));
        } else {
            // Read: movi/movd dst, [page, off]
            const dst = try self.parseReg(line);
            _ = self.tryConsume(.Comma);
            const byte_right = self.tryConsumeSizeQual("byte");

            if (self.peek().kind != .LBracket) {
                const t = self.peek();
                std.debug.print("{s}:{}:{}: error: movi/movd: expected '[page, offset]' memory operand\n",
                    .{ t.source_file, t.line, t.col });
                self.printSourceContext(t);
                return ParseError.InvalidMemoryOperand;
            }
            if (!self.peekMemIsExt()) {
                const t = self.peek();
                std.debug.print("{s}:{}:{}: error: movi/movd requires extended [page, offset] addressing\n",
                    .{ t.source_file, t.line, t.col });
                self.printSourceContext(t);
                return ParseError.InvalidMemoryOperand;
            }
            const mem = try self.parseMemExt(line);
            const opcode: u8 = if (increment)
                if (byte_left or byte_right) 0x37 else 0x35
            else
                if (byte_left or byte_right) 0x3B else 0x39;
            try self.emitWord(pDstSrcAddrX(opcode, dst, mem.page_reg, mem.off_reg, mem.offset));
        }
    }

    // ── Smart bump dispatch ────────────────────────────────────────────────

    fn parseBump(self: *@This(), line: u32) ParseError!void {
        const next = self.peek();
        const is_reg = next.kind == .Identifier and
            (RegID.fromStr(next.text) != null or self.lookupAlias(next.text) != null);
        if (is_reg) {
            // bump reg  ->  bump_r (0x32): reg holds allocation amount, sp is implicit
            const src = try self.parseReg(line);
            try self.emitWord(pDst(0x32, src, 0));
        } else {
            // bump imm  ->  bump_c (0x33): i16 constant in payload, sp is implicit
            const imm = try self.parseImm(line);
            const payload: u32 = @truncate(@as(u64, @bitCast(imm)));
            try self.emitWord(pDst(0x33, .R0, payload & 0x7FFFF));
        }
    }

    // ── Smart push/pop dispatch ────────────────────────────────────────────

    fn parsePush(self: *@This(), line: u32) ParseError!void {
        const sq = self.parseSizeQual();
        switch (sq) {
            .byte => {
                const reg = try self.parseReg(line);
                try self.emitWord(pDst(0x2E, reg, 0)); // push8
            },
            .dword => {
                // (dword) qualifier forces push32: accept `jr` or `lo, hi`
                const lo, const hi = try self.parsePair32(line);
                try self.emitWord(pDstSrc(0x81, lo, hi, 0));
            },
            .none => {
                if (self.isJrToken(self.peek())) {
                    // push jr → push32 JR:JRH pair
                    _ = self.advance();
                    try self.emitWord(pDstSrc(0x81, .JR, .JRH, 0));
                } else {
                    const r1 = try self.parseReg(line);
                    if (self.tryConsume(.Comma)) {
                        // push IXR, IXR → push32 explicit pair
                        const r2 = try self.parseReg(line);
                        try self.emitWord(pDstSrc(0x81, r1, r2, 0));
                    } else {
                        // push IXR → push16
                        try self.emitWord(pDst(0x2F, r1, 0));
                    }
                }
            },
        }
    }

    fn parsePop(self: *@This(), line: u32) ParseError!void {
        const sq = self.parseSizeQual();
        switch (sq) {
            .byte => {
                const reg = try self.parseReg(line);
                try self.emitWord(pDst(0x30, reg, 0)); // pop8
            },
            .dword => {
                // (dword) qualifier forces pop32: accept `jr` or `lo, hi`
                const lo, const hi = try self.parsePair32(line);
                try self.emitWord(pDstSrc(0x82, lo, hi, 0));
            },
            .none => {
                if (self.isJrToken(self.peek())) {
                    // pop jr → pop32 JR:JRH pair
                    _ = self.advance();
                    try self.emitWord(pDstSrc(0x82, .JR, .JRH, 0));
                } else {
                    const r1 = try self.parseReg(line);
                    if (self.tryConsume(.Comma)) {
                        // pop IXR, IXR → pop32 explicit pair
                        const r2 = try self.parseReg(line);
                        try self.emitWord(pDstSrc(0x82, r1, r2, 0));
                    } else {
                        // pop IXR → pop16
                        try self.emitWord(pDst(0x31, r1, 0));
                    }
                }
            },
        }
    }

    // Parse a 32-bit register pair: `jr` (expands to JR/JRH) or `lo_reg, hi_reg`.
    fn parsePair32(self: *@This(), line: u32) ParseError!struct { RegID, RegID } {
        if (self.isJrToken(self.peek())) {
            _ = self.advance();
            return .{ .JR, .JRH };
        }
        const lo = try self.parseReg(line); _ = self.tryConsume(.Comma);
        const hi = try self.parseReg(line);
        return .{ lo, hi };
    }

    // ── Smart resume dispatch ──────────────────────────────────────────────
    // `resume`         → resume_skip (0x42)  bare, no operands
    // `resume [hi, lo]` → resume_at  (0x43)  address from register pair

    fn parseResume(self: *@This(), line: u32) ParseError!void {
        const t = self.peek();
        if (t.kind == .LBracket) {
            _ = self.advance(); // '['
            const hi = try self.parseReg(line); _ = self.tryConsume(.Comma);
            const lo = try self.parseReg(line);
            _ = try self.expect(.RBracket);
            try self.emitWord(pDstSrc(0x43, hi, lo, 0)); // resume_at
        } else {
            try self.emitWord(@as(u32, 0x42)); // resume_skip
        }
    }

    fn parseAddr32(self: *@This(), line: u32) ParseError!u32 {
        _ = line;
        const t = self.peek();
        if (t.kind == .Integer) { _ = self.advance(); return @truncate(t.int_value); }
        if (t.kind == .Dollar) {
            _ = self.advance();
            const name_tok = try self.expectIdent();
            const v = try self.parseBuiltinConst(name_tok);
            return @truncate(@as(u64, @bitCast(v)));
        }
        if (t.kind == .Identifier) {
            _ = self.advance();
            var full: std.ArrayList(u8) = .empty;
            defer full.deinit(self.allocator);
            full.appendSlice(self.allocator, t.text) catch return ParseError.OutOfMemory;
            while (self.peekRaw().kind == .Dot) {
                _ = self.advanceRaw();
                const f = try self.expectIdent();
                full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                full.appendSlice(self.allocator, f.text) catch return ParseError.OutOfMemory;
            }
            return self.sym.resolveAddress(full.items) catch {
                std.debug.print("{s}:{}:{}: error: undefined symbol '{s}'\n", .{ t.source_file, t.line, t.col, full.items });
                self.printSourceContext(t);
                return ParseError.UndefinedSymbol;
            };
        }
        std.debug.print("{s}:{}:{}: error: expected address, got '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
        self.printSourceContext(t);
        return ParseError.InvalidOperand;
    }

    const LabelOrImm = union(enum) {
        resolved:   i14,
        unresolved: []u8, // heap-allocated; ownership transferred to ForwardRef
    };

    fn parseLabelOrImm(self: *@This(), line: u32) ParseError!LabelOrImm {
        const t = self.peek();
        if (t.kind == .Integer or t.kind == .Minus) {
            const v = try self.parseImm(line);
            if (v < -8192 or v > 8191) {
                std.debug.print("{s}:{}:{}: error: branch offset {} out of i14 range [-8192, 8191]\n", .{ t.source_file, t.line, t.col, v });
                self.printSourceContext(t);
                return ParseError.BranchTooFar;
            }
            return LabelOrImm{ .resolved = @intCast(v) };
        }
        if (t.kind == .At) {
            _ = self.advance(); // consume '@'
            const name_tok = try self.expectIdent();
            // Temp label (forward or backward reference within scope).
            if (try self.lookupOrReserveTempLabel(name_tok)) |internal_name| {
                const owned = self.allocator.dupe(u8, internal_name) catch return ParseError.OutOfMemory;
                return LabelOrImm{ .unresolved = owned };
            }
            // Scoped constant used as a compile-time branch offset.
            if (self.lookupScopedConst(name_tok.text)) |val| {
                if (val < -8192 or val > 8191) {
                    std.debug.print("{s}:{}:{}: error: '@{s}' value {} out of i14 range [-8192, 8191]\n",
                        .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text, val });
                    self.printSourceContext(name_tok);
                    return ParseError.BranchTooFar;
                }
                return LabelOrImm{ .resolved = @intCast(val) };
            }
            std.debug.print("{s}:{}:{}: error: '@{s}' is not defined in any current scope\n",
                .{ name_tok.source_file, name_tok.line, name_tok.col, name_tok.text });
            self.printSourceContext(name_tok);
            return ParseError.LabelNotFound;
        }
        if (t.kind == .Identifier) {
            _ = self.advance();
            var full: std.ArrayList(u8) = .empty;
            defer full.deinit(self.allocator);
            full.appendSlice(self.allocator, t.text) catch return ParseError.OutOfMemory;
            while (self.peekRaw().kind == .Dot) {
                _ = self.advanceRaw();
                const f = try self.expectIdent();
                full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                full.appendSlice(self.allocator, f.text) catch return ParseError.OutOfMemory;
            }
            if (self.sym.getSymbol(full.items)) |sym| {
                switch (sym.*) {
                    .Data => {
                        std.debug.print("{s}:{}:{}: error: '{s}' is a data symbol, not a branch label\n", .{ t.source_file, t.line, t.col, full.items });
                        self.printSourceContext(t);
                        return ParseError.TypeMismatch;
                    },
                    .Label => {},
                }
            }
            const owned = self.allocator.dupe(u8, full.items) catch return ParseError.OutOfMemory;
            return LabelOrImm{ .unresolved = owned };
        }
        std.debug.print("{s}:{}:{}: error: expected label or offset, got '{s}'\n", .{ t.source_file, t.line, t.col, t.text });
        self.printSourceContext(t);
        return ParseError.InvalidOperand;
    }

    const MemSimple = struct { base: RegID, offset: i9 };
    const MemExt    = struct { page_reg: RegID, off_reg: RegID, offset: i9 };

    fn parseMemSimple(self: *@This(), line: u32) ParseError!MemSimple {
        _ = try self.expect(.LBracket);
        const first = self.advance();

        // [(Symbol.field[N]) reg] or [(Symbol.field) reg] — struct field offset in parens
        if (first.kind == .LParen) {
            const sym_tok = self.advanceRaw();
            var full: std.ArrayList(u8) = .empty;
            defer full.deinit(self.allocator);
            full.appendSlice(self.allocator, sym_tok.text) catch return ParseError.OutOfMemory;
            while (self.peekRaw().kind == .Dot) {
                _ = self.advanceRaw();
                const f = try self.expectIdent();
                full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                full.appendSlice(self.allocator, f.text) catch return ParseError.OutOfMemory;
            }
            var index_offset: i32 = 0;
            if (self.peekRaw().kind == .LBracket) {
                _ = self.advanceRaw();
                const idx_tok = try self.expect(.Integer);
                _ = try self.expect(.RBracket);
                const elem_size = self.sym.resolveFieldElemSize(full.items) catch |e| {
                    std.debug.print("{s}:{}:{}: error: array index on non-array field '{s}'\n",
                        .{ sym_tok.source_file, sym_tok.line, sym_tok.col, full.items });
                    self.printSourceContext(sym_tok);
                    return switch (e) {
                        sym_mod.SymbolError.FieldNotFound   => ParseError.FieldNotFound,
                        sym_mod.SymbolError.UndefinedSymbol => ParseError.UndefinedSymbol,
                        else                                => ParseError.InvalidOperand,
                    };
                };
                index_offset = @as(i32, @intCast(idx_tok.int_value)) * @as(i32, @intCast(elem_size));
            }
            _ = try self.expect(.RParen);
            const field_off = self.sym.resolveFieldOffset(full.items) catch {
                std.debug.print("{s}:{}:{}: error: undefined symbol '{s}'\n", .{ sym_tok.source_file, sym_tok.line, sym_tok.col, full.items });
                self.printSourceContext(sym_tok);
                return ParseError.UndefinedSymbol;
            };
            const sym_off: i32 = @intCast(field_off);
            const reg_tok = self.advance();
            const base = RegID.fromStr(reg_tok.text) orelse {
                std.debug.print("{s}:{}:{}: error: expected register after symbol, got '{s}'\n", .{ reg_tok.source_file, reg_tok.line, reg_tok.col, reg_tok.text });
                self.printSourceContext(reg_tok);
                return ParseError.InvalidMemoryOperand;
            };
            var extra: i32 = 0;
            while (true) {
                if (self.peek().kind == .Plus) {
                    _ = self.advance();
                    extra += @as(i32, @intCast(try self.parseImm(line)));
                } else if (self.peek().kind == .Minus) {
                    _ = self.advance();
                    extra -= @as(i32, @intCast(try self.parseImm(line)));
                } else break;
            }
            _ = try self.expect(.RBracket);
            const total = sym_off + index_offset + extra;
            if (total < -256 or total > 255) return ParseError.OffsetOutOfRange;
            return MemSimple{ .base = base, .offset = @intCast(total) };
        }

        // [Symbol reg] — bare symbol (no parens, legacy/plain address)
        if (first.kind == .Identifier and RegID.fromStr(first.text) == null and self.lookupAlias(first.text) == null) {
            var full: std.ArrayList(u8) = .empty;
            defer full.deinit(self.allocator);
            full.appendSlice(self.allocator, first.text) catch return ParseError.OutOfMemory;
            while (self.peekRaw().kind == .Dot) {
                _ = self.advanceRaw();
                const f = try self.expectIdent();
                full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                full.appendSlice(self.allocator, f.text) catch return ParseError.OutOfMemory;
            }
            const addr = self.sym.resolveAddress(full.items) catch {
                std.debug.print("{s}:{}:{}: error: undefined symbol '{s}'\n", .{ first.source_file, first.line, first.col, full.items });
                self.printSourceContext(first);
                return ParseError.UndefinedSymbol;
            };
            const sym_off: i32 = @intCast(addr & 0xFFFF);
            const reg_tok = self.advance();
            const base = RegID.fromStr(reg_tok.text) orelse {
                std.debug.print("{s}:{}:{}: error: expected register after symbol, got '{s}'\n", .{ reg_tok.source_file, reg_tok.line, reg_tok.col, reg_tok.text });
                self.printSourceContext(reg_tok);
                return ParseError.InvalidMemoryOperand;
            };
            var extra: i32 = 0;
            while (true) {
                if (self.peek().kind == .Plus) {
                    _ = self.advance();
                    extra += @as(i32, @intCast(try self.parseImm(line)));
                } else if (self.peek().kind == .Minus) {
                    _ = self.advance();
                    extra -= @as(i32, @intCast(try self.parseImm(line)));
                } else break;
            }
            _ = try self.expect(.RBracket);
            const total = sym_off + extra;
            if (total < -256 or total > 255) return ParseError.OffsetOutOfRange;
            return MemSimple{ .base = base, .offset = @intCast(total) };
        }

        const base = RegID.fromStr(first.text) orelse self.lookupAlias(first.text) orelse {
            std.debug.print("{s}:{}:{}: error: expected register, got '{s}'\n", .{ first.source_file, first.line, first.col, first.text });
            self.printSourceContext(first);
            return ParseError.InvalidMemoryOperand;
        };
        var off: i32 = 0;
        while (true) {
            if (self.peek().kind == .Plus) {
                _ = self.advance();
                off += @as(i32, @intCast(try self.parseImm(line)));
            } else if (self.peek().kind == .Minus) {
                _ = self.advance();
                off -= @as(i32, @intCast(try self.parseImm(line)));
            } else break;
        }
        _ = try self.expect(.RBracket);
        if (off < -256 or off > 255) return ParseError.OffsetOutOfRange;
        return MemSimple{ .base = base, .offset = @intCast(off) };
    }

    fn parseMemExt(self: *@This(), line: u32) ParseError!MemExt {
        _ = try self.expect(.LBracket);
        const psr = try self.parseReg(line);
        _ = try self.expect(.Comma);

        // [psr, (Symbol.field[N]) por] — struct field offset (with optional array index) in parens
        var sym_off: i32 = 0;
        if (self.peekRaw().kind == .LParen) {
            _ = self.advanceRaw(); // consume '('
            const sym_tok = self.advanceRaw();
            var full: std.ArrayList(u8) = .empty;
            defer full.deinit(self.allocator);
            full.appendSlice(self.allocator, sym_tok.text) catch return ParseError.OutOfMemory;
            while (self.peekRaw().kind == .Dot) {
                _ = self.advanceRaw();
                const f = try self.expectIdent();
                full.append(self.allocator, '.') catch return ParseError.OutOfMemory;
                full.appendSlice(self.allocator, f.text) catch return ParseError.OutOfMemory;
            }
            var index_offset: i32 = 0;
            if (self.peekRaw().kind == .LBracket) {
                _ = self.advanceRaw();
                const idx_tok = try self.expect(.Integer);
                _ = try self.expect(.RBracket);
                const elem_size = self.sym.resolveFieldElemSize(full.items) catch |e| {
                    std.debug.print("{s}:{}:{}: error: array index on non-array field '{s}'\n",
                        .{ sym_tok.source_file, sym_tok.line, sym_tok.col, full.items });
                    self.printSourceContext(sym_tok);
                    return switch (e) {
                        sym_mod.SymbolError.FieldNotFound   => ParseError.FieldNotFound,
                        sym_mod.SymbolError.UndefinedSymbol => ParseError.UndefinedSymbol,
                        else                                => ParseError.InvalidOperand,
                    };
                };
                index_offset = @as(i32, @intCast(idx_tok.int_value)) * @as(i32, @intCast(elem_size));
            }
            _ = try self.expect(.RParen);
            const field_off = self.sym.resolveFieldOffset(full.items) catch {
                std.debug.print("{s}:{}:{}: error: undefined symbol '{s}'\n", .{ sym_tok.source_file, sym_tok.line, sym_tok.col, full.items });
                self.printSourceContext(sym_tok);
                return ParseError.UndefinedSymbol;
            };
            sym_off = @intCast(field_off);
            sym_off += index_offset;
        }

        const por = try self.parseReg(line);
        var off: i32 = sym_off;
        while (true) {
            if (self.peek().kind == .Plus) {
                _ = self.advance();
                off += @as(i32, @intCast(try self.parseImm(line)));
            } else if (self.peek().kind == .Minus) {
                _ = self.advance();
                off -= @as(i32, @intCast(try self.parseImm(line)));
            } else break;
        }
        _ = try self.expect(.RBracket);
        if (off < -256 or off > 255) return ParseError.OffsetOutOfRange;
        return MemExt{ .page_reg = psr, .off_reg = por, .offset = @intCast(off) };
    }

    fn emitWord(self: *@This(), word: u32) ParseError!void {
        self.tbfWriter.addInstruction(word) catch return ParseError.OutOfMemory;
    }

    // ══════════════════════════════════════════════════════════════════════
    // PASS 2 — patch forward references
    // ══════════════════════════════════════════════════════════════════════

    fn pass2FixupRefs(self: *@This()) ParseError!void {
        for (self.forward_refs.items) |*ref| {
            const target_idx = self.sym.resolveLabel(ref.label) catch {
                std.debug.print("{s}:{}:{}: error: undefined label '{s}'\n", .{ ref.source_file, ref.line, ref.col, ref.label });
                self.printSourceContextAt(ref.source_file, ref.line, ref.col, ref.label.len);
                return ParseError.LabelNotFound;
            };
            const offset = @as(i64, @intCast(target_idx)) - @as(i64, @intCast(ref.from_idx));
            if (offset < -8192 or offset > 8191) {
                std.debug.print("{s}:{}:{}: error: branch to '{s}' is too far ({} instructions, max ±8192)\n", .{ ref.source_file, ref.line, ref.col, ref.label, offset });
                self.printSourceContextAt(ref.source_file, ref.line, ref.col, ref.label.len);
                return ParseError.BranchTooFar;
            }
            const words = self.tbfWriter.instructions.items;
            const off14: i14 = @intCast(offset);
            const opcode: u8 = @truncate(words[ref.instr_idx] & 0xFF);
            words[ref.instr_idx] = switch (ref.kind) {
                .Near     => pBrNear(opcode, off14),
                .NearCond => pBrNearCond(opcode, ref.cond_reg, off14),
            };
        }
    }

    // ── Data flush ─────────────────────────────────────────────────────────

    fn flushDataPages(self: *@This()) ParseError!void {
        var it = self.data_buf.iterator();
        while (it.next()) |entry| {
            const page = entry.key_ptr.*;
            const buf  = entry.value_ptr.*;
            if (buf.items.len == 0) continue;
            var base: u16 = 0xFFFF;
            var sit = self.sym.symbols.valueIterator();
            while (sit.next()) |s| {
                switch (s.*) {
                    .Data  => |d| if (d.page == page and d.offset < base) { base = d.offset; },
                    .Label => {},
                }
            }
            if (base == 0xFFFF) base = 0;
            self.tbfWriter.addDataPage(page, base, buf.items[base..]) catch return ParseError.OutOfMemory;
        }
    }
};

// ── Instruction word packing ──────────────────────────────────────────────────
inline fn ri(reg: RegID) u32 { return @intFromEnum(reg); }

fn pDst(op: u8, dst: RegID, p19: u32) u32 {
    return @as(u32,op) | (ri(dst)<<8) | ((p19&0x7FFFF)<<13);
}
fn pDstSrc(op: u8, dst: RegID, src: RegID, p14: u32) u32 {
    return @as(u32,op) | (ri(dst)<<8) | (ri(src)<<13) | ((p14&0x3FFF)<<18);
}
fn pDstAddrSrc(op: u8, por: RegID, src: RegID, off: i9) u32 {
    return @as(u32,op) | (ri(por)<<8) | (ri(src)<<13) | (@as(u32,@as(u9,@bitCast(off)))<<18);
}
fn pDstAddrXSrc(op: u8, psr: RegID, por: RegID, src: RegID, off: i9) u32 {
    return @as(u32,op) | (ri(psr)<<8) | (ri(por)<<13) | (ri(src)<<18) | (@as(u32,@as(u9,@bitCast(off)))<<23);
}
fn pDstSrcAddr(op: u8, dst: RegID, por: RegID, off: i9) u32 {
    return @as(u32,op) | (ri(dst)<<8) | (ri(por)<<13) | (@as(u32,@as(u9,@bitCast(off)))<<18);
}
fn pDstSrcAddrX(op: u8, dst: RegID, psr: RegID, por: RegID, off: i9) u32 {
    return @as(u32,op) | (ri(dst)<<8) | (ri(psr)<<13) | (ri(por)<<18) | (@as(u32,@as(u9,@bitCast(off)))<<23);
}
fn pDst2Src2(op: u8, d0: RegID, d1: RegID, s0: RegID, s1: RegID) u32 {
    return @as(u32,op) | (ri(d0)<<8) | (ri(d1)<<13) | (ri(s0)<<18) | (ri(s1)<<23);
}
fn pDst2Src2Len(op: u8, d0: RegID, d1: RegID, s0: RegID, s1: RegID, len: RegID) u32 {
    return @as(u32,op) | (ri(d0)<<8) | (ri(d1)<<13) | (ri(s0)<<18) | (ri(s1)<<23) | (@as(u32, ri(len) & 0xF)<<28);
}
fn pDstSrc2(op: u8, dst: RegID, s0: RegID, s1: RegID) u32 {
    return @as(u32,op) | (ri(dst)<<8) | (ri(s0)<<13) | (ri(s1)<<18);
}
fn pDstSrc3(op: u8, dst: RegID, s0: RegID, s1: RegID, s2: RegID) u32 {
    return @as(u32,op) | (ri(dst)<<8) | (ri(s0)<<13) | (ri(s1)<<18) | (ri(s2)<<23);
}
fn pBrNear(op: u8, off: i14) u32 {
    return @as(u32,op) | (@as(u32,@as(u14,@bitCast(off)))<<13);
}
fn pBrNearCond(op: u8, cond: RegID, off: i14) u32 {
    return @as(u32,op) | (ri(cond)<<8) | (@as(u32,@as(u14,@bitCast(off)))<<13);
}
