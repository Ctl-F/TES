const std = @import("std");
const tes_core = @import("tes_core");
const builtin = @import("builtin");
const native = @import("native");

const SystemExtension = @import("extensions/System.zig");
const GraphicsExtension = @import("extensions/Graphics.zig");
const InputExtension = @import("extensions/Input.zig");

var mainIO: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    mainIO = init.io;

    const sysExt = SystemExtension.extension(true);
    const gfxExt = GraphicsExtension.extension(true);
    const ioExt = InputExtension.extension(true);

    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();

    // ignore the application path argument
    _ = args.next();

    const binaryPath = args.next() orelse {
        std.debug.print("Expected input binary file\n", .{});
        return;
    };

    const blob = try readFile(init.io, allocator, binaryPath);
    defer allocator.free(blob);
    var binary = try Binary.parseBinary(blob, allocator);
    defer binary.deinit();

    var vm: tes_core.vm.TESVM = try tes_core.vm.TESVM.defaultWithPageAllocator(init.io, frameBarrier);
    defer vm.deinit();

    vm.instructionBuffer = binary.instructions.items;
    try mapDefaultPages(&vm, binary.pages);

    try vm.extensions.put(SystemExtension.pool, sysExt);
    try vm.extensions.put(GraphicsExtension.pool, gfxExt);
    try vm.extensions.put(InputExtension.pool, ioExt);

    {
        var iter = vm.extensions.iterator();
        while (iter.next()) |ext| {
            std.debug.print("Extension: {s}\n", .{ext.value_ptr.getFriendlyName()});
        }
    }

    if (!native.SDL_Init(native.SDL_INIT_VIDEO)) {
        return error.SDL_Init;
    }
    defer native.SDL_Quit();

    try vm.run();

    std.debug.print("Exited(0)\n", .{});
}

pub fn frameBarrier(vm: *tes_core.vm.TESVM) anyerror!void {
    try InputExtension.IOPoll(vm);
    try GraphicsExtension.presentGFX(vm);
}

// Exported for web
// export fn wasm_main() void {
//     main() catch {};
// }

test "native-tes basic test" {
    try std.testing.expect(true);
}

fn mapDefaultPages(vm: *tes_core.vm.TESVM, pages: std.ArrayList(PageDefinition)) !void {
    for (pages.items) |page| {
        var mmu = &vm.mmu;

        var pageBuffer = mmu.getPage(page.page) orelse try mmu.requestPage(page.page, null);

        const start = page.offset;
        const end = start + page.blob.len;

        if (pageBuffer.len < end) {
            return error.PageTooSmall;
        }

        const slice = pageBuffer[start..end];
        @memcpy(slice, page.blob);
    }
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();

    return try cwd.readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
}

fn earlyStop() !void {
    return error.EarlyStop;
}

const DebugSymbol = struct {
    address: u32,
    symbol: []const u8,
};

const ExtensionDefinition = struct {
    id: u16,
    enable: u8,
};

const PageDefinition = struct {
    page: u8,
    offset: u16,
    blob: []const u8,
};

const Binary = struct {
    instructions: std.ArrayList(tes_core.vm.Instruction),
    pages: std.ArrayList(PageDefinition),
    extensions: std.ArrayList(ExtensionDefinition),
    symbols: std.ArrayList(DebugSymbol),
    allocator: std.mem.Allocator,

    const Stream = struct {
        blob: []const u8,
        cursor: usize,

        fn readNext(this: *@This(), comptime T: type) !T {
            if (this.cursor + @sizeOf(T) > this.blob.len) return error.MalformedBinary;
            defer this.cursor += @sizeOf(T);
            return std.mem.readInt(T, this.blob[this.cursor..][0..@sizeOf(T)], .little);
        }

        fn grab(this: *@This(), count: usize) ![]const u8 {
            if (this.cursor + count > this.blob.len) return error.MalformedBinary;
            defer this.cursor += count;
            return this.blob[this.cursor..][0..count];
        }
    };

    pub fn deinit(this: *@This()) void {
        this.instructions.deinit(this.allocator);
        this.pages.deinit(this.allocator);
        this.extensions.deinit(this.allocator);
        this.symbols.deinit(this.allocator);
    }

    pub fn parseBinary(blob: []const u8, allocator: std.mem.Allocator) !@This() {
        if (blob.len < 8) return error.MalformedBinary;

        var instructions = std.ArrayList(tes_core.vm.Instruction).empty;
        var pages = std.ArrayList(PageDefinition).empty;
        var extensions = std.ArrayList(ExtensionDefinition).empty;
        var symbols = std.ArrayList(DebugSymbol).empty;

        if (!std.mem.eql(u8, blob[0..4], "TESB")) {
            return error.MalformedBinary;
        }

        var stream = Stream{
            .blob = blob,
            .cursor = 4,
        };

        const instructionCount = try stream.readNext(u32);
        try instructions.ensureTotalCapacity(allocator, instructionCount);
        errdefer instructions.deinit(allocator);

        for (0..instructionCount) |_| {
            const instr = try stream.readNext(u32);

            const instruction: tes_core.vm.Instruction = @bitCast(instr);
            instructions.appendAssumeCapacity(instruction);
        }

        const pageCount = try stream.readNext(u8);

        try pages.ensureTotalCapacity(allocator, pageCount);
        errdefer pages.deinit(allocator);

        for (0..pageCount) |_| {
            const pageID = try stream.readNext(u8);
            const offset = try stream.readNext(u16);
            const size = try stream.readNext(u16);
            const data = try stream.grab(size);

            pages.appendAssumeCapacity(.{
                .page = pageID,
                .offset = offset,
                .blob = data,
            });
        }

        const extensionCount = try stream.readNext(u16);
        try extensions.ensureTotalCapacity(allocator, extensionCount);
        errdefer extensions.deinit(allocator);

        for (0..extensionCount) |_| {
            const extID = try stream.readNext(u16);
            const enable = try stream.readNext(u8);

            extensions.appendAssumeCapacity(.{
                .enable = enable,
                .id = extID,
            });
        }

        const debugSymbolCount = try stream.readNext(u32);
        try symbols.ensureTotalCapacity(allocator, debugSymbolCount);
        errdefer symbols.deinit(allocator);

        for (0..debugSymbolCount) |_| {
            const addr = try stream.readNext(u32);
            const len = try stream.readNext(u16);
            const symbol = try stream.grab(len);

            symbols.appendAssumeCapacity(.{
                .address = addr,
                .symbol = symbol,
            });
        }

        return .{
            .allocator = allocator,
            .instructions = instructions,
            .pages = pages,
            .extensions = extensions,
            .symbols = symbols,
        };
    }
};
