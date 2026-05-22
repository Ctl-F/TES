const std = @import("std");

pub const PrimType = enum {
    u8, u16, i8, i16,
    Struct,

    pub fn size(self: @This()) u16 {
        return switch (self) {
            .u8, .i8  => 1,
            .u16, .i16 => 2,
            .Struct    => unreachable,
        };
    }

    pub fn alignment(self: @This()) u16 {
        return switch (self) {
            .u8, .i8   => 1,
            .u16, .i16 => 2,
            .Struct    => unreachable,
        };
    }

    pub fn fromStr(s: []const u8) ?@This() {
        if (std.mem.eql(u8, s, "u8"))  return .u8;
        if (std.mem.eql(u8, s, "u16")) return .u16;
        if (std.mem.eql(u8, s, "i8"))  return .i8;
        if (std.mem.eql(u8, s, "i16")) return .i16;
        return null;
    }
};

pub const FieldDef = struct {
    name: []const u8,       // heap-allocated
    prim: PrimType,
    struct_name: ?[]const u8, // heap-allocated if set
    offset: u16,
    size: u16,  // total bytes = element_size * count
    count: u16 = 1,
};

pub const StructDef = struct {
    name: []const u8,       // heap-allocated, owned by structs map
    fields: std.ArrayList(FieldDef),
    total_size: u16,
    alignment: u16 = 1,

    pub fn findField(self: *const @This(), name: []const u8) ?*const FieldDef {
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

pub const DataSymbol = struct {
    page: u8,
    offset: u16,
    size: u16,
    prim: PrimType,
    struct_name: ?[]const u8, // heap-allocated if set
    struct_def: ?*StructDef,
};

pub const Symbol = union(enum) {
    Label: u32,     // instruction index
    Data: DataSymbol,
};

pub const SymbolError = error{
    DuplicateSymbol,
    UndefinedSymbol,
    UndefinedStruct,
    FieldNotFound,
    TypeMismatch,
    InvalidType,
    OutOfMemory,
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMapUnmanaged(Symbol),
    structs: std.StringHashMapUnmanaged(StructDef),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .symbols = .{},
            .structs = .{},
        };
    }

    pub fn deinit(self: *@This()) void {
        // Free struct fields
        var sit = self.structs.valueIterator();
        while (sit.next()) |sd| {
            for (sd.fields.items) |f| {
                self.allocator.free(f.name);
                if (f.struct_name) |sn| self.allocator.free(sn);
            }
            sd.fields.deinit(self.allocator);
            self.allocator.free(sd.name);
        }
        self.structs.deinit(self.allocator);

        // Free symbol keys and owned data fields
        var sym_it = self.symbols.iterator();
        while (sym_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .Data => |d| { if (d.struct_name) |sn| self.allocator.free(sn); },
                .Label => {},
            }
        }
        self.symbols.deinit(self.allocator);
    }

    pub fn defineStruct(self: *@This(), sd: StructDef) SymbolError!void {
        if (self.structs.contains(sd.name)) return SymbolError.DuplicateSymbol;
        const key = self.allocator.dupe(u8, sd.name) catch return SymbolError.OutOfMemory;
        var owned = sd;
        owned.name = key;
        self.structs.put(self.allocator, key, owned) catch return SymbolError.OutOfMemory;
    }

    pub fn defineLabel(self: *@This(), name: []const u8, instr_idx: u32) SymbolError!void {
        if (self.symbols.contains(name)) return SymbolError.DuplicateSymbol;
        const key = self.allocator.dupe(u8, name) catch return SymbolError.OutOfMemory;
        self.symbols.put(self.allocator, key, Symbol{ .Label = instr_idx }) catch return SymbolError.OutOfMemory;
    }

    pub fn defineData(self: *@This(), name: []const u8, ds: DataSymbol) SymbolError!void {
        if (self.symbols.contains(name)) return SymbolError.DuplicateSymbol;
        const key = self.allocator.dupe(u8, name) catch return SymbolError.OutOfMemory;
        errdefer self.allocator.free(key);
        var owned = ds;
        if (ds.struct_name) |sn| {
            owned.struct_name = self.allocator.dupe(u8, sn) catch return SymbolError.OutOfMemory;
        }
        self.symbols.put(self.allocator, key, Symbol{ .Data = owned }) catch return SymbolError.OutOfMemory;
    }

    pub fn getSymbol(self: *@This(), name: []const u8) ?*Symbol {
        return self.symbols.getPtr(name);
    }

    pub fn getStruct(self: *@This(), name: []const u8) ?*StructDef {
        return self.structs.getPtr(name);
    }

    pub fn resolveStructRefs(self: *@This()) SymbolError!void {
        var it = self.symbols.valueIterator();
        while (it.next()) |sym| {
            switch (sym.*) {
                .Data => |*d| {
                    if (d.struct_name) |sn| {
                        d.struct_def = self.structs.getPtr(sn);
                        if (d.struct_def == null) {
                            std.debug.print("Error: undefined struct type '{s}'\n", .{sn});
                            return SymbolError.UndefinedStruct;
                        }
                    }
                },
                .Label => {},
            }
        }
    }

    /// Fix up struct fields that were parsed before their type struct was defined.
    /// Iterates to a fixpoint so chains (A->B->C) are handled.
    pub fn resolveForwardStructRefs(self: *@This()) void {
        var changed = true;
        while (changed) {
            changed = false;
            var it = self.structs.valueIterator();
            while (it.next()) |sd| {
                var needs_layout = false;
                for (sd.fields.items) |*f| {
                    if (f.prim == .Struct and f.size == 0) {
                        if (f.struct_name) |sn| {
                            if (self.structs.getPtr(sn)) |ref| {
                                if (ref.total_size > 0) {
                                    f.size = ref.total_size * f.count;
                                    needs_layout = true;
                                    changed = true;
                                }
                            }
                        }
                    }
                }
                if (needs_layout) {
                    var off: u16 = 0;
                    var max_align: u16 = 1;
                    for (sd.fields.items) |*f| {
                        const falign: u16 = switch (f.prim) {
                            .Struct => if (f.struct_name) |sn|
                                (if (self.structs.getPtr(sn)) |ref| ref.alignment else 1)
                            else 1,
                            else => f.prim.alignment(),
                        };
                        off = @intCast(((@as(u32, off) + falign - 1) / falign) * falign);
                        f.offset = off;
                        off += f.size;
                        if (falign > max_align) max_align = falign;
                    }
                    sd.total_size = @intCast(((@as(u32, off) + max_align - 1) / max_align) * max_align);
                    sd.alignment = max_align;
                }
            }
        }
    }

    /// Resolve Symbol.field.subfield to packed (page<<16)|offset u32.
    /// For labels, returns the instruction index directly.
    pub fn resolveAddress(self: *@This(), name: []const u8) SymbolError!u32 {
        var parts = std.mem.splitScalar(u8, name, '.');
        const base_name = parts.next() orelse return SymbolError.UndefinedSymbol;
        const sym = self.symbols.get(base_name) orelse {
            std.debug.print("Error: undefined symbol '{s}'\n", .{base_name});
            return SymbolError.UndefinedSymbol;
        };
        switch (sym) {
            .Label => |idx| return idx,
            .Data => |d| {
                var offset = d.offset;
                var cur_struct: ?*StructDef = d.struct_def;
                while (parts.next()) |field_name| {
                    const sd = cur_struct orelse {
                        std.debug.print("Error: '{s}' is not a struct\n", .{base_name});
                        return SymbolError.TypeMismatch;
                    };
                    const field = sd.findField(field_name) orelse {
                        std.debug.print("Error: struct '{s}' has no field '{s}'\n", .{ sd.name, field_name });
                        return SymbolError.FieldNotFound;
                    };
                    offset +%= field.offset;
                    cur_struct = if (field.prim == .Struct and field.struct_name != null)
                        self.structs.getPtr(field.struct_name.?)
                    else
                        null;
                }
                return (@as(u32, d.page) << 16) | offset;
            },
        }
    }

    /// Resolve StructType.field to a byte offset within the struct (not an absolute address).
    /// Used for [ra, StructName.field rb] memory operands.
    pub fn resolveFieldOffset(self: *@This(), name: []const u8) SymbolError!u16 {
        var parts = std.mem.splitScalar(u8, name, '.');
        const base_name = parts.next() orelse return SymbolError.UndefinedSymbol;
        // Try as a struct type name first
        if (self.structs.getPtr(base_name)) |sd| {
            var offset: u16 = 0;
            var cur_struct: ?*StructDef = sd;
            while (parts.next()) |field_name| {
                const s = cur_struct orelse return SymbolError.TypeMismatch;
                const field = s.findField(field_name) orelse return SymbolError.FieldNotFound;
                offset +%= field.offset;
                cur_struct = if (field.prim == .Struct and field.struct_name != null)
                    self.structs.getPtr(field.struct_name.?)
                else
                    null;
            }
            return offset;
        }
        // Fall back: data instance — return field offset relative to instance base
        const sym = self.symbols.get(base_name) orelse return SymbolError.UndefinedSymbol;
        switch (sym) {
            .Label => return SymbolError.TypeMismatch,
            .Data => |d| {
                var offset: u16 = 0;
                var cur_struct: ?*StructDef = d.struct_def;
                while (parts.next()) |field_name| {
                    const s = cur_struct orelse return SymbolError.TypeMismatch;
                    const field = s.findField(field_name) orelse return SymbolError.FieldNotFound;
                    offset +%= field.offset;
                    cur_struct = if (field.prim == .Struct and field.struct_name != null)
                        self.structs.getPtr(field.struct_name.?)
                    else
                        null;
                }
                return offset;
            },
        }
    }

    /// Returns the byte size of one element of the field at the end of a dotted
    /// path, i.e. field.size / field.count. Used to compute [N] array offsets.
    pub fn resolveFieldElemSize(self: *@This(), name: []const u8) SymbolError!u16 {
        var parts = std.mem.splitScalar(u8, name, '.');
        const base_name = parts.next() orelse return SymbolError.UndefinedSymbol;

        var cur_struct: ?*StructDef = if (self.structs.getPtr(base_name)) |sd| sd else blk: {
            const sym = self.symbols.get(base_name) orelse return SymbolError.UndefinedSymbol;
            break :blk switch (sym) {
                .Data  => |d| d.struct_def,
                .Label => return SymbolError.TypeMismatch,
            };
        };

        var last_field: ?*const FieldDef = null;
        while (parts.next()) |field_name| {
            const sd = cur_struct orelse return SymbolError.TypeMismatch;
            const field = sd.findField(field_name) orelse return SymbolError.FieldNotFound;
            last_field = field;
            cur_struct = if (field.prim == .Struct and field.struct_name != null)
                self.structs.getPtr(field.struct_name.?)
            else
                null;
        }

        const f = last_field orelse return SymbolError.FieldNotFound;
        if (f.count == 0) return SymbolError.InvalidType;
        return f.size / f.count;
    }

    pub fn resolveLabel(self: *@This(), name: []const u8) SymbolError!u32 {
        const sym = self.symbols.get(name) orelse return SymbolError.UndefinedSymbol;
        return switch (sym) {
            .Label => |idx| idx,
            .Data  => SymbolError.TypeMismatch,
        };
    }
};
