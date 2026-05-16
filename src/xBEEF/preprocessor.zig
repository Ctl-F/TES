const std = @import("std");
const Io = std.Io;

pub const PreprocError = error{
    IncludeNotFound,
    UnterminatedExpr,
    DivisionByZero,
    UndefinedMacro,
    InvalidExpression,
    OutOfMemory,
    TooManyIncludes,
    UnmatchedEndif,
    UnmatchedElse,
    MissingEndif,
};

const CondState = struct {
    active:     bool, // is this branch currently emitting?
    seen_true:  bool, // has any branch in this block been taken?
    in_else:    bool, // have we passed an #else?
};

pub const Preprocessor = struct {
    allocator:    std.mem.Allocator,
    io:           Io,
    /// key and value are both heap-allocated slices owned by this map
    defines:      std.StringHashMapUnmanaged([]const u8),
    include_dirs: std.ArrayList([]const u8),
    include_depth: u32,
    /// tracks files that have used #once; keys are heap-allocated
    once_files:   std.StringHashMapUnmanaged(void),

    const MaxIncludeDepth = 16;

    pub fn init(allocator: std.mem.Allocator, io: Io) @This() {
        return .{
            .allocator     = allocator,
            .io            = io,
            .defines       = .{},
            .include_dirs  = .empty,
            .include_depth = 0,
            .once_files    = .{},
        };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.defines.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.defines.deinit(self.allocator);
        self.include_dirs.deinit(self.allocator);
        var oit = self.once_files.keyIterator();
        while (oit.next()) |k| self.allocator.free(k.*);
        self.once_files.deinit(self.allocator);
    }

    pub fn addIncludeDir(self: *@This(), dir: []const u8) !void {
        try self.include_dirs.append(self.allocator, dir);
    }

    pub fn addDefine(self: *@This(), name: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        try self.defines.put(self.allocator, k, v);
    }

    fn allActive(stack: []const CondState) bool {
        for (stack) |cs| if (!cs.active) return false;
        return true;
    }

    /// Preprocess src; returns heap-allocated expanded source. Caller frees.
    pub fn process(self: *@This(), src: []const u8, source_path: []const u8) PreprocError![]u8 {
        if (self.include_depth >= MaxIncludeDepth) return PreprocError.TooManyIncludes;

        // #once: skip this file if it has already been fully processed
        if (self.once_files.contains(source_path)) {
            return self.allocator.dupe(u8, "") catch return PreprocError.OutOfMemory;
        }

        self.include_depth += 1;
        defer self.include_depth -= 1;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var cond_stack: std.ArrayList(CondState) = .empty;
        defer cond_stack.deinit(self.allocator);

        // Emit initial line marker so the lexer knows which file line 1 belongs to.
        {
            var tmp: [std.fs.max_path_bytes + 32]u8 = undefined;
            const mark = std.fmt.bufPrint(&tmp, "#line 1 \"{s}\"\n", .{source_path}) catch return PreprocError.OutOfMemory;
            out.appendSlice(self.allocator, mark) catch return PreprocError.OutOfMemory;
        }

        var line_num: u32 = 1;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| {
            defer line_num += 1;
            const trimmed = std.mem.trimStart(u8, line, " \t");

            // ── #once ─────────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#once")) {
                if (allActive(cond_stack.items)) {
                    const key = self.allocator.dupe(u8, source_path) catch return PreprocError.OutOfMemory;
                    const gop = self.once_files.getOrPut(self.allocator, key) catch return PreprocError.OutOfMemory;
                    if (gop.found_existing) {
                        // already marked: the check at the top of process() will
                        // handle future calls; nothing more to do here.
                        self.allocator.free(key);
                    }
                    // else: key is now owned by once_files
                }
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #ifdef ────────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#ifdef")) {
                const name = std.mem.trim(u8, trimmed["#ifdef".len..], " \t\r");
                const take = allActive(cond_stack.items) and self.defines.contains(name);
                cond_stack.append(self.allocator, .{
                    .active    = take,
                    .seen_true = take,
                    .in_else   = false,
                }) catch return PreprocError.OutOfMemory;
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #ifndef ───────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#ifndef")) {
                const name = std.mem.trim(u8, trimmed["#ifndef".len..], " \t\r");
                const take = allActive(cond_stack.items) and !self.defines.contains(name);
                cond_stack.append(self.allocator, .{
                    .active    = take,
                    .seen_true = take,
                    .in_else   = false,
                }) catch return PreprocError.OutOfMemory;
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #elif ─────────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#elif")) {
                if (cond_stack.items.len == 0) {
                    std.debug.print("Preprocessor error: #elif without #ifdef/#ifndef\n", .{});
                    return PreprocError.UnmatchedElse;
                }
                const top = &cond_stack.items[cond_stack.items.len - 1];
                if (top.in_else) {
                    std.debug.print("Preprocessor error: #elif after #else\n", .{});
                    return PreprocError.UnmatchedElse;
                }
                const name = std.mem.trim(u8, trimmed["#elif".len..], " \t\r");
                const parent_active = if (cond_stack.items.len > 1)
                    allActive(cond_stack.items[0 .. cond_stack.items.len - 1])
                else
                    true;
                if (!top.seen_true and parent_active and self.defines.contains(name)) {
                    top.active    = true;
                    top.seen_true = true;
                } else {
                    top.active = false;
                }
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #else ─────────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#else")) {
                if (cond_stack.items.len == 0) {
                    std.debug.print("Preprocessor error: #else without #ifdef/#ifndef\n", .{});
                    return PreprocError.UnmatchedElse;
                }
                const top = &cond_stack.items[cond_stack.items.len - 1];
                if (top.in_else) {
                    std.debug.print("Preprocessor error: duplicate #else\n", .{});
                    return PreprocError.UnmatchedElse;
                }
                const parent_active = if (cond_stack.items.len > 1)
                    allActive(cond_stack.items[0 .. cond_stack.items.len - 1])
                else
                    true;
                top.active  = parent_active and !top.seen_true;
                top.in_else = true;
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #endif ────────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#endif")) {
                if (cond_stack.items.len == 0) {
                    std.debug.print("Preprocessor error: #endif without matching #ifdef/#ifndef\n", .{});
                    return PreprocError.UnmatchedEndif;
                }
                _ = cond_stack.pop();
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #undef ────────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#undef")) {
                if (allActive(cond_stack.items)) {
                    const name = std.mem.trim(u8, trimmed["#undef".len..], " \t\r");
                    if (self.defines.getKey(name)) |old_key| {
                        const old_val = self.defines.get(old_key).?;
                        self.allocator.free(old_val);
                        self.allocator.free(old_key);
                        _ = self.defines.remove(name);
                    }
                }
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #include ──────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#include")) {
                if (allActive(cond_stack.items)) {
                    const rest = std.mem.trim(u8, trimmed["#include".len..], " \t");
                    const included = try self.processInclude(rest, source_path);
                    defer self.allocator.free(included);
                    try out.appendSlice(self.allocator, included);
                    // Restore parent file/line after include expansion
                    {
                        var tmp: [std.fs.max_path_bytes + 32]u8 = undefined;
                        const mark = std.fmt.bufPrint(&tmp, "#line {} \"{s}\"\n", .{ line_num + 1, source_path }) catch return PreprocError.OutOfMemory;
                        out.appendSlice(self.allocator, mark) catch return PreprocError.OutOfMemory;
                    }
                }
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── #define ───────────────────────────────────────────────────
            if (std.mem.startsWith(u8, trimmed, "#define")) {
                if (allActive(cond_stack.items)) {
                    try self.processDefine(trimmed["#define".len..]);
                }
                try out.append(self.allocator, '\n');
                continue;
            }

            // ── ordinary line ─────────────────────────────────────────────
            if (allActive(cond_stack.items)) {
                const expanded = try self.expandLine(line);
                defer self.allocator.free(expanded);
                try out.appendSlice(self.allocator, expanded);
            }
            try out.append(self.allocator, '\n');
        }

        if (cond_stack.items.len > 0) {
            std.debug.print("Preprocessor error: {d} unclosed #ifdef/#ifndef block(s)\n",
                .{cond_stack.items.len});
            return PreprocError.MissingEndif;
        }

        return out.toOwnedSlice(self.allocator) catch return PreprocError.OutOfMemory;
    }

    fn processInclude(self: *@This(), spec: []const u8, source_path: []const u8) PreprocError![]u8 {
        var filename: []const u8 = spec;
        if (spec.len >= 2 and ((spec[0] == '<' and spec[spec.len-1] == '>') or
                               (spec[0] == '"' and spec[spec.len-1] == '"'))) {
            filename = spec[1..spec.len-1];
        }
        filename = std.mem.trim(u8, filename, " \t\r");

        const source_dir = std.Io.Dir.path.dirname(source_path) orelse ".";
        const rel = std.Io.Dir.path.join(self.allocator, &.{ source_dir, filename }) catch return PreprocError.OutOfMemory;
        defer self.allocator.free(rel);

        if (self.tryReadFile(rel)) |content| {
            defer self.allocator.free(content);
            return self.process(content, rel);
        }

        for (self.include_dirs.items) |dir| {
            const path = std.Io.Dir.path.join(self.allocator, &.{ dir, filename }) catch return PreprocError.OutOfMemory;
            defer self.allocator.free(path);
            if (self.tryReadFile(path)) |content| {
                defer self.allocator.free(content);
                return self.process(content, path);
            }
        }

        std.debug.print("Error: cannot find include '{s}'\n", .{filename});
        return PreprocError.IncludeNotFound;
    }

    fn tryReadFile(self: *@This(), path: []const u8) ?[]u8 {
        return Io.Dir.cwd().readFileAlloc(
            self.io, path, self.allocator, .limited(16 * 1024 * 1024),
        ) catch return null;
    }

    fn processDefine(self: *@This(), rest: []const u8) PreprocError!void {
        const trimmed = std.mem.trim(u8, rest, " \t");
        var i: usize = 0;
        while (i < trimmed.len and !std.ascii.isWhitespace(trimmed[i])) : (i += 1) {}
        const name  = trimmed[0..i];
        const value = if (i < trimmed.len) std.mem.trim(u8, trimmed[i..], " \t") else "";

        // Replace existing define if present
        if (self.defines.getKey(name)) |old_key| {
            const old_val = self.defines.get(old_key).?;
            self.allocator.free(old_val);
            self.allocator.free(old_key);
            _ = self.defines.remove(name);
        }

        const k = self.allocator.dupe(u8, name) catch return PreprocError.OutOfMemory;
        errdefer self.allocator.free(k);
        const v = self.allocator.dupe(u8, value) catch return PreprocError.OutOfMemory;
        self.defines.put(self.allocator, k, v) catch return PreprocError.OutOfMemory;
    }

    fn expandLine(self: *@This(), line: []const u8) PreprocError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '$' and i + 1 < line.len and
                (std.ascii.isAlphabetic(line[i+1]) or line[i+1] == '_'))
            {
                // $WORD shorthand — collect identifier characters
                var j = i + 1;
                while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_')) : (j += 1) {}
                const expr = line[i+1..j];

                // $sizeOf(...) and $offsetOf(...) are struct-aware builtins resolved by
                // the parser, not here. Pass them through verbatim including the (...).
                if (std.mem.eql(u8, expr, "sizeOf") or std.mem.eql(u8, expr, "offsetOf") or
                    std.mem.eql(u8, expr, "nSizeOf") or
                    std.mem.eql(u8, expr, "sizeOfAligned") or std.mem.eql(u8, expr, "nSizeOfAligned")) {
                    try out.append(self.allocator, '$');
                    try out.appendSlice(self.allocator, expr);
                    if (j < line.len and line[j] == '(') {
                        var depth: usize = 1;
                        try out.append(self.allocator, '(');
                        j += 1;
                        while (j < line.len and depth > 0) : (j += 1) {
                            if (line[j] == '(') depth += 1;
                            if (line[j] == ')') depth -= 1;
                            try out.append(self.allocator, line[j]);
                        }
                    }
                    i = j;
                } else {
                const expanded_expr = try self.expandLine(expr);
                defer self.allocator.free(expanded_expr);
                const val = try self.evalExpr(expanded_expr);
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return PreprocError.InvalidExpression;
                try out.appendSlice(self.allocator, num_str);
                i = j;
                }
            } else if (i + 1 < line.len and line[i] == '$' and line[i+1] == '{') {
                const start = i + 2;
                var depth: usize = 1;
                var j = start;
                while (j < line.len and depth > 0) : (j += 1) {
                    if (line[j] == '{') depth += 1;
                    if (line[j] == '}') depth -= 1;
                }
                if (depth != 0) return PreprocError.UnterminatedExpr;
                const expr = line[start..j-1];
                const expanded_expr = try self.expandLine(expr);
                defer self.allocator.free(expanded_expr);
                const val = try self.evalExpr(expanded_expr);
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return PreprocError.InvalidExpression;
                try out.appendSlice(self.allocator, num_str);
                i = j;
            } else {
                try out.append(self.allocator, line[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(self.allocator) catch return PreprocError.OutOfMemory;
    }

    pub fn evalExpr(self: *@This(), expr: []const u8) PreprocError!i64 {
        var p = ExprParser.init(self.allocator, expr, &self.defines);
        return p.parseExpr();
    }
};

const ExprParser = struct {
    src: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    defines: *const std.StringHashMapUnmanaged([]const u8),

    fn init(allocator: std.mem.Allocator, src: []const u8, defines: *const std.StringHashMapUnmanaged([]const u8)) @This() {
        return .{ .src = src, .pos = 0, .allocator = allocator, .defines = defines };
    }

    fn skipWs(self: *@This()) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) : (self.pos += 1) {}
    }

    fn peek(self: *@This()) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn parseExpr(self: *@This()) PreprocError!i64  { return self.parseBitOr(); }

    fn parseBitOr(self: *@This()) PreprocError!i64 {
        var l = try self.parseBitXor();
        self.skipWs();
        while (self.peek() == '|' and (self.pos+1 >= self.src.len or self.src[self.pos+1] != '|')) {
            self.pos += 1; l |= try self.parseBitXor(); self.skipWs();
        }
        return l;
    }
    fn parseBitXor(self: *@This()) PreprocError!i64 {
        var l = try self.parseBitAnd();
        self.skipWs();
        while (self.peek() == '^') { self.pos += 1; l ^= try self.parseBitAnd(); self.skipWs(); }
        return l;
    }
    fn parseBitAnd(self: *@This()) PreprocError!i64 {
        var l = try self.parseShift();
        self.skipWs();
        while (self.peek() == '&' and (self.pos+1 >= self.src.len or self.src[self.pos+1] != '&')) {
            self.pos += 1; l &= try self.parseShift(); self.skipWs();
        }
        return l;
    }
    fn parseShift(self: *@This()) PreprocError!i64 {
        var l = try self.parseAddSub();
        self.skipWs();
        while (self.pos < self.src.len) {
            if (self.pos+1 < self.src.len and self.src[self.pos] == '<' and self.src[self.pos+1] == '<') {
                self.pos += 2; l <<= @intCast((try self.parseAddSub()) & 63);
            } else if (self.pos+1 < self.src.len and self.src[self.pos] == '>' and self.src[self.pos+1] == '>') {
                self.pos += 2; l >>= @intCast((try self.parseAddSub()) & 63);
            } else break;
            self.skipWs();
        }
        return l;
    }
    fn parseAddSub(self: *@This()) PreprocError!i64 {
        var l = try self.parseMulDiv();
        self.skipWs();
        while (self.peek()) |c| {
            if (c == '+') { self.pos += 1; l += try self.parseMulDiv(); }
            else if (c == '-') { self.pos += 1; l -= try self.parseMulDiv(); }
            else break;
            self.skipWs();
        }
        return l;
    }
    fn parseMulDiv(self: *@This()) PreprocError!i64 {
        var l = try self.parseUnary();
        self.skipWs();
        while (self.peek()) |c| {
            if (c == '*') { self.pos += 1; l *%= try self.parseUnary(); }
            else if (c == '/') { self.pos += 1; const r = try self.parseUnary(); if (r == 0) return PreprocError.DivisionByZero; l = @divTrunc(l, r); }
            else if (c == '%') { self.pos += 1; const r = try self.parseUnary(); if (r == 0) return PreprocError.DivisionByZero; l = @rem(l, r); }
            else break;
            self.skipWs();
        }
        return l;
    }
    fn parseUnary(self: *@This()) PreprocError!i64 {
        self.skipWs();
        if (self.peek() == '-') { self.pos += 1; return -(try self.parseUnary()); }
        if (self.peek() == '~') { self.pos += 1; return ~(try self.parseUnary()); }
        if (self.peek() == '+') { self.pos += 1; return try self.parseUnary(); }
        return self.parseAtom();
    }
    fn parseAtom(self: *@This()) PreprocError!i64 {
        self.skipWs();
        if (self.peek() == '(') {
            self.pos += 1;
            const v = try self.parseExpr();
            self.skipWs();
            if (self.peek() == ')') self.pos += 1;
            return v;
        }
        // hex
        if (self.pos+1 < self.src.len and self.src[self.pos] == '0' and
            (self.src[self.pos+1] == 'x' or self.src[self.pos+1] == 'X'))
        {
            self.pos += 2;
            var v: i64 = 0;
            while (self.peek()) |c| {
                const d: ?i64 = switch(c) { '0'...'9'=>c-'0', 'a'...'f'=>c-'a'+10, 'A'...'F'=>c-'A'+10, else=>null };
                if (d) |dv| { v = v*16+dv; self.pos += 1; } else break;
            }
            return v;
        }
        // binary
        if (self.pos+1 < self.src.len and self.src[self.pos] == '0' and
            (self.src[self.pos+1] == 'b' or self.src[self.pos+1] == 'B'))
        {
            self.pos += 2;
            var v: i64 = 0;
            while (self.peek()) |c| { if (c=='0' or c=='1') { v=v*2+(c-'0'); self.pos+=1; } else break; }
            return v;
        }
        // decimal
        if (self.peek()) |c| {
            if (c >= '0' and c <= '9') {
                var v: i64 = 0;
                while (self.peek()) |ch| { if (ch>='0' and ch<='9') { v=v*10+(ch-'0'); self.pos+=1; } else break; }
                return v;
            }
        }
        // identifier macro
        if (self.peek()) |c| {
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const s = self.pos;
                while (self.peek()) |ch| { if (std.ascii.isAlphanumeric(ch) or ch=='_') { self.pos+=1; } else break; }
                const name = self.src[s..self.pos];
                if (self.defines.get(name)) |vs| {
                    var sub = ExprParser.init(self.allocator, vs, self.defines);
                    return sub.parseExpr();
                }
                std.debug.print("Error: undefined macro '{s}'\n", .{name});
                return PreprocError.UndefinedMacro;
            }
        }
        return PreprocError.InvalidExpression;
    }
};
