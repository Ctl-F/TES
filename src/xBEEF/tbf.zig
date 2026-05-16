const std = @import("std");
const Io = std.Io;

pub const TBFError = error{
    OutOfMemory,
    TooManyPages,
    TooManySymbols,
};

pub const DataPage = struct {
    page: u8,
    offset: u16,
    data: []const u8, // heap-allocated, owned by TBFWriter
};

pub const ExtensionEntry = struct {
    id: u16,
    enabled: bool,
};

pub const DebugSymbol = struct {
    address: u32,
    name: []const u8, // not owned — points into source or symbol table
};

pub const TBFWriter = struct {
    allocator: std.mem.Allocator,
    instructions:  std.ArrayList(u32),
    data_pages:    std.ArrayList(DataPage),
    extensions:    std.ArrayList(ExtensionEntry),
    debug_symbols: std.ArrayList(DebugSymbol),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator    = allocator,
            .instructions  = .empty,
            .data_pages    = .empty,
            .extensions    = .empty,
            .debug_symbols = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.data_pages.items) |dp| self.allocator.free(dp.data);
        self.instructions.deinit(self.allocator);
        self.data_pages.deinit(self.allocator);
        self.extensions.deinit(self.allocator);
        self.debug_symbols.deinit(self.allocator);
    }

    pub fn addInstruction(self: *@This(), word: u32) TBFError!void {
        self.instructions.append(self.allocator, word) catch return TBFError.OutOfMemory;
    }

    pub fn addDataPage(self: *@This(), page: u8, offset: u16, data: []const u8) TBFError!void {
        const owned = self.allocator.dupe(u8, data) catch return TBFError.OutOfMemory;
        self.data_pages.append(self.allocator, .{ .page = page, .offset = offset, .data = owned }) catch {
            self.allocator.free(owned);
            return TBFError.OutOfMemory;
        };
    }

    pub fn addExtension(self: *@This(), id: u16, enabled: bool) TBFError!void {
        self.extensions.append(self.allocator, .{ .id = id, .enabled = enabled }) catch return TBFError.OutOfMemory;
    }

    pub fn addDebugSymbol(self: *@This(), address: u32, name: []const u8) TBFError!void {
        self.debug_symbols.append(self.allocator, .{ .address = address, .name = name }) catch return TBFError.OutOfMemory;
    }

    /// Write TBF binary to any writer.
    /// Format:
    ///   "TESB"                         magic (4 bytes)
    ///   InstructionCount: u32 LE
    ///   Instructions:     [N]u32 LE
    ///   DefaultPageCount: u8
    ///   For each page:
    ///     Page:   u8
    ///     Offset: u16 LE
    ///     Size:   u16 LE
    ///     Data:   [Size]u8
    ///   ExtensionCount: u16 LE
    ///   For each:
    ///     ExtensionID: u16 LE
    ///     Enable:      u8
    ///   SymbolCount: u32 LE
    ///   For each:
    ///     address: u32 LE
    ///     len:     u16 LE
    ///     symbol:  [len]u8
    pub fn write(self: *@This(), writer: *Io.Writer) !void {
        try writer.writeAll("TESB");

        try writer.writeInt(u32, @intCast(self.instructions.items.len), .little);
        for (self.instructions.items) |w| try writer.writeInt(u32, w, .little);

        if (self.data_pages.items.len > 255) return TBFError.TooManyPages;
        try writer.writeInt(u8, @intCast(self.data_pages.items.len), .little);
        for (self.data_pages.items) |dp| {
            try writer.writeInt(u8,  dp.page,              .little);
            try writer.writeInt(u16, dp.offset,            .little);
            try writer.writeInt(u16, @intCast(dp.data.len),.little);
            try writer.writeAll(dp.data);
        }

        try writer.writeInt(u16, @intCast(self.extensions.items.len), .little);
        for (self.extensions.items) |ext| {
            try writer.writeInt(u16, ext.id,                        .little);
            try writer.writeInt(u8,  if (ext.enabled) @as(u8,1) else 0, .little);
        }

        try writer.writeInt(u32, @intCast(self.debug_symbols.items.len), .little);
        for (self.debug_symbols.items) |sym| {
            if (sym.name.len > 0xFFFF) return TBFError.TooManySymbols;
            try writer.writeInt(u32, sym.address,            .little);
            try writer.writeInt(u16, @intCast(sym.name.len), .little);
            try writer.writeAll(sym.name);
        }
    }

    pub fn writeFile(self: *@This(), io: Io, path: []const u8) !void {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try self.write(&fw.interface);
        try fw.interface.flush();
    }
};
