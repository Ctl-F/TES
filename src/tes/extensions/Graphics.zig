const native = @import("native");
const std = @import("std");
const tes = @import("tes_core").vm;

pub const pool: tes.PoolID = 1;

pub const GFXBufferLen = 4096;
pub const GFXPageOffset = 0;

const PixelShaderVDefault = @embedFile("PixelShader_VTX.glsl");
const PixelShaderFDefault = @embedFile("PixelShader_FRX.glsl");

const Context = struct {
    init: bool = false,
    window: ?*native.SDL_Window = null,
    context: native.SDL_GLContext = null,
    layers: [16]LayerConfig = [_]LayerConfig{.disabled} ** 16,
    dataPtrs: [16]LayerData = [_]LayerData{.disabled} ** 16,
};

const LayerConfig = union(enum) {
    disabled: void,
    pixelBuffer: PixelBufferContext,

    const PixelBufferContext = struct {
        config: PixelBufferConfig,
        glContext: struct {
            vao: u32 = 0,
            vbo: u32 = 0,
            shaderHandle: u32 = 0,
            textureIndex: u32 = 0,
            textureHandle: u32 = 0,
            pbo: [2]u32 = [_]u32{ 0, 0 },
            pboId: u32 = 0,
        } = .{},

        fn init(config: PixelBufferConfig) @This() {
            return .{
                .config = config,
            };
        }
    };
};

const LayerData = union(enum) {
    disabled: void,
    pixelBuffer: [*]u8,
};

var singleton: Context = .{};

pub const ErrorCodes = enum(u8) {
    UnknownEventCode = 0,
    DisableError = 1,
    EnableError = 2,
    PresentError = 3,
    InvalidLayerConfig = 4,
};

pub const EventCodes = enum(u15) {
    GraphicsSync = 1,
    GraphicsPresent = 2,
    _,
};

pub const ModeCodes = enum(u8) {
    Disabled = 0,
    PixelBuffer = 1,
};

pub const FormatCodes = enum(u8) {
    RGB32 = 0,
    RGB565 = 1,

    pub inline fn getSize(this: @This()) u32 {
        return switch (this) {
            .RGB32 => 4,
            .RGB565 => 2,
        };
    }
};

pub const ColorFRGB32 = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const ColorRGB32 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    n: u8,

    fn normalize(this: @This()) ColorFRGB32 {
        return .{
            .r = @as(f32, @floatFromInt(this.r)) / 255.0,
            .g = @as(f32, @floatFromInt(this.g)) / 255.0,
            .b = @as(f32, @floatFromInt(this.b)) / 255.0,
            .a = @as(f32, @floatFromInt(this.n)) / 255.0,
        };
    }
};

pub const PixelBufferConfig = extern struct {
    mode: u8,
    width: u16,
    height: u16,
    format: u8,
};

pub const GFXLayerConfig = extern struct {
    configHigh: u16,
    configLow: u16,
    dataHigh: u16,
    dataLow: u16,
};

pub const GFXHeader = extern struct {
    enable: u8,
    screenWidth: u16,
    screenHeight: u16,
    screenScale: u8,
    clearColor: ColorRGB32,
    clearEnable: u8,
    layerReg: u16,
    layers: [16]GFXLayerConfig,
};

pub fn extension(enable: bool) tes.Extension {
    return .{
        .enabled = enable,
        .getFriendlyName = getFriendlyName,
        .handler = handle,
        .crashDump = crashDump,
    };
}

fn getFriendlyName() []const u8 {
    return "Graphics";
}

fn handle(vm: *tes.TESVM, evCode: tes.EventID) tes.EventResult {
    switch (@as(EventCodes, @enumFromInt(evCode))) {
        .GraphicsSync => {
            return syncConfig(vm);
        },
        .GraphicsPresent => {
            presentGFX(vm) catch {
                return .{
                    .fail = .{
                        .code = @intFromEnum(ErrorCodes.PresentError),
                        .message = "Failed to present graphics",
                        .panic = false,
                    },
                };
            };

            return .ok;
        },
        _ => {},
    }

    return .{
        .fail = .{
            .code = @intFromEnum(ErrorCodes.UnknownEventCode),
            .message = "Provided event code not recognized",
            .panic = true,
        },
    };
}

fn crashDump(vm: *tes.TESVM) void {
    const page = vm.getPageMMIO();
    const header = getHeader(page);
    std.debug.print(
        \\ [ Graphics Info ]
        \\ Header:
        \\   enabled: {}
        \\   size: {}x{} @{}
        \\   layers: {b:0>16}
        \\
        \\ VGPU:
        \\   enabled: {}
        \\   host.window: {s}
        \\   host.context: {s}
        \\
    , .{
        header.enable,
        header.screenWidth,
        header.screenHeight,
        header.screenScale,
        header.layerReg,

        singleton.init,
        if (singleton.window) |_| "allocated" else "null",
        if (singleton.context) |_| "allocated" else "null",
    });
}

fn syncConfig(vm: *tes.TESVM) tes.EventResult {
    const page = vm.getPageMMIO();
    const header = getHeader(page);

    if (header.enable != @as(u8, @intFromBool(singleton.init))) {
        switch (singleton.init) {
            true => disableGFX(vm, header) catch return .{
                .fail = .{
                    .code = @intFromEnum(ErrorCodes.DisableError),
                    .message = "Failed to disable graphics",
                    .panic = false,
                },
            },
            false => enableGFX(vm, header) catch return .{
                .fail = .{
                    .code = @intFromEnum(ErrorCodes.EnableError),
                    .message = "Failed to initialize graphics",
                    .panic = false,
                },
            },
        }
    }

    var mask: u16 = 1;
    for (0..16) |i| {
        defer mask <<= 1;
        if (header.layerReg & mask == 0) continue;

        updateLayerConfig(vm, header, i) catch return .{
            .fail = .{
                .code = @intFromEnum(ErrorCodes.InvalidLayerConfig),
                .message = "Failed to configure layer",
                .panic = false,
            },
        };
    }

    return .ok;
}

fn updateLayerConfig(vm: *tes.TESVM, header: *GFXHeader, index: usize) !void {
    const layerConfig = header.layers[index];
    const configPage = vm.getPage(@truncate(layerConfig.configHigh)) orelse return error.PageFault;
    const dataPage = vm.getPage(@truncate(layerConfig.dataHigh)) orelse return error.PageFault;

    const mode: *u8 = @ptrCast(@alignCast(&configPage[layerConfig.configLow]));
    const dataBuffer: [*]u8 = @ptrCast(@alignCast(&dataPage[layerConfig.dataLow]));

    switch (mode.*) {
        @intFromEnum(ModeCodes.Disabled) => {
            singleton.layers[index] = .disabled;
            singleton.dataPtrs[index] = .disabled;
        },
        @intFromEnum(ModeCodes.PixelBuffer) => {
            const pbc: *PixelBufferConfig = @ptrCast(@alignCast(mode));
            singleton.layers[index] = .{ .pixelBuffer = LayerConfig.PixelBufferContext.init(pbc.*) };
            singleton.dataPtrs[index] = .{ .pixelBuffer = dataBuffer };

            initPixelBuffer(@truncate(index));
        },
        else => return error.InvalidMode,
    }
}

fn initPixelBuffer(index: u16) void {
    std.debug.assert(singleton.layers[index] == .pixelBuffer);

    const defaultData = [_]f32{
        -1.0, -1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0,
        1.0,  1.0,  1.0, 1.0,
    };

    var context = &singleton.layers[index].pixelBuffer;

    native.glGenVertexArrays(1, &context.glContext.vao);
    native.glGenBuffers(1, &context.glContext.vbo);

    native.glBindVertexArray(context.glContext.vao);
    native.glBindBuffer(native.GL_ARRAY_BUFFER, context.glContext.vbo);

    native.glBufferData(native.GL_ARRAY_BUFFER, @intCast(@sizeOf(f32) * defaultData.len), @ptrCast(&defaultData[0]), native.GL_STATIC_DRAW);

    native.glVertexAttribPointer(0, 2, native.GL_FLOAT, native.GL_FALSE, @sizeOf(f32) * 4, @as(?*const anyopaque, @ptrFromInt(0)));
    native.glVertexAttribPointer(1, 2, native.GL_FLOAT, native.GL_FALSE, @sizeOf(f32) * 4, @as(?*const anyopaque, @ptrFromInt(2 * @sizeOf(f32))));

    native.glEnableVertexAttribArray(0);
    native.glEnableVertexAttribArray(1);

    context.glContext.shaderHandle = compileShader(PixelShaderVDefault, PixelShaderFDefault) catch unreachable;

    context.glContext.textureIndex = @intCast(native.glGetUniformLocation(context.glContext.shaderHandle, "PixelBuffer"));

    const size = context.config.width * context.config.height * @as(FormatCodes, @enumFromInt(context.config.format)).getSize();

    native.glGenTextures(1, &context.glContext.textureHandle);
    native.glBindTexture(native.GL_TEXTURE_2D, context.glContext.textureHandle);

    switch (context.config.format) {
        @intFromEnum(FormatCodes.RGB32) => native.glTexImage2D(native.GL_TEXTURE_2D, 0, native.GL_RGBA8, context.config.width, context.config.height, 0, native.GL_RGBA, native.GL_UNSIGNED_BYTE, null),
        @intFromEnum(FormatCodes.RGB565) => native.glTexImage2D(native.GL_TEXTURE_2D, 0, native.GL_RGB565, context.config.width, context.config.height, 0, native.GL_RGB, native.GL_UNSIGNED_SHORT_5_6_5, null),
        else => @panic("Unrecognized format code"),
    }

    native.glTexParameteri(native.GL_TEXTURE_2D, native.GL_TEXTURE_MIN_FILTER, native.GL_NEAREST);
    native.glTexParameteri(native.GL_TEXTURE_2D, native.GL_TEXTURE_MAG_FILTER, native.GL_NEAREST);

    native.glGenBuffers(2, &context.glContext.pbo[0]);
    inline for (0..2) |idx| {
        native.glBindBuffer(native.GL_PIXEL_UNPACK_BUFFER, context.glContext.pbo[idx]);
        native.glBufferData(native.GL_PIXEL_UNPACK_BUFFER, size, null, native.GL_STREAM_DRAW);
    }
    native.glBindBuffer(native.GL_PIXEL_UNPACK_BUFFER, 0);
}

fn presentPixelBuffer(index: u16) void {
    std.debug.assert(singleton.layers[index] == .pixelBuffer);
    var context = &singleton.layers[index].pixelBuffer;
    var data = singleton.dataPtrs[index].pixelBuffer;
    const size = context.config.width * context.config.height * @as(FormatCodes, @enumFromInt(context.config.format)).getSize();

    const currentPbo = context.glContext.pboId;

    context.glContext.pboId += 1;
    context.glContext.pboId = @rem(context.glContext.pboId, @as(u32, @truncate(context.glContext.pbo.len)));

    const nextPbo = context.glContext.pboId;

    native.glBindTexture(native.GL_TEXTURE_2D, context.glContext.textureHandle);
    native.glBindBuffer(native.GL_PIXEL_UNPACK_BUFFER, context.glContext.pbo[currentPbo]);

    switch (context.config.format) {
        @intFromEnum(FormatCodes.RGB32) => native.glTexSubImage2D(native.GL_TEXTURE_2D, 0, 0, 0, context.config.width, context.config.height, native.GL_RGBA, native.GL_UNSIGNED_BYTE, @as(?*const anyopaque, @ptrFromInt(0))),
        @intFromEnum(FormatCodes.RGB565) => native.glTexSubImage2D(native.GL_TEXTURE_2D, 0, 0, 0, context.config.width, context.config.height, native.GL_RGB, native.GL_UNSIGNED_SHORT_5_6_5, @as(?*const anyopaque, @ptrFromInt(0))),
        else => @panic("Unrecognized format code"),
    }
    native.glBindBuffer(native.GL_PIXEL_UNPACK_BUFFER, context.glContext.pbo[nextPbo]);
    const ptr: ?*anyopaque = native.glMapBuffer(native.GL_PIXEL_UNPACK_BUFFER, native.GL_WRITE_ONLY);
    if (ptr != null) {
        @memcpy(@as([*]u8, @ptrCast(ptr)), data[0..size]);
        _ = native.glUnmapBuffer(native.GL_PIXEL_UNPACK_BUFFER);
    }

    native.glBindBuffer(native.GL_PIXEL_UNPACK_BUFFER, 0);

    native.glBindVertexArray(context.glContext.vao);
    native.glBindBuffer(native.GL_ARRAY_BUFFER, context.glContext.vbo);
    native.glUseProgram(context.glContext.shaderHandle);
    native.glUniform1i(@intCast(context.glContext.textureIndex), 0);
    native.glDrawArrays(native.GL_TRIANGLE_STRIP, 0, 4);
}

fn compileShader(vsrc: [:0]const u8, fsrc: [:0]const u8) !u32 {
    const vertex = try compileShaderStage(vsrc, native.GL_VERTEX_SHADER);
    defer native.glDeleteShader(vertex);

    const fragment = try compileShaderStage(fsrc, native.GL_FRAGMENT_SHADER);
    defer native.glDeleteShader(fragment);

    const programID = native.glCreateProgram();
    errdefer native.glDeleteProgram(programID);

    native.glAttachShader(programID, vertex);
    native.glAttachShader(programID, fragment);
    native.glLinkProgram(programID);

    native.glDetachShader(programID, vertex);
    native.glDetachShader(programID, fragment);

    var status: c_int = 0;
    native.glGetProgramiv(programID, native.GL_LINK_STATUS, &status);
    if (status == 0) {
        const buf_len = 1024;
        var buffer = [_]u8{0} ** buf_len;
        var length: native.GLsizei = undefined;

        native.glGetProgramInfoLog(programID, buf_len, &length, @as([*c]native.GLchar, @ptrCast(&buffer)));

        const len = std.mem.indexOfScalar(u8, buffer[0..buf_len], 0) orelse @as(usize, @intCast(length));
        std.log.err("ShaderLinkError: {s}\n", .{buffer[0..len]});
        return error.SHADER_LINK_ERROR;
    }

    return programID;
}

fn compileShaderStage(src: [:0]const u8, stage: c_uint) !u32 {
    const shader = native.glCreateShader(stage);
    native.glShaderSource(shader, 1, &@as([*c]const native.GLchar, @ptrCast(src.ptr)), 0);

    native.glCompileShader(shader);

    var result: c_int = undefined;
    native.glGetShaderiv(shader, native.GL_COMPILE_STATUS, &result);

    if (result == native.GL_FALSE) {
        const buf_len = 1024;
        var buffer = [_]u8{0} ** buf_len;
        var length: native.GLsizei = undefined;

        native.glGetShaderInfoLog(shader, buf_len, &length, @as([*c]native.GLchar, @ptrCast(buffer[0..].ptr)));

        // we do this incase of broken/old opengl drivers that don't populate length
        // has been reported on mobile platforms
        const len = std.mem.indexOfScalar(u8, buffer[0..buf_len], 0) orelse @as(usize, @intCast(length));

        const stage_string = switch (stage) {
            native.GL_VERTEX_SHADER => "Vertex",
            native.GL_FRAGMENT_SHADER => "Fragment",
            else => "Undefined",
        };

        std.log.err("ShaderCompileError [{s}]: {s} ::{d}\n", .{ stage_string, buffer, len });
        return error.SHADER_COMPILE_ERROR;
    }
    return shader;
}

fn getHeader(page: tes.PageBuffer) *GFXHeader {
    const header: *GFXHeader = @ptrCast(@alignCast(&page[
        GFXPageOffset
    ]));
    return header;
}

fn disableGFX(_: *tes.TESVM, _: *GFXHeader) !void {
    native.SDL_DestroyWindow(singleton.window);
    native.SDL_Quit();
    singleton.init = false;

    singleton.window = null;
    singleton.context = null;
}

fn enableGFX(vm: *tes.TESVM, header: *GFXHeader) !void {
    _ = vm;
    errdefer std.debug.print("Graphics was not enabled\n", .{});

    const width = header.screenWidth * header.screenScale;
    const height = header.screenHeight * header.screenScale;

    if (width == 0 or height == 0 or width > 2048 or height > 2048) {
        return error.InvalidDimensions;
    }

    _ = native.SDL_GL_SetAttribute(native.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = native.SDL_GL_SetAttribute(native.SDL_GL_CONTEXT_MINOR_VERSION, 3);
    _ = native.SDL_GL_SetAttribute(native.SDL_GL_CONTEXT_PROFILE_MASK, native.SDL_GL_CONTEXT_PROFILE_CORE);

    const window = native.SDL_CreateWindow("T.E.S.", @intCast(width), @intCast(height), native.SDL_WINDOW_OPENGL);

    if (window == null) {
        return error.WindowCreate;
    }
    errdefer _ = native.SDL_DestroyWindow(window);

    const context = native.SDL_GL_CreateContext(window);

    if (context == null) {
        return error.ContextCreate;
    }
    errdefer _ = native.SDL_GL_DestroyContext(context);

    _ = native.SDL_GL_MakeCurrent(window, context);
    if (native.gladLoadGLLoader(@ptrCast(&native.SDL_GL_GetProcAddress)) == 0) {
        return error.ContextLoad;
    }

    singleton.init = true;
    singleton.window = window;
    singleton.context = context;

    std.debug.print("Graphics enabled\n", .{});
}

pub fn presentGFX(vm: *tes.TESVM) !void {
    if (!singleton.init) {
        return;
    }

    const page = vm.getPageMMIO();
    const header = getHeader(page);

    if (header.clearEnable != 0) {
        const color = header.clearColor.normalize();
        native.glClearColor(color.r, color.g, color.b, color.a);
        native.glClear(native.GL_COLOR_BUFFER_BIT);
    }

    inline for (0..16) |idx| {
        if (singleton.layers[idx] == .pixelBuffer) {
            presentPixelBuffer(idx);
        }
    }

    _ = native.SDL_GL_SwapWindow(singleton.window);
}
