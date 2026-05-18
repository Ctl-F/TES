const std = @import("std");
const ast = @import("ast.zig");

pub const FieldLayout = struct {
    name: []const u8,
    type_expr: ast.TypeExpr,
    offset: u16,
};

pub const StructLayout = struct {
    fields: []FieldLayout,
    total_size: u16,
    alignment: u16,
    is_union: bool,
};

pub const FnSig = struct {
    params: []const ast.Param,
    return_type: ast.TypeExpr,
    is_inline: bool,
};

pub const GlobalInfo = struct {
    type_expr: ast.TypeExpr,
    page: u8,
    offset: u16,
    is_const: bool,
    init_value: ?i64,        // for simple scalar constants
    string_content: ?[]const u8, // decoded string for [*]u8 globals
    array_len: u32,          // length of string/array (including null)
};

pub const StringLiteral = struct {
    label: []const u8,
    page: u8,
    offset: u16,
    content: []const u8, // raw bytes including null terminator
    array_len: u32,
};

pub const SemaError = error{
    DuplicateSymbol,
    UnknownType,
    OutOfMemory,
};

// Data section constants
pub const DATA_PAGE: u8 = 0;
pub const DATA_START: u16 = 0x0400; // after 1KB IVT
pub const CODE_PAGE: u8 = 1;
pub const CODE_START: u16 = 0x0000;

pub const Sema = struct {
    gpa: std.mem.Allocator,
    structs: std.StringHashMapUnmanaged(StructLayout) = .{},
    fns: std.StringHashMapUnmanaged(FnSig) = .{},
    globals: std.StringHashMapUnmanaged(GlobalInfo) = .{},
    // string literals encountered (assigned to data section)
    string_lits: std.ArrayList(StringLiteral) = .empty,
    data_cursor: u16 = DATA_START,
    string_counter: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Sema {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Sema) void {
        self.structs.deinit(self.gpa);
        self.fns.deinit(self.gpa);
        self.globals.deinit(self.gpa);
        self.string_lits.deinit(self.gpa);
    }

    pub fn analyze(self: *Sema, file: *const ast.File) SemaError!void {
        // Pass 1: collect struct/union layouts
        for (file.decls) |*decl| {
            if (decl.* == .struct_decl) {
                const sd = &decl.struct_decl;
                const layout = try self.computeLayout(sd.fields, sd.is_union);
                if (self.structs.contains(sd.name)) {
                    std.debug.print("error: duplicate struct/union '{s}'\n", .{sd.name});
                    return SemaError.DuplicateSymbol;
                }
                try self.structs.put(self.gpa, sd.name, layout);
            }
        }

        // Pass 2: collect function signatures
        for (file.decls) |*decl| {
            if (decl.* == .fn_decl) {
                const fd = &decl.fn_decl;
                if (self.fns.contains(fd.name)) {
                    std.debug.print("error: duplicate function '{s}'\n", .{fd.name});
                    return SemaError.DuplicateSymbol;
                }
                try self.fns.put(self.gpa, fd.name, .{
                    .params = fd.params,
                    .return_type = fd.return_type,
                    .is_inline = fd.is_inline,
                });
            }
        }

        // Pass 3: collect global variables, compute their data-section offsets
        for (file.decls) |*decl| {
            if (decl.* == .global_var) {
                try self.registerGlobal(&decl.global_var);
            }
        }

        // Pass 4: scan function bodies for inline string literals
        for (file.decls) |*decl| {
            if (decl.* == .fn_decl) {
                for (decl.fn_decl.body) |s| {
                    try self.scanStmtForStrings(s);
                }
            }
        }
    }

    fn registerGlobal(self: *Sema, gv: *const ast.GlobalVar) SemaError!void {
        if (self.globals.contains(gv.name)) {
            std.debug.print("error: duplicate global '{s}'\n", .{gv.name});
            return SemaError.DuplicateSymbol;
        }

        const size = self.typeSize(gv.type_expr);
        const align_ = self.typeAlignment(gv.type_expr);

        // Align data cursor
        self.data_cursor = alignUp(self.data_cursor, align_);
        const offset = self.data_cursor;

        var init_val: ?i64 = null;
        var string_content: ?[]const u8 = null;
        var array_len: u32 = 0;

        if (gv.init) |init_expr| {
            switch (init_expr.*) {
                .int_lit => |il| init_val = il.value,
                .string_lit => |sl| {
                    const decoded = decodeStringLit(self.gpa, sl.raw) catch return SemaError.OutOfMemory;
                    string_content = decoded;
                    array_len = @intCast(decoded.len); // includes null
                },
                else => {},
            }
        }

        // For flex_array with string content, the size is the string length
        const actual_size: u16 = switch (gv.type_expr) {
            .flex_array => @intCast(if (string_content) |sc| sc.len else 0),
            else => size,
        };

        try self.globals.put(self.gpa, gv.name, .{
            .type_expr = gv.type_expr,
            .page = DATA_PAGE,
            .offset = offset,
            .is_const = gv.is_const,
            .init_value = init_val,
            .string_content = string_content,
            .array_len = array_len,
        });

        self.data_cursor += if (actual_size > 0) actual_size else 2;
    }

    fn scanStmtForStrings(self: *Sema, s: *const ast.Stmt) SemaError!void {
        switch (s.*) {
            .var_decl => |vd| if (vd.init) |e| try self.scanExprForStrings(e),
            .const_decl => |cd| try self.scanExprForStrings(cd.value),
            .expr_stmt => |e| try self.scanExprForStrings(e),
            .block => |stmts| for (stmts) |s2| try self.scanStmtForStrings(s2),
            .if_stmt => |is| {
                try self.scanExprForStrings(is.cond);
                try self.scanStmtForStrings(is.then_stmt);
                if (is.else_stmt) |es| try self.scanStmtForStrings(es);
            },
            .while_stmt => |ws| {
                try self.scanExprForStrings(ws.cond);
                try self.scanStmtForStrings(ws.body);
            },
            .do_while => |dw| {
                try self.scanStmtForStrings(dw.body);
                try self.scanExprForStrings(dw.cond);
            },
            .for_stmt => |fs| {
                if (fs.init) |i| try self.scanStmtForStrings(i);
                if (fs.cond) |c| try self.scanExprForStrings(c);
                if (fs.update) |u| try self.scanExprForStrings(u);
                try self.scanStmtForStrings(fs.body);
            },
            .return_stmt => |rs| if (rs.value) |e| try self.scanExprForStrings(e),
            else => {},
        }
    }

    fn scanExprForStrings(self: *Sema, e: *const ast.Expr) SemaError!void {
        switch (e.*) {
            .string_lit => |sl| try self.registerStringLit(sl.raw),
            .call => |c| {
                try self.scanExprForStrings(c.callee);
                for (c.args) |a| try self.scanExprForStrings(a);
            },
            .binary => |b| {
                try self.scanExprForStrings(b.lhs);
                try self.scanExprForStrings(b.rhs);
            },
            .unary => |u| try self.scanExprForStrings(u.operand),
            .index => |i| {
                try self.scanExprForStrings(i.base);
                try self.scanExprForStrings(i.idx);
            },
            .field => |f| try self.scanExprForStrings(f.base),
            .ternary => |tn| {
                try self.scanExprForStrings(tn.cond);
                try self.scanExprForStrings(tn.then_val);
                try self.scanExprForStrings(tn.else_val);
            },
            else => {},
        }
    }

    fn registerStringLit(self: *Sema, raw: []const u8) SemaError!void {
        // Check if already registered
        for (self.string_lits.items) |*sl| {
            if (std.mem.eql(u8, sl.content, raw)) return;
        }
        const content = decodeStringLit(self.gpa, raw) catch return SemaError.OutOfMemory;
        const label = std.fmt.allocPrint(self.gpa, "_cm_str_{}", .{self.string_counter}) catch
            return SemaError.OutOfMemory;
        self.string_counter += 1;

        // Align to 1 (strings are byte arrays)
        const offset = self.data_cursor;
        self.data_cursor += @intCast(content.len);

        try self.string_lits.append(self.gpa, .{
            .label = label,
            .page = DATA_PAGE,
            .offset = offset,
            .content = content,
            .array_len = @intCast(content.len),
        });
    }

    pub fn findStringLit(self: *const Sema, raw: []const u8) ?*const StringLiteral {
        for (self.string_lits.items) |*sl| {
            if (std.mem.eql(u8, sl.content, raw)) return sl;
        }
        return null;
    }

    fn computeLayout(self: *Sema, fields: []const ast.StructField, is_union: bool) SemaError!StructLayout {
        var field_layouts: std.ArrayList(FieldLayout) = .empty;
        var cursor: u16 = 0;
        var max_align: u16 = 1;

        for (fields) |f| {
            const fsz = self.typeSize(f.type_expr);
            const fa = self.typeAlignment(f.type_expr);
            if (fa > max_align) max_align = fa;

            if (!is_union) {
                cursor = alignUp(cursor, fa);
            }
            try field_layouts.append(self.gpa, .{
                .name = f.name,
                .type_expr = f.type_expr,
                .offset = if (is_union) 0 else cursor,
            });
            if (!is_union) cursor += fsz;
        }

        const raw_size: u16 = if (is_union) blk: {
            var mx: u16 = 0;
            for (fields) |f| {
                const s = self.typeSize(f.type_expr);
                if (s > mx) mx = s;
            }
            break :blk mx;
        } else cursor;

        const total = alignUp(raw_size, max_align);
        return .{
            .fields = try field_layouts.toOwnedSlice(self.gpa),
            .total_size = total,
            .alignment = max_align,
            .is_union = is_union,
        };
    }

    pub fn typeSize(self: *const Sema, te: ast.TypeExpr) u16 {
        return switch (te) {
            .void => 0,
            .u8, .i8 => 1,
            .u16, .i16, .u8_vec2, .i8_vec2 => 2,
            .array => |a| @intCast(@as(u32, a.size) * self.typeSize(a.elem.*)),
            .flex_array => 0, // size not stored in variable
            .named => |n| if (self.structs.get(n)) |sl| sl.total_size else 2,
        };
    }

    pub fn typeAlignment(self: *const Sema, te: ast.TypeExpr) u16 {
        return switch (te) {
            .void => 1,
            .u8, .i8 => 1,
            .u16, .i16, .u8_vec2, .i8_vec2 => 2,
            .array => |a| self.typeAlignment(a.elem.*),
            .flex_array => 1,
            .named => |n| if (self.structs.get(n)) |sl| sl.alignment else 2,
        };
    }

    pub fn structField(self: *const Sema, struct_name: []const u8, field_name: []const u8) ?FieldLayout {
        const layout = self.structs.get(struct_name) orelse return null;
        for (layout.fields) |fl| {
            if (std.mem.eql(u8, fl.name, field_name)) return fl;
        }
        return null;
    }
};

fn alignUp(val: u16, alignment: u16) u16 {
    if (alignment <= 1) return val;
    return (val + alignment - 1) & ~(alignment - 1);
}

/// Decode a string literal token (including surrounding quotes) to bytes with null terminator.
pub fn decodeStringLit(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // raw includes leading and trailing "
    const inner = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        if (ch == '\\' and i + 1 < inner.len) {
            i += 1;
            const esc = switch (inner[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '0' => @as(u8, 0),
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                else => inner[i],
            };
            try buf.append(gpa, esc);
        } else {
            try buf.append(gpa, ch);
        }
    }
    try buf.append(gpa, 0); // null terminator
    return buf.toOwnedSlice(gpa);
}
