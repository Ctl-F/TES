const std = @import("std");
pub const Loc = @import("lexer.zig").Loc;

pub const TypeExpr = union(enum) {
    void,
    u8, u16, i8, i16, u8_vec2, i8_vec2,
    array: struct { size: u32, elem: *TypeExpr },
    flex_array: *TypeExpr, // [*]type — comptime-known length
    named: []const u8,

    pub fn isSigned(self: TypeExpr) bool {
        return switch (self) {
            .i8, .i16, .i8_vec2 => true,
            else => false,
        };
    }

    pub fn isByte(self: TypeExpr) bool {
        return switch (self) {
            .u8, .i8 => true,
            else => false,
        };
    }

    pub fn format(self: TypeExpr, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
        switch (self) {
            .void => try w.writeAll("void"),
            .u8 => try w.writeAll("u8"),
            .u16 => try w.writeAll("u16"),
            .i8 => try w.writeAll("i8"),
            .i16 => try w.writeAll("i16"),
            .u8_vec2 => try w.writeAll("u8_vec2"),
            .i8_vec2 => try w.writeAll("i8_vec2"),
            .array => |a| try w.print("[{}]{}", .{ a.size, a.elem.* }),
            .flex_array => |e| try w.print("[*]{}", .{e.*}),
            .named => |n| try w.writeAll(n),
        }
    }
};

pub const BinOp = enum {
    add, sub, mul, div, mod,
    band, bor, bxor, shl, shr,
    land, lor,
    eq, neq, lt, gt, le, ge,
    assign,
    add_assign, sub_assign, mul_assign, div_assign, mod_assign,
    band_assign, bor_assign, bxor_assign, shl_assign, shr_assign,

    pub fn isAssign(self: BinOp) bool {
        return switch (self) {
            .assign, .add_assign, .sub_assign, .mul_assign,
            .div_assign, .mod_assign, .band_assign, .bor_assign,
            .bxor_assign, .shl_assign, .shr_assign => true,
            else => false,
        };
    }

    pub fn baseOp(self: BinOp) ?BinOp {
        return switch (self) {
            .add_assign => .add,
            .sub_assign => .sub,
            .mul_assign => .mul,
            .div_assign => .div,
            .mod_assign => .mod,
            .band_assign => .band,
            .bor_assign => .bor,
            .bxor_assign => .bxor,
            .shl_assign => .shl,
            .shr_assign => .shr,
            else => null,
        };
    }
};

pub const UnOp = enum {
    neg, bnot, lnot, addr_of, deref,
    pre_inc, pre_dec, post_inc, post_dec,
};

pub const Expr = union(enum) {
    int_lit: struct { value: i64, loc: Loc },
    string_lit: struct { raw: []const u8, loc: Loc }, // includes the surrounding quotes
    undefined_val: Loc,
    ident: struct { name: []const u8, loc: Loc },
    field: struct { base: *Expr, name: []const u8, loc: Loc },
    dot_len: struct { base: *Expr, loc: Loc },
    index: struct { base: *Expr, idx: *Expr, loc: Loc },
    call: struct { callee: *Expr, args: []*Expr, loc: Loc },
    unary: struct { op: UnOp, operand: *Expr, loc: Loc },
    binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr, loc: Loc },
    ternary: struct { cond: *Expr, then_val: *Expr, else_val: *Expr, loc: Loc },
    ext_ptr: struct { page_expr: *Expr, addr_expr: *Expr, loc: Loc }, // (page, addr) pair
    ext_deref: struct { page_expr: *Expr, addr_expr: *Expr, loc: Loc }, // *(page, addr)
    ext_call: struct { page_expr: *Expr, addr_expr: *Expr, args: []*Expr, loc: Loc },

    pub fn getLoc(self: *const Expr) Loc {
        return switch (self.*) {
            .int_lit => |e| e.loc,
            .string_lit => |e| e.loc,
            .undefined_val => |l| l,
            .ident => |e| e.loc,
            .field => |e| e.loc,
            .dot_len => |e| e.loc,
            .index => |e| e.loc,
            .call => |e| e.loc,
            .unary => |e| e.loc,
            .binary => |e| e.loc,
            .ternary => |e| e.loc,
            .ext_ptr => |e| e.loc,
            .ext_deref => |e| e.loc,
            .ext_call => |e| e.loc,
        };
    }
};

pub const Stmt = union(enum) {
    var_decl: VarDecl,
    const_decl: ConstDecl,
    expr_stmt: *Expr,
    block: []*Stmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    do_while: DoWhileStmt,
    for_stmt: ForStmt,
    inline_for: InlineForStmt,
    return_stmt: ReturnStmt,
    asm_block: AsmBlock,
    break_stmt: Loc,
    continue_stmt: Loc,
};

pub const VarDecl = struct {
    type_expr: TypeExpr,
    name: []const u8,
    reg_hint: ?[]const u8,
    init: ?*Expr,
    loc: Loc,
};

pub const ConstDecl = struct {
    name: []const u8,
    value: *Expr,
    loc: Loc,
};

pub const IfStmt = struct {
    cond: *Expr,
    then_stmt: *Stmt,
    else_stmt: ?*Stmt,
    loc: Loc,
};

pub const WhileStmt = struct {
    cond: *Expr,
    body: *Stmt,
    loc: Loc,
};

pub const DoWhileStmt = struct {
    body: *Stmt,
    cond: *Expr,
    loc: Loc,
};

pub const ForStmt = struct {
    init: ?*Stmt,
    cond: ?*Expr,
    update: ?*Expr,
    body: *Stmt,
    loc: Loc,
};

pub const InlineForStmt = struct {
    iter_type: TypeExpr,
    iter_name: []const u8,
    start: *Expr,
    end: *Expr,
    body: *Stmt,
    loc: Loc,
};

pub const ReturnStmt = struct {
    value: ?*Expr,
    loc: Loc,
};

pub const AsmBlock = struct {
    lines: [][]const u8,
    loc: Loc,
};

pub const Param = struct {
    name: []const u8,
    type_expr: TypeExpr,
    reg_hint: ?[]const u8,
    loc: Loc,
};

pub const FnDecl = struct {
    name: []const u8,
    params: []Param,
    return_type: TypeExpr,
    body: []*Stmt,
    is_inline: bool,
    loc: Loc,
};

pub const StructField = struct {
    name: []const u8,
    type_expr: TypeExpr,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []StructField,
    is_union: bool,
    loc: Loc,
};

pub const GlobalVar = struct {
    name: []const u8,
    type_expr: TypeExpr,
    init: ?*Expr,
    is_const: bool,
    loc: Loc,
};

pub const Decl = union(enum) {
    fn_decl: FnDecl,
    struct_decl: StructDecl,
    global_var: GlobalVar,
};

pub const File = struct {
    name: []const u8,
    decls: []Decl,
};
