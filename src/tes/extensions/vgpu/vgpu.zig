const native = @import("native");
const std = @import("std");
const vm = @import("tes_core").vm;
const Layers = @import("layer.zig");
const mmMap = @import("../mmioHeader.zig").MMMap;

const CompositerVertexSource = @embedFile("CompositerVertex.glsl");
const CompositerFragmentSource = @embedFile("CompositerFragment.glsl");

const Layer = Layers.Layer;

pub const TextureFormat = enum(u8) {
    RGBA32 = 0,
    RGB5A1 = 1,
    RGB565 = 2,
    Pallet8 = 3,
    Pallet16 = 4,
};

pub const TextureHeader = extern struct {
    width: u16,
    height: u16,
    format: TextureFormat,
    internalHandle: u32 = 0,
};

pub const Texture = extern struct {
    header: TextureHeader,
    buffer: ?[*]u8,
};

pub const Resources = struct {
    textures: [256]Texture = [_]Texture{
        .{
            .header = .{
                .width = 0,
                .height = 0,
                .format = .RGB565,
            },
            .buffer = null,
        },
    } ** 256,
};

pub const vGPU = struct {
    enabled: bool = false,
    arena: std.mem.Allocator,
    resources: Resources,
    layerMask: u16 = 0,
    layers: [16]Layer = [_]Layer{.{ .disabled = .{} }} ** 16,
    parent: *vm.TESVM,
    context: struct {
        window: ?*native.SDL_Window = null,
        context: native.SDL_GLContext = null,
        fence: ?native.GLsync = null,

        windowWidth: u32 = 0,
        windowHeight: u32 = 0,

        fbo: u32 = 0,
        layerTextureArray: u32 = 0,
        width: c_int = 0,
        height: c_int = 0,

        compositeShader: u32 = 0,
        compositeUniformLayerMaskLocation: u32 = 0,
        compositeUniformLayerTextureLocation: u32 = 0,
        compositeVao: u32 = 0,
        compositeVbo: u32 = 0,
    } = .{},

    pub fn initialize(parent: *vm.TESVM, arena: std.mem.Allocator) @This() {
        return .{
            .enabled = false,
            .layerMask = 0,
            .arena = arena,
            .resources = .{},
            .parent = parent,
        };
    }

    pub inline fn getHeader(this: *@This()) *mmMap.GPUHeader {
        const page = this.parent.getPageMMIO();
        const header: *mmMap.GPUHeader = @ptrCast(@alignCast(&page[0]));
        return header;
    }

    pub fn enable(this: *@This()) !void {
        if (this.enabled) return;

        if (!native.SDL_Init(native.SDL_INIT_VIDEO)) {
            return error.SDLInitError;
        }
        errdefer native.SDL_Quit();

        const header = this.getHeader();

        const width: c_int = @intCast(header.screenWidth);
        const height: c_int = @intCast(header.screenHeight);

        if (width == 0 or height == 0 or width > 2048 or height > 2048 or header.screenScale == 0) {
            return error.InvalidDimensions;
        }

        const wWidth = width * header.screenScale;
        const wHeight = height * header.screenScale;

        _ = native.SDL_GL_SetAttribute(native.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = native.SDL_GL_SetAttribute(native.SDL_GL_CONTEXT_MINOR_VERSION, 3);
        _ = native.SDL_GL_SetAttribute(native.SDL_GL_CONTEXT_PROFILE_MASK, native.SDL_GL_CONTEXT_PROFILE_CORE);

        const window = native.SDL_CreateWindow("T.E.S.", wWidth, wHeight, native.SDL_WINDOW_OPENGL);
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

        if (native.SDL_GL_SetSwapInterval(1)) {
            std.debug.print("VSync enabled\n", .{});
        } else {
            std.debug.print("VSync could not be enabled\n", .{});
        }

        const fbo, const tid = GEN_FB_OBJECTS: {
            var f: u32 = 0;
            var t: u32 = 0;

            native.glGenFramebuffers(1, &f);
            errdefer native.glDeleteFramebuffers(1, &f);

            native.glBindFramebuffer(native.GL_FRAMEBUFFER, f);

            native.glGenTextures(1, &t);
            errdefer native.glDeleteTextures(1, &t);

            native.glBindTexture(native.GL_TEXTURE_2D_ARRAY, t);

            native.glTexImage3D(
                native.GL_TEXTURE_2D_ARRAY,
                0,
                native.GL_RGBA8,
                width,
                height,
                16, // layer count
                0,
                native.GL_RGBA,
                native.GL_UNSIGNED_BYTE,
                null,
            );

            native.glTexParameteri(native.GL_TEXTURE_2D_ARRAY, native.GL_TEXTURE_MIN_FILTER, native.GL_NEAREST);
            native.glTexParameteri(native.GL_TEXTURE_2D_ARRAY, native.GL_TEXTURE_MAG_FILTER, native.GL_NEAREST);
            native.glTexParameteri(native.GL_TEXTURE_2D_ARRAY, native.GL_TEXTURE_WRAP_S, native.GL_CLAMP_TO_EDGE);
            native.glTexParameteri(native.GL_TEXTURE_2D_ARRAY, native.GL_TEXTURE_WRAP_T, native.GL_CLAMP_TO_EDGE);

            break :GEN_FB_OBJECTS .{ f, t };
        };

        const shader, const layerMaskLoc, const texLoc = GEN_SHADER: {
            const programID = try compileShader(CompositerVertexSource, CompositerFragmentSource);
            errdefer native.glDeleteProgram(programID);

            const maskLoc: u32 = @intCast(native.glGetUniformLocation(programID, "layerMask"));
            const layerLoc: u32 = @intCast(native.glGetUniformLocation(programID, "layerTextures"));

            break :GEN_SHADER .{ programID, maskLoc, layerLoc };
        };

        const vao, const vbo = GEN_OBJECTS: {
            var ao: u32 = 0;
            var bo: u32 = 0;

            native.glGenVertexArrays(1, &ao);
            native.glGenBuffers(1, &bo);

            native.glBindVertexArray(ao);
            native.glBindBuffer(native.GL_ARRAY_BUFFER, bo);

            native.glBufferData(native.GL_ARRAY_BUFFER, @intCast(@sizeOf(f32) * FullScreenQuad.len), @ptrCast(&FullScreenQuad[0]), native.GL_STATIC_DRAW);

            native.glVertexAttribPointer(0, 2, native.GL_FLOAT, native.GL_FALSE, @sizeOf(f32) * 4, @as(?*const anyopaque, @ptrFromInt(0)));
            native.glVertexAttribPointer(1, 2, native.GL_FLOAT, native.GL_FALSE, @sizeOf(f32) * 4, @as(?*const anyopaque, @ptrFromInt(2 * @sizeOf(f32))));

            native.glEnableVertexAttribArray(0);
            native.glEnableVertexAttribArray(1);

            native.glBindVertexArray(0);

            break :GEN_OBJECTS .{ ao, bo };
        };

        this.context = .{
            .window = window,
            .context = context,
            .fbo = fbo,
            .layerTextureArray = tid,
            .width = width,
            .height = height,

            .windowWidth = @intCast(wWidth),
            .windowHeight = @intCast(wHeight),

            .compositeShader = shader,
            .compositeUniformLayerMaskLocation = layerMaskLoc,
            .compositeUniformLayerTextureLocation = texLoc,
            .compositeVao = vao,
            .compositeVbo = vbo,
        };

        this.enabled = true;
    }

    fn updateLayerData(this: *@This(), layer: u32, pixels: []const u8) void {
        native.glBindTexture(native.GL_TEXTURE_2D_ARRAY, this.context.layerTextureArray);

        native.glTexSubImage3D(
            native.GL_TEXTURE_2D_ARRAY,
            0,
            0,
            0,
            @intCast(layer),
            this.context.width,
            this.context.height,
            1,
            native.GL_RGBA,
            native.GL_UNSIGNED_BYTE,
            @ptrCast(pixels.ptr),
        );
    }

    pub fn disable(this: *@This()) !void {
        for (0..this.layers.len) |idx| {
            try this.layers[idx].detach(this, @truncate(idx));
            this.layers[idx] = .{ .disabled = .{} };
        }

        native.glDeleteProgram(this.context.compositeShader);
        native.glDeleteVertexArrays(1, &this.context.compositeVao);
        native.glDeleteBuffers(1, &this.context.compositeVbo);
        native.glDeleteFramebuffers(1, &this.context.fbo);
        native.glDeleteTextures(1, &this.context.layerTextureArray);

        _ = native.SDL_GL_DestroyContext(this.context.context);
        _ = native.SDL_DestroyWindow(this.context.window);

        native.SDL_Quit();

        this.context = .{};

        this.enabled = false;
    }

    pub fn setLayer(this: *@This(), idx: u16, new: Layer) !void {
        try this.layers[idx].detach(this, idx);
        this.layers[idx] = new;
        try this.layers[idx].attach(this, idx);
    }

    pub fn present(this: *@This()) !void {
        if (this.context.fence) |fence| {
            _ = native.glClientWaitSync(fence, native.GL_SYNC_FLUSH_COMMANDS_BIT, 500_000_000);

            native.glDeleteSync(fence);
            this.context.fence = null;
        }

        const header = this.getHeader();

        native.glBindFramebuffer(native.GL_FRAMEBUFFER, this.context.fbo);
        native.glViewport(0, 0, this.context.width, this.context.height);

        //std.debug.print("[vgpu] Presenting layer mask: {b}\n", .{this.layerMask});
        for (&this.layers, 0..) |*layer, idx| {
            const mask: u16 = @as(u16, 1) << @as(u4, @truncate(idx));
            if (this.layerMask & mask == 0) continue;

            //std.debug.print("[vgpu] Presenting layer {}\n", .{layer});

            native.glFramebufferTextureLayer(native.GL_FRAMEBUFFER, native.GL_COLOR_ATTACHMENT0, this.context.layerTextureArray, 0, @intCast(idx));

            native.glClearColor(0, 0, 0, 0);
            native.glClear(native.GL_COLOR_BUFFER_BIT);

            try layer.present(this, @truncate(idx));
        }

        //native.glFramebufferTextureLayer(native.GL_FRAMEBUFFER, native.GL_COLOR_ATTACHMENT0, 0, 0, 0);

        native.glBindFramebuffer(native.GL_FRAMEBUFFER, 0);
        //native.glFlush();

        native.glViewport(0, 0, @intCast(this.context.windowWidth), @intCast(this.context.windowHeight));

        if (header.clearEnable != 0) {
            const color = header.clearColor.normalize();
            native.glClearColor(color.r, color.g, color.b, color.a);
            native.glClear(native.GL_COLOR_BUFFER_BIT);
        }

        native.glBindVertexArray(this.context.compositeVao);
        native.glBindBuffer(native.GL_ARRAY_BUFFER, this.context.compositeVbo);

        native.glActiveTexture(native.GL_TEXTURE0);
        native.glBindTexture(native.GL_TEXTURE_2D_ARRAY, this.context.layerTextureArray);

        native.glEnable(native.GL_BLEND);
        native.glBlendFunc(native.GL_SRC_ALPHA, native.GL_ONE_MINUS_SRC_ALPHA);

        native.glUseProgram(this.context.compositeShader);
        native.glUniform1i(@intCast(this.context.compositeUniformLayerMaskLocation), @intCast(this.layerMask));
        native.glUniform1i(@intCast(this.context.compositeUniformLayerTextureLocation), 0);

        native.glDrawArrays(native.GL_TRIANGLES, 0, 6);

        native.glDisable(native.GL_BLEND);

        this.context.fence = native.glFenceSync(native.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);

        native.glFinish();
        _ = native.SDL_GL_SwapWindow(this.context.window);
    }
};

pub fn compileShader(vsrc: [:0]const u8, fsrc: [:0]const u8) !u32 {
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
        //const len = std.mem.indexOfScalar(u8, buffer[0..buf_len], 0) orelse @as(usize, @intCast(length));

        const stage_string = switch (stage) {
            native.GL_VERTEX_SHADER => "Vertex",
            native.GL_FRAGMENT_SHADER => "Fragment",
            else => "Undefined",
        };

        std.log.err("ShaderCompileError [{s}]: {s} ::{s}\n", .{ stage_string, buffer, src[0..64] });
        return error.SHADER_COMPILE_ERROR;
    }
    return shader;
}

// Inside PixelBufferLayer
const FullScreenQuad = [_]f32{
    // x,    y,    u,   v
    -1.0, -1.0, 0.0, 1.0,
    1.0,  -1.0, 1.0, 1.0,
    -1.0, 1.0,  0.0, 0.0,

    -1.0, 1.0,  0.0, 0.0,
    1.0,  -1.0, 1.0, 1.0,
    1.0,  1.0,  1.0, 0.0,
};
