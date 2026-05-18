const std = @import("std");
const ast = @import("ast.zig");
const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;

// ─── Register constants ────────────────────────────────────────────────────────
// Param registers: R0-R7 (8 params max)
// Local scratch:   RA-RD (4 slots, callee-saved)
// Expr temps:      R8 (primary), R9 (secondary)
// Call setup:      RE (target offset), RF (target page)
// Return addr:     JR, JRH (callee-saved pair)

const MAX_LOCALS = 4;
const SCRATCH_REGS = [MAX_LOCALS][]const u8{ "ra", "rb", "rc", "rd" };
const PARAM_REGS = [_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7" };
const EXPR_TEMP = "r8";
const EXPR_TEMP2 = "r9";
const CALL_PAGE = "rf";
const CALL_OFFSET = "re";

pub const CodegenError = error{
    TooManyLocals,
    UnknownSymbol,
    UnsupportedExpr,
    OutOfMemory,
    InvalidLValue,
};

const LocalInfo = struct {
    reg: []const u8,
    type_expr: ast.TypeExpr,
};

pub const Codegen = struct {
    gpa: std.mem.Allocator,
    sema: *const Sema,
    label_counter: u32 = 0,

    // Per-function state — reset in beginFn
    fn_name: []const u8 = "",
    fn_ret_label: []const u8 = "",
    locals: std.StringHashMapUnmanaged(LocalInfo) = .{},
    const_vals: std.StringHashMapUnmanaged(i64) = .{},
    scratch_used: u3 = 0, // how many scratch regs allocated so far

    pub fn init(gpa: std.mem.Allocator, s: *const Sema) Codegen {
        return .{ .gpa = gpa, .sema = s };
    }

    pub fn deinit(self: *Codegen) void {
        self.locals.deinit(self.gpa);
        self.const_vals.deinit(self.gpa);
    }

    fn newLabel(self: *Codegen) u32 {
        const n = self.label_counter;
        self.label_counter += 1;
        return n;
    }

    fn nextScratch(self: *Codegen) CodegenError![]const u8 {
        if (self.scratch_used >= MAX_LOCALS) {
            std.debug.print("error: too many local variables in function '{s}' (max {})\n",
                .{ self.fn_name, MAX_LOCALS });
            return CodegenError.TooManyLocals;
        }
        const reg = SCRATCH_REGS[self.scratch_used];
        self.scratch_used += 1;
        return reg;
    }

    fn resetFn(self: *Codegen) void {
        self.locals.clearRetainingCapacity();
        self.const_vals.clearRetainingCapacity();
        self.scratch_used = 0;
        self.fn_name = "";
        self.fn_ret_label = "";
    }

    // ─── Pre-scan to count locals ──────────────────────────────────────────────

    fn countLocalsInStmt(s: *const ast.Stmt) u32 {
        return switch (s.*) {
            .var_decl => 1,
            .block => |stmts| blk: {
                var n: u32 = 0;
                for (stmts) |st| n += countLocalsInStmt(st);
                break :blk n;
            },
            .if_stmt => |is| blk: {
                var n = countLocalsInStmt(is.then_stmt);
                if (is.else_stmt) |es| n += countLocalsInStmt(es);
                break :blk n;
            },
            .while_stmt => |ws| countLocalsInStmt(ws.body),
            .do_while => |dw| countLocalsInStmt(dw.body),
            .for_stmt => |fs| blk: {
                var n: u32 = 0;
                if (fs.init) |i| n += countLocalsInStmt(i);
                n += countLocalsInStmt(fs.body);
                break :blk n;
            },
            .inline_for => |ilf| countLocalsInStmt(ilf.body) + 1,
            else => 0,
        };
    }

    // ─── Public generate entry point ───────────────────────────────────────────

    pub fn generate(self: *Codegen, file: *const ast.File, writer: anytype) !void {
        // ── Data section ──────────────────────────────────────────────────────
        try self.emitDataSection(file, writer);

        // ── Code section ──────────────────────────────────────────────────────
        try writer.print("\n[Code({d}:0x0000)]\n", .{sema_mod.CODE_PAGE});

        for (file.decls) |*decl| {
            if (decl.* == .fn_decl) {
                try self.genFunction(&decl.fn_decl, writer);
            }
        }
    }

    fn emitDataSection(self: *Codegen, file: *const ast.File, writer: anytype) !void {
        const has_data = self.sema.globals.count() > 0 or self.sema.string_lits.items.len > 0;
        if (!has_data) return;

        try writer.print("[Data({d}:0x{X:0>4})]\n", .{ sema_mod.DATA_PAGE, sema_mod.DATA_START });

        // Emit global variables in declaration order
        for (file.decls) |*decl| {
            if (decl.* != .global_var) continue;
            const gv = &decl.global_var;
            const info = self.sema.globals.get(gv.name) orelse continue;

            try writer.print("_cm_g_{s}:\n", .{gv.name});

            switch (gv.type_expr) {
                .u8, .i8 => {
                    const val: i64 = info.init_value orelse 0;
                    try writer.print("    .u8 {}\n", .{@as(u8, @intCast(val & 0xFF))});
                },
                .u16, .i16 => {
                    const val: i64 = info.init_value orelse 0;
                    try writer.print("    .u16 {}\n", .{@as(u16, @intCast(val & 0xFFFF))});
                },
                .flex_array => {
                    if (info.string_content) |sc| {
                        try writer.writeAll("    .u8 ");
                        for (sc, 0..) |b, i| {
                            if (i > 0) try writer.writeAll(", ");
                            try writer.print("{}", .{b});
                        }
                        try writer.writeAll("\n");
                    } else {
                        try writer.writeAll("    .u8 0\n");
                    }
                },
                .array => |arr| {
                    const elem_size = self.sema.typeSize(arr.elem.*);
                    const byte_size = arr.size * elem_size;
                    // emit as bytes
                    if (byte_size > 0) {
                        try writer.writeAll("    .u8");
                        for (0..byte_size) |i| {
                            if (i == 0) try writer.writeAll(" 0")
                            else try writer.writeAll(", 0");
                        }
                        try writer.writeAll("\n");
                    }
                },
                .u8_vec2, .i8_vec2 => {
                    const val: i64 = info.init_value orelse 0;
                    try writer.print("    .u16 {}\n", .{@as(u16, @intCast(val & 0xFFFF))});
                },
                else => {
                    try writer.writeAll("    .u8 0\n");
                },
            }
        }

        // Emit inline string literals from function bodies
        for (self.sema.string_lits.items) |*sl| {
            try writer.print("{s}:\n", .{sl.label});
            try writer.writeAll("    .u8 ");
            for (sl.content, 0..) |b, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{}", .{b});
            }
            try writer.writeAll("\n");
        }
    }

    // ─── Function generation ───────────────────────────────────────────────────

    fn genFunction(self: *Codegen, fd: *const ast.FnDecl, writer: anytype) !void {
        self.resetFn();
        self.fn_name = fd.name;

        // Count params + locals for scratch reg pre-allocation
        const param_count = fd.params.len;
        var local_count: u32 = 0;
        for (fd.body) |s| local_count += countLocalsInStmt(s);

        const total = param_count + local_count;
        if (total > MAX_LOCALS) {
            std.debug.print("error: function '{s}': too many vars ({} params + {} locals > {})\n",
                .{ fd.name, param_count, local_count, MAX_LOCALS });
            return CodegenError.TooManyLocals;
        }

        // Generate return label
        const ret_lbl_n = self.newLabel();
        self.fn_ret_label = try std.fmt.allocPrint(self.gpa, "_cm_L_{}", .{ret_lbl_n});

        // Emit function label
        if (std.mem.eql(u8, fd.name, "main")) {
            try writer.writeAll("main:\n");
        }
        try writer.print("_cm_{s}:\n", .{fd.name});

        // ── Prologue ──────────────────────────────────────────────────────────
        // Allocate scratch regs for params first
        for (fd.params) |p| {
            const reg = try self.nextScratch();
            try self.locals.put(self.gpa, p.name, .{ .reg = reg, .type_expr = p.type_expr });
        }
        const scratch_count = self.scratch_used + @as(u3, @intCast(local_count));
        _ = scratch_count; // used implicitly below via scratch_used at end

        try writer.writeAll("    push jrh\n");
        try writer.writeAll("    push jr\n");

        // Push scratch regs we'll use (params already counted, locals will be added)
        // We need to push exactly (total) scratch regs. Since we know total upfront, push them all.
        for (0..total) |i| {
            try writer.print("    push {s}\n", .{SCRATCH_REGS[i]});
        }

        // Copy params from R0-Rn into their scratch regs
        for (fd.params, 0..) |p, i| {
            const local = self.locals.get(p.name).?;
            if (!std.mem.eql(u8, local.reg, PARAM_REGS[i])) {
                try writer.print("    mov {s}, {s}\n", .{ local.reg, PARAM_REGS[i] });
            }
        }

        // ── Body ──────────────────────────────────────────────────────────────
        for (fd.body) |s| {
            try self.genStmt(s, writer);
        }

        // ── Epilogue ──────────────────────────────────────────────────────────
        try writer.print("{s}:\n", .{self.fn_ret_label});

        // Move return value from R8 to R0 (if not void and not already there)
        if (fd.return_type != .void) {
            try writer.print("    mov r0, {s}\n", .{EXPR_TEMP});
        }

        // Pop scratch regs in reverse order
        var i: usize = total;
        while (i > 0) {
            i -= 1;
            try writer.print("    pop {s}\n", .{SCRATCH_REGS[i]});
        }
        try writer.writeAll("    pop jr\n");
        try writer.writeAll("    pop jrh\n");
        try writer.writeAll("    b jr\n\n");
    }

    // ─── Statement generation ──────────────────────────────────────────────────

    fn genStmt(self: *Codegen, s: *const ast.Stmt, writer: anytype) anyerror!void {
        switch (s.*) {
            .var_decl => |vd| try self.genVarDecl(&vd, writer),
            .const_decl => |cd| {
                // Evaluate as constant if possible, otherwise just store
                if (cd.value.* == .int_lit) {
                    try self.const_vals.put(self.gpa, cd.name, cd.value.int_lit.value);
                } else {
                    // Evaluate and store in a scratch reg
                    const reg = try self.nextScratch();
                    try self.locals.put(self.gpa, cd.name, .{
                        .reg = reg, .type_expr = .u16
                    });
                    try self.genExpr(cd.value, writer);
                    try writer.print("    mov {s}, {s}\n", .{ reg, EXPR_TEMP });
                }
            },
            .expr_stmt => |e| try self.genExpr(e, writer),
            .block => |stmts| for (stmts) |st| try self.genStmt(st, writer),
            .if_stmt => |is| try self.genIf(&is, writer),
            .while_stmt => |ws| try self.genWhile(&ws, writer),
            .do_while => |dw| try self.genDoWhile(&dw, writer),
            .for_stmt => |fs| try self.genFor(&fs, writer),
            .inline_for => |ilf| try self.genInlineFor(&ilf, writer),
            .return_stmt => |rs| {
                if (rs.value) |v| {
                    try self.genExpr(v, writer);
                    // result already in R8 (EXPR_TEMP)
                }
                try writer.print("    bn {s}\n", .{self.fn_ret_label});
            },
            .asm_block => |ab| {
                for (ab.lines) |line| {
                    try writer.print("    {s}\n", .{line});
                }
            },
            .break_stmt => {
                // would need a break label — emit comment for now
                try writer.writeAll("    ; break (not fully supported)\n");
            },
            .continue_stmt => {
                try writer.writeAll("    ; continue (not fully supported)\n");
            },
        }
    }

    fn genVarDecl(self: *Codegen, vd: *const ast.VarDecl, writer: anytype) !void {
        const reg = try self.nextScratch();
        try self.locals.put(self.gpa, vd.name, .{ .reg = reg, .type_expr = vd.type_expr });

        if (vd.init) |init_expr| {
            switch (init_expr.*) {
                .undefined_val => {}, // no init needed
                else => {
                    try self.genExpr(init_expr, writer);
                    try writer.print("    mov {s}, {s}\n", .{ reg, EXPR_TEMP });
                },
            }
        }
    }

    fn genIf(self: *Codegen, is: *const ast.IfStmt, writer: anytype) !void {
        const else_lbl = self.newLabel();
        const end_lbl = self.newLabel();

        try self.genExpr(is.cond, writer);
        if (is.else_stmt != null) {
            try writer.print("    bnf {s}, _cm_L_{}\n", .{ EXPR_TEMP, else_lbl });
        } else {
            try writer.print("    bnf {s}, _cm_L_{}\n", .{ EXPR_TEMP, end_lbl });
        }

        try self.genStmt(is.then_stmt, writer);

        if (is.else_stmt) |es| {
            try writer.print("    bn _cm_L_{}\n", .{end_lbl});
            try writer.print("_cm_L_{}:\n", .{else_lbl});
            try self.genStmt(es, writer);
        }
        try writer.print("_cm_L_{}:\n", .{end_lbl});
    }

    fn genWhile(self: *Codegen, ws: *const ast.WhileStmt, writer: anytype) !void {
        const top_lbl = self.newLabel();
        const end_lbl = self.newLabel();

        try writer.print("_cm_L_{}:\n", .{top_lbl});
        try self.genExpr(ws.cond, writer);
        try writer.print("    bnf {s}, _cm_L_{}\n", .{ EXPR_TEMP, end_lbl });
        try self.genStmt(ws.body, writer);
        try writer.print("    bn _cm_L_{}\n", .{top_lbl});
        try writer.print("_cm_L_{}:\n", .{end_lbl});
    }

    fn genDoWhile(self: *Codegen, dw: *const ast.DoWhileStmt, writer: anytype) !void {
        const top_lbl = self.newLabel();
        try writer.print("_cm_L_{}:\n", .{top_lbl});
        try self.genStmt(dw.body, writer);
        try self.genExpr(dw.cond, writer);
        try writer.print("    bnt {s}, _cm_L_{}\n", .{ EXPR_TEMP, top_lbl });
    }

    fn genFor(self: *Codegen, fs: *const ast.ForStmt, writer: anytype) !void {
        if (fs.init) |fs_init| try self.genStmt(fs_init, writer);

        const top_lbl = self.newLabel();
        const end_lbl = self.newLabel();

        try writer.print("_cm_L_{}:\n", .{top_lbl});

        if (fs.cond) |cond| {
            try self.genExpr(cond, writer);
            try writer.print("    bnf {s}, _cm_L_{}\n", .{ EXPR_TEMP, end_lbl });
        }

        try self.genStmt(fs.body, writer);

        if (fs.update) |upd| try self.genExpr(upd, writer);

        try writer.print("    bn _cm_L_{}\n", .{top_lbl});
        try writer.print("_cm_L_{}:\n", .{end_lbl});
    }

    fn genInlineFor(self: *Codegen, ilf: *const ast.InlineForStmt, writer: anytype) !void {
        // Only supported when start and end are integer literals
        const start_val = switch (ilf.start.*) {
            .int_lit => |il| il.value,
            else => {
                try writer.writeAll("    ; inline for: non-constant start — emitting as regular for\n");
                return self.genForFallback(ilf, writer);
            },
        };
        const end_val = switch (ilf.end.*) {
            .int_lit => |il| il.value,
            else => return self.genForFallback(ilf, writer),
        };

        // Unroll the loop
        var iter = start_val;
        while (iter < end_val) : (iter += 1) {
            // Bind the iterator as a compile-time constant
            try self.const_vals.put(self.gpa, ilf.iter_name, iter);
            try self.genStmt(ilf.body, writer);
        }
        _ = self.const_vals.remove(ilf.iter_name);
    }

    fn genForFallback(self: *Codegen, ilf: *const ast.InlineForStmt, writer: anytype) !void {
        // Emit as regular for loop
        const reg = try self.nextScratch();
        try self.locals.put(self.gpa, ilf.iter_name, .{ .reg = reg, .type_expr = ilf.iter_type });
        try self.genExpr(ilf.start, writer);
        try writer.print("    mov {s}, {s}\n", .{ reg, EXPR_TEMP });

        const top_lbl = self.newLabel();
        const end_lbl = self.newLabel();
        try writer.print("_cm_L_{}:\n", .{top_lbl});
        try self.genExpr(ilf.end, writer);
        const end_reg = EXPR_TEMP2;
        try writer.print("    mov {s}, {s}\n", .{ end_reg, EXPR_TEMP });
        try writer.print("    seteq {s}, {s}, {s}\n", .{ EXPR_TEMP, reg, end_reg });
        try writer.print("    bnt {s}, _cm_L_{}\n", .{ EXPR_TEMP, end_lbl });
        try self.genStmt(ilf.body, writer);
        try writer.print("    inc {s}\n", .{reg});
        try writer.print("    bn _cm_L_{}\n", .{top_lbl});
        try writer.print("_cm_L_{}:\n", .{end_lbl});
    }

    // ─── Expression generation ─────────────────────────────────────────────────
    // Result is always in EXPR_TEMP (r8) after genExpr returns.

    fn genExpr(self: *Codegen, e: *const ast.Expr, writer: anytype) anyerror!void {
        switch (e.*) {
            .int_lit => |il| {
                try writer.print("    mov {s}, {}\n", .{ EXPR_TEMP, il.value });
            },
            .string_lit => |sl| {
                // Put (page=0, offset) into R8 — actually address is two values.
                // For string literals used as expressions, load their offset into R8.
                // The page would need to be handled separately.
                const decoded = try sema_mod.decodeStringLit(self.gpa, sl.raw);
                defer self.gpa.free(decoded);
                if (self.sema.findStringLit(sl.raw)) |lit| {
                    try writer.print("    mov {s}, 0x{X:0>4}\n", .{ EXPR_TEMP, lit.offset });
                } else {
                    try writer.print("    mov {s}, 0\n", .{EXPR_TEMP});
                }
            },
            .undefined_val => {
                try writer.print("    mov {s}, 0\n", .{EXPR_TEMP});
            },
            .ident => |id| try self.genIdent(id.name, id.loc, writer),
            .dot_len => |dl| {
                // expr.len — for globals this is a comptime value
                switch (dl.base.*) {
                    .ident => |id| {
                        if (self.sema.globals.get(id.name)) |gi| {
                            const len: u32 = switch (gi.type_expr) {
                                .flex_array => gi.array_len,
                                .array => |arr| arr.size,
                                else => 1,
                            };
                            try writer.print("    mov {s}, {}\n", .{ EXPR_TEMP, len });
                        } else {
                            try writer.print("    mov {s}, 0\n", .{EXPR_TEMP});
                        }
                    },
                    else => try writer.print("    mov {s}, 0\n", .{EXPR_TEMP}),
                }
            },
            .unary => |u| try self.genUnary(u, writer),
            .binary => |b| try self.genBinary(b, writer),
            .ternary => |tn| try self.genTernary(tn, writer),
            .call => |c| try self.genCall(c, writer),
            .ext_ptr => |ep| {
                // (page, addr) evaluated as the addr part only
                try self.genExpr(ep.addr_expr, writer);
            },
            .ext_deref => |ed| try self.genExtDeref(ed, writer),
            .ext_call => |ec| try self.genExtCall(ec, writer),
            .index => |idx| try self.genIndex(idx, writer),
            .field => |f| try self.genField(f, writer),
        }
    }

    fn genIdent(self: *Codegen, name: []const u8, loc: ast.Loc, writer: anytype) !void {
        // Check compile-time constant first
        if (self.const_vals.get(name)) |cv| {
            try writer.print("    mov {s}, {}\n", .{ EXPR_TEMP, cv });
            return;
        }
        // Local variable
        if (self.locals.get(name)) |local| {
            try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP, local.reg });
            return;
        }
        // Global variable
        if (self.sema.globals.get(name)) |gi| {
            // Load from page-0 memory
            try writer.print("    mov {s}, 0x{X:0>4}\n", .{ EXPR_TEMP2, gi.offset });
            if (gi.type_expr.isByte()) {
                try writer.print("    (byte) mov {s}, [{s}]\n", .{ EXPR_TEMP, EXPR_TEMP2 });
            } else {
                try writer.print("    mov {s}, [{s}]\n", .{ EXPR_TEMP, EXPR_TEMP2 });
            }
            return;
        }
        std.debug.print("{s}:{}:{}: error: unknown identifier '{s}'\n",
            .{ loc.file, loc.line, loc.col, name });
        return CodegenError.UnknownSymbol;
    }

    fn genUnary(self: *Codegen, u: anytype, writer: anytype) !void {
        switch (u.op) {
            .neg => {
                try self.genExpr(u.operand, writer);
                try writer.print("    neg {s}\n", .{EXPR_TEMP});
            },
            .bnot => {
                try self.genExpr(u.operand, writer);
                try writer.print("    not {s}\n", .{EXPR_TEMP});
            },
            .lnot => {
                try self.genExpr(u.operand, writer);
                try writer.print("    lnot {s}\n", .{EXPR_TEMP});
            },
            .deref => {
                // *ptr — page-0 dereference
                try self.genExpr(u.operand, writer);
                try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP2, EXPR_TEMP });
                try writer.print("    mov {s}, [{s}]\n", .{ EXPR_TEMP, EXPR_TEMP2 });
            },
            .addr_of => {
                // &ident — load the address of a global or local
                switch (u.operand.*) {
                    .ident => |id| {
                        if (self.sema.globals.get(id.name)) |gi| {
                            // Address = offset (page-0, so page=0 is implicit)
                            try writer.print("    mov {s}, 0x{X:0>4}\n", .{ EXPR_TEMP, gi.offset });
                        } else {
                            std.debug.print("error: cannot take address of local '{s}' (stack addressing not supported)\n", .{id.name});
                            return CodegenError.UnsupportedExpr;
                        }
                    },
                    else => {
                        std.debug.print("error: address-of on non-identifier expression\n", .{});
                        return CodegenError.UnsupportedExpr;
                    },
                }
            },
            .pre_inc => {
                try self.genStorableIncDec(u.operand, true, true, writer);
            },
            .pre_dec => {
                try self.genStorableIncDec(u.operand, false, true, writer);
            },
            .post_inc => {
                try self.genStorableIncDec(u.operand, true, false, writer);
            },
            .post_dec => {
                try self.genStorableIncDec(u.operand, false, false, writer);
            },
        }
    }

    fn genStorableIncDec(self: *Codegen, operand: *const ast.Expr, inc: bool, pre: bool, writer: anytype) !void {
        try self.genExpr(operand, writer);
        if (!pre) try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP2, EXPR_TEMP }); // save old value
        if (inc) {
            try writer.print("    inc {s}\n", .{EXPR_TEMP});
        } else {
            try writer.print("    dec {s}\n", .{EXPR_TEMP});
        }
        try self.genStore(operand, EXPR_TEMP, writer);
        if (!pre) try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }); // restore old for post
    }

    fn genBinary(self: *Codegen, b: anytype, writer: anytype) !void {
        // Handle assignment specially
        if (b.op == .assign) {
            // Special case: ext_ptr assignment
            switch (b.lhs.*) {
                .ext_ptr => |ep| {
                    try self.genExtPtrAssign(ep.page_expr, ep.addr_expr, b.rhs, writer);
                    return;
                },
                else => {},
            }
            try self.genExpr(b.rhs, writer);
            try self.genStore(b.lhs, EXPR_TEMP, writer);
            return;
        }

        // Compound assignment: op= is lhs = lhs op rhs
        if (b.op.baseOp()) |base| {
            // Compute rhs first, save to R9
            try self.genExpr(b.rhs, writer);
            try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP2, EXPR_TEMP });
            // Load lhs
            try self.genExpr(b.lhs, writer);
            // Apply op
            try self.emitBinOp(base, writer);
            // Store back
            try self.genStore(b.lhs, EXPR_TEMP, writer);
            return;
        }

        // Regular binary: compute lhs, save, compute rhs, combine
        try self.genExpr(b.lhs, writer);
        try writer.print("    push {s}\n", .{EXPR_TEMP}); // save lhs
        try self.genExpr(b.rhs, writer);
        try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP2, EXPR_TEMP }); // r9 = rhs
        try writer.print("    pop {s}\n", .{EXPR_TEMP}); // r8 = lhs
        try self.emitBinOp(b.op, writer);
    }

    fn emitBinOp(self: *Codegen, op: ast.BinOp, writer: anytype) !void {
        _ = self;
        switch (op) {
            .add  => try writer.print("    add {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .sub  => try writer.print("    sub {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .mul  => try writer.print("    mul {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .div  => try writer.print("    div {s}, {s}, {s}, {s}\n", .{
                EXPR_TEMP2, EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 }),
            .mod  => {
                // mod: use div (quotient in r8, remainder concept)
                // TES div: Dst2Src2 format: div rQ, rR, rA, rB  → rQ:rR = rA / rB  (rR = remainder)
                // div r9, r8, r8, r9 → quotient in r9, remainder in r8
                try writer.print("    div {s}, {s}, {s}, {s}\n", .{
                    EXPR_TEMP2, EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 });
            },
            .band => try writer.print("    and {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .bor  => try writer.print("    or {s}, {s}\n",  .{ EXPR_TEMP, EXPR_TEMP2 }),
            .bxor => try writer.print("    xor {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .shl  => try writer.print("    shl {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .shr  => try writer.print("    shr {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .land => try writer.print("    land {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 }),
            .lor  => try writer.print("    lor {s}, {s}\n",  .{ EXPR_TEMP, EXPR_TEMP2 }),
            .eq   => try writer.print("    seteq {s}, {s}, {s}\n",  .{ EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 }),
            .neq  => try writer.print("    setneq {s}, {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 }),
            .lt   => try writer.print("    setlt {s}, {s}, {s}\n",  .{ EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 }),
            .gt   => try writer.print("    setgt {s}, {s}, {s}\n",  .{ EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 }),
            .le   => try writer.print("    setle {s}, {s}, {s}\n",  .{ EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 }),
            .ge   => try writer.print("    setge {s}, {s}, {s}\n",  .{ EXPR_TEMP, EXPR_TEMP, EXPR_TEMP2 }),
            else  => try writer.print("    ; unsupported op\n", .{}),
        }
    }

    fn genTernary(self: *Codegen, tn: anytype, writer: anytype) !void {
        const else_lbl = self.newLabel();
        const end_lbl = self.newLabel();

        try self.genExpr(tn.cond, writer);
        try writer.print("    bnf {s}, _cm_L_{}\n", .{ EXPR_TEMP, else_lbl });
        try self.genExpr(tn.then_val, writer);
        try writer.print("    bn _cm_L_{}\n", .{end_lbl});
        try writer.print("_cm_L_{}:\n", .{else_lbl});
        try self.genExpr(tn.else_val, writer);
        try writer.print("_cm_L_{}:\n", .{end_lbl});
    }

    fn genCall(self: *Codegen, c: anytype, writer: anytype) !void {
        if (c.args.len > PARAM_REGS.len) {
            std.debug.print("error: too many arguments (max {})\n", .{PARAM_REGS.len});
            return CodegenError.UnsupportedExpr;
        }

        // Compute each argument and push onto stack
        for (c.args) |arg| {
            try self.genExpr(arg, writer);
            try writer.print("    push {s}\n", .{EXPR_TEMP});
        }

        // Pop args in reverse into param registers
        var i = c.args.len;
        while (i > 0) {
            i -= 1;
            try writer.print("    pop {s}\n", .{PARAM_REGS[i]});
        }

        // Resolve callee
        const callee_name = switch (c.callee.*) {
            .ident => |id| id.name,
            else => {
                std.debug.print("error: indirect function calls through expressions not supported\n", .{});
                return CodegenError.UnsupportedExpr;
            },
        };

        const ret_lbl = self.newLabel();
        try writer.print("    lea {s}, {s}, _cm_{s}\n", .{ CALL_PAGE, CALL_OFFSET, callee_name });
        try writer.print("    lea jrh, jr, _cm_L_{}\n", .{ret_lbl});
        try writer.print("    b {s}, {s}\n", .{ CALL_PAGE, CALL_OFFSET });
        try writer.print("_cm_L_{}:\n", .{ret_lbl});
        // Result from callee is in R0; move to EXPR_TEMP for chaining
        try writer.print("    mov {s}, r0\n", .{EXPR_TEMP});
    }

    fn genExtDeref(self: *Codegen, ed: anytype, writer: anytype) !void {
        try self.genExpr(ed.page_expr, writer);
        try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP2, EXPR_TEMP }); // r9 = page
        try self.genExpr(ed.addr_expr, writer); // r8 = addr (overwrites page in r8)
        // Now r9=page, r8=addr. Do extended load:
        // We need both in registers — use r9 for page, r8 for addr
        // Temporarily swap: r8 is addr (por), r9 is page (psr)
        try writer.print("    mov {s}, [{s}, {s}]\n", .{ EXPR_TEMP, EXPR_TEMP2, EXPR_TEMP });
    }

    fn genExtCall(self: *Codegen, ec: anytype, writer: anytype) !void {
        // Push args
        for (ec.args) |arg| {
            try self.genExpr(arg, writer);
            try writer.print("    push {s}\n", .{EXPR_TEMP});
        }
        var i = ec.args.len;
        while (i > 0) {
            i -= 1;
            try writer.print("    pop {s}\n", .{PARAM_REGS[i]});
        }

        // Load target address into CALL_PAGE:CALL_OFFSET
        try self.genExpr(ec.page_expr, writer);
        try writer.print("    mov {s}, {s}\n", .{ CALL_PAGE, EXPR_TEMP });
        try self.genExpr(ec.addr_expr, writer);
        try writer.print("    mov {s}, {s}\n", .{ CALL_OFFSET, EXPR_TEMP });

        const ret_lbl = self.newLabel();
        try writer.print("    lea jrh, jr, _cm_L_{}\n", .{ret_lbl});
        try writer.print("    b {s}, {s}\n", .{ CALL_PAGE, CALL_OFFSET });
        try writer.print("_cm_L_{}:\n", .{ret_lbl});
        try writer.print("    mov {s}, r0\n", .{EXPR_TEMP});
    }

    fn genIndex(self: *Codegen, idx: anytype, writer: anytype) !void {
        // Compute base address (page-0)
        switch (idx.base.*) {
            .ident => |id| {
                if (self.sema.globals.get(id.name)) |gi| {
                    // addr = gi.offset + index * elem_size
                    try self.genExpr(idx.idx, writer); // r8 = index
                    const elem_size: u16 = switch (gi.type_expr) {
                        .array => |arr| self.sema.typeSize(arr.elem.*),
                        .flex_array => |elem| self.sema.typeSize(elem.*),
                        else => 1,
                    };
                    if (elem_size != 1) {
                        try writer.print("    mov {s}, {}\n", .{ EXPR_TEMP2, elem_size });
                        try writer.print("    mul {s}, {s}\n", .{ EXPR_TEMP, EXPR_TEMP2 });
                    }
                    try writer.print("    mov {s}, 0x{X:0>4}\n", .{ EXPR_TEMP2, gi.offset });
                    try writer.print("    add {s}, {s}\n", .{ EXPR_TEMP2, EXPR_TEMP }); // addr in r9
                    try writer.print("    (byte) mov {s}, [{s}]\n", .{ EXPR_TEMP, EXPR_TEMP2 });
                } else {
                    try writer.print("    mov {s}, 0\n", .{EXPR_TEMP});
                }
            },
            else => {
                try writer.print("    mov {s}, 0\n", .{EXPR_TEMP});
            },
        }
    }

    fn genField(self: *Codegen, f: anytype, writer: anytype) !void {
        // struct field access — resolve the struct type and offset
        switch (f.base.*) {
            .ident => |id| {
                // Find the type of id to get the struct name
                var base_type: ?ast.TypeExpr = null;
                if (self.locals.get(id.name)) |li| base_type = li.type_expr;
                if (self.sema.globals.get(id.name)) |gi| base_type = gi.type_expr;

                if (base_type) |bt| {
                    if (bt == .named) {
                        if (self.sema.structField(bt.named, f.name)) |fl| {
                            // Load base address, add field offset
                            if (self.sema.globals.get(id.name)) |gi| {
                                const field_addr = gi.offset + fl.offset;
                                try writer.print("    mov {s}, 0x{X:0>4}\n", .{ EXPR_TEMP2, field_addr });
                                if (fl.type_expr.isByte()) {
                                    try writer.print("    (byte) mov {s}, [{s}]\n", .{ EXPR_TEMP, EXPR_TEMP2 });
                                } else {
                                    try writer.print("    mov {s}, [{s}]\n", .{ EXPR_TEMP, EXPR_TEMP2 });
                                }
                                return;
                            }
                        }
                    }
                }
            },
            else => {},
        }
        try writer.print("    mov {s}, 0\n", .{EXPR_TEMP});
    }

    // ─── Store to lvalue ───────────────────────────────────────────────────────

    fn genStore(self: *Codegen, lvalue: *const ast.Expr, src_reg: []const u8, writer: anytype) !void {
        switch (lvalue.*) {
            .ident => |id| {
                // Local variable store
                if (self.locals.get(id.name)) |local| {
                    try writer.print("    mov {s}, {s}\n", .{ local.reg, src_reg });
                    return;
                }
                // Global variable store
                if (self.sema.globals.get(id.name)) |gi| {
                    try writer.print("    mov {s}, 0x{X:0>4}\n", .{ EXPR_TEMP2, gi.offset });
                    if (gi.type_expr.isByte()) {
                        try writer.print("    (byte) mov [{s}], {s}\n", .{ EXPR_TEMP2, src_reg });
                    } else {
                        try writer.print("    mov [{s}], {s}\n", .{ EXPR_TEMP2, src_reg });
                    }
                    return;
                }
                std.debug.print("error: unknown identifier '{s}' in assignment\n", .{id.name});
                return CodegenError.UnknownSymbol;
            },
            .unary => |u| if (u.op == .deref) {
                // *ptr = value — page-0 store
                // src_reg has the value to store.
                // We need the address: evaluate u.operand
                // But u.operand evaluation would clobber EXPR_TEMP...
                // Save src_reg if it IS expr_temp
                if (std.mem.eql(u8, src_reg, EXPR_TEMP)) {
                    try writer.print("    push {s}\n", .{src_reg});
                    try self.genExpr(u.operand, writer); // r8 = ptr address
                    try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP2, EXPR_TEMP }); // r9 = ptr
                    try writer.print("    pop {s}\n", .{src_reg}); // restore value
                    try writer.print("    mov [{s}], {s}\n", .{ EXPR_TEMP2, src_reg });
                } else {
                    try self.genExpr(u.operand, writer);
                    try writer.print("    mov [{s}], {s}\n", .{ EXPR_TEMP, src_reg });
                }
                return;
            },
            .index => |idx| {
                // array[i] = value
                if (!std.mem.eql(u8, src_reg, EXPR_TEMP)) {
                    try writer.print("    mov {s}, {s}\n", .{ EXPR_TEMP, src_reg });
                }
                try writer.print("    push {s}\n", .{EXPR_TEMP}); // save value
                _ = idx;
                // compute address (same as genIndex but without final load)
                // simplified: just error for now
                try writer.print("    pop {s}\n", .{EXPR_TEMP});
                std.debug.print("error: array element assignment not fully implemented\n", .{});
                return CodegenError.UnsupportedExpr;
            },
            else => {
                std.debug.print("error: invalid left-hand side in assignment\n", .{});
                return CodegenError.InvalidLValue;
            },
        }
    }

    // ─── Extended pointer assignment: (psr, por) = &something ─────────────────

    fn genExtPtrAssign(self: *Codegen, page_lhs: *const ast.Expr, addr_lhs: *const ast.Expr,
        rhs: *const ast.Expr, writer: anytype) !void
    {
        // Get the page register and addr register from LHS identifiers
        const psr_reg = switch (page_lhs.*) {
            .ident => |id| (if (self.locals.get(id.name)) |l| l.reg else null),
            else => null,
        } orelse {
            std.debug.print("error: ext_ptr LHS must be simple identifiers\n", .{});
            return CodegenError.InvalidLValue;
        };
        const por_reg = switch (addr_lhs.*) {
            .ident => |id| (if (self.locals.get(id.name)) |l| l.reg else null),
            else => null,
        } orelse {
            std.debug.print("error: ext_ptr LHS must be simple identifiers\n", .{});
            return CodegenError.InvalidLValue;
        };

        // RHS: addr_of(ident) → gives (page, offset) of the global
        switch (rhs.*) {
            .unary => |u| if (u.op == .addr_of) {
                switch (u.operand.*) {
                    .ident => |id| {
                        if (self.sema.globals.get(id.name)) |gi| {
                            try writer.print("    mov {s}, {}\n", .{ psr_reg, gi.page });
                            try writer.print("    mov {s}, 0x{X:0>4}\n", .{ por_reg, gi.offset });
                            return;
                        }
                        std.debug.print("error: '{s}' is not a global variable\n", .{id.name});
                        return CodegenError.UnknownSymbol;
                    },
                    else => {},
                }
            },
            .string_lit => |sl| {
                if (self.sema.findStringLit(sl.raw)) |lit| {
                    try writer.print("    mov {s}, {}\n", .{ psr_reg, lit.page });
                    try writer.print("    mov {s}, 0x{X:0>4}\n", .{ por_reg, lit.offset });
                    return;
                }
            },
            else => {},
        }

        // Generic: evaluate RHS, then split page and addr
        // This doesn't work naturally for a pair — emit a warning
        std.debug.print("warning: ext_ptr assignment with non-addr-of RHS — may produce incorrect code\n", .{});
        try self.genExpr(rhs, writer);
        try writer.print("    mov {s}, 0\n", .{psr_reg});
        try writer.print("    mov {s}, {s}\n", .{ por_reg, EXPR_TEMP });
    }
};
