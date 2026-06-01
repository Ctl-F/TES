const native = @import("native");
const std = @import("std");
const VGPU = @import("vgpu.zig");
const MMMap = @import("../mmioHeader.zig").MMMap;
const gpu = VGPU.vGPU;

pub const Layer = union(enum) {
    disabled: PassThroughLayer,
    pixelBuffer: PixelBufferLayer,

    pub fn attach(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        switch (this.*) {
            .disabled => |*layer| try PassThroughLayer.attach(layer, parent, idx),
            .pixelBuffer => |*layer| try PixelBufferLayer.attach(layer, parent, idx),
        }
    }

    pub fn detach(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        switch (this.*) {
            .disabled => |*layer| try PassThroughLayer.detach(layer, parent, idx),
            .pixelBuffer => |*layer| try PixelBufferLayer.detach(layer, parent, idx),
        }
    }

    pub fn present(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        switch (this.*) {
            .disabled => |*layer| try PassThroughLayer.present(layer, parent, idx),
            .pixelBuffer => |*layer| try PixelBufferLayer.present(layer, parent, idx),
        }
    }
};

pub const PassThroughLayer = struct {
    pub fn attach(_: *@This(), _: *gpu, _: u16) anyerror!void {}

    pub fn present(_: *@This(), _: *gpu, _: u16) anyerror!void {}

    pub fn detach(_: *@This(), _: *gpu, _: u16) anyerror!void {}
};

var created: bool = false;

pub const PixelBufferLayer = struct {
    context: struct {
        vao: u32 = 0,
        vbo: u32 = 0,
        shader: u32 = 0,
        textureUniformLocation: u32 = 0,
        textureHandle: u32 = 0,
        decompressionBuffer: ?[]u8 = null,
    } = .{},
    config: *MMMap.GFXPixelLayerConfig,

    const PixelShaderVert = @embedFile("../PixelShader_VTX.glsl");
    const PixelShaderFrag = @embedFile("../PixelShader_FRX.glsl");

    pub fn attach(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        const header = parent.getHeader();
        const config = try header.layers[idx].getConfigBuffer(parent.parent);
        const pixelConfig: *MMMap.GFXPixelLayerConfig = @ptrCast(@alignCast(config));

        if (pixelConfig.format != @intFromEnum(MMMap.PixelFormat.RGBA32)) {
            const bufferSize = @as(usize, @intCast(pixelConfig.width)) * @as(usize, @intCast(pixelConfig.height)) * 4;
            this.context.decompressionBuffer = try parent.arena.alloc(u8, bufferSize);
            errdefer {
                parent.arena.free(this.context.decompressionBuffer);
                this.context.decompressionBuffer = null;
            }
        }

        native.glGenVertexArrays(1, &this.context.vao);
        native.glGenBuffers(1, &this.context.vbo);

        native.glBindVertexArray(this.context.vao);
        native.glBindBuffer(native.GL_ARRAY_BUFFER, this.context.vbo);

        native.glBufferData(
            native.GL_ARRAY_BUFFER,
            @intCast(@sizeOf(f32) * FullScreenQuad.len),
            @ptrCast(&FullScreenQuad[0]),
            native.GL_STATIC_DRAW,
        );

        native.glVertexAttribPointer(0, 2, native.GL_FLOAT, native.GL_FALSE, @sizeOf(f32) * 4, @as(?*const anyopaque, @ptrFromInt(0)));
        native.glVertexAttribPointer(1, 2, native.GL_FLOAT, native.GL_FALSE, @sizeOf(f32) * 4, @as(?*const anyopaque, @ptrFromInt(2 * @sizeOf(f32))));

        native.glEnableVertexAttribArray(0);
        native.glEnableVertexAttribArray(1);

        native.glBindVertexArray(0);

        this.context.shader = try VGPU.compileShader(PixelShaderVert, PixelShaderFrag);
        this.context.textureUniformLocation =
            @intCast(native.glGetUniformLocation(this.context.shader, "PixelBuffer"));

        native.glGenTextures(1, &this.context.textureHandle);
        native.glBindTexture(native.GL_TEXTURE_2D, this.context.textureHandle);

        native.glTexImage2D(
            native.GL_TEXTURE_2D,
            0,
            native.GL_RGBA8,
            @intCast(pixelConfig.width),
            @intCast(pixelConfig.height),
            0,
            native.GL_RGBA,
            native.GL_UNSIGNED_BYTE,
            null,
        );

        // Fallback safety filters for flat textures without mipmap chains
        native.glTexParameteri(native.GL_TEXTURE_2D, native.GL_TEXTURE_MIN_FILTER, native.GL_NEAREST);
        native.glTexParameteri(native.GL_TEXTURE_2D, native.GL_TEXTURE_MAG_FILTER, native.GL_NEAREST);
        native.glTexParameteri(native.GL_TEXTURE_2D, native.GL_TEXTURE_WRAP_S, native.GL_CLAMP_TO_EDGE);
        native.glTexParameteri(native.GL_TEXTURE_2D, native.GL_TEXTURE_WRAP_T, native.GL_CLAMP_TO_EDGE);

        native.glBindTexture(native.GL_TEXTURE_2D, 0);
    }

    inline fn formatToSDL(fmt: MMMap.PixelFormat) c_uint {
        return switch (fmt) {
            .RGBA32 => native.SDL_PIXELFORMAT_RGBA8888,
            .RGB565 => native.SDL_PIXELFORMAT_RGB565,
            .RGB555A1 => native.SDL_PIXELFORMAT_RGBA5551,
        };
    }

    inline fn getFormatWidth(fmt: MMMap.PixelFormat) u32 {
        return switch (fmt) {
            .RGBA32 => 4,
            .RGB565, .RGB555A1 => 2,
        };
    }

    fn convert(width: i32, height: i32, srcFormat: MMMap.PixelFormat, srcBuffer: []const u8, dstFormat: MMMap.PixelFormat, dstBuffer: []u8) !void {
        const sdlFormatSrc = formatToSDL(srcFormat);
        const sdlFormatDst = formatToSDL(dstFormat);

        const sourcePitch = @as(c_int, @intCast(width)) * @as(c_int, @intCast(getFormatWidth(srcFormat)));
        const dstPitch = @as(c_int, @intCast(width)) * @as(c_int, @intCast(getFormatWidth(dstFormat)));

        if (!created) {
            const surface = native.SDL_CreateSurfaceFrom(width, height, sdlFormatSrc, @ptrCast(@constCast(srcBuffer.ptr)), sourcePitch);
            if (!native.SDL_SaveBMP(surface, "preframe.bmp")) {
                std.debug.print("Error saving preframe: {s}\n", .{native.SDL_GetError()});
            }
            native.SDL_DestroySurface(surface);
        }

        if (!native.SDL_ConvertPixels(
            width,
            height,
            sdlFormatSrc,
            srcBuffer.ptr,
            sourcePitch,
            sdlFormatDst,
            @ptrCast(dstBuffer.ptr),
            dstPitch,
        )) {
            std.debug.print("Image Conversion Error: {s}\n", .{native.SDL_GetError()});
            return error.FormatConvert;
        }

        if (!created) {
            const surface = native.SDL_CreateSurfaceFrom(width, height, sdlFormatDst, @ptrCast(dstBuffer.ptr), dstPitch);
            _ = native.SDL_SaveBMP(surface, "frame.bmp");
            native.SDL_DestroySurface(surface);
            created = true;
        }
    }

    pub fn present(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        const header = parent.getHeader();
        const config = try header.layers[idx].getConfigBuffer(parent.parent);
        const data = try header.layers[idx].getDataBuffer(parent.parent);
        const pixelConfig: *MMMap.GFXPixelLayerConfig = @ptrCast(@alignCast(config));

        const pixelBuffer = if (pixelConfig.format != @intFromEnum(MMMap.PixelFormat.RGBA32)) CONV: {
            const sourceLength: usize = @as(usize, @intCast(pixelConfig.width)) * @as(usize, @intCast(pixelConfig.height)) * getFormatWidth(@enumFromInt(pixelConfig.format));
            try convert(pixelConfig.width, pixelConfig.height, @as(MMMap.PixelFormat, @enumFromInt(pixelConfig.format)), data[0..sourceLength], .RGBA32, this.context.decompressionBuffer.?);

            var count: usize = 0;

            for (0..this.context.decompressionBuffer.?.len) |i| {
                if (this.context.decompressionBuffer.?[i] != 0) {
                    count += 1;
                }
            }

            break :CONV this.context.decompressionBuffer.?.ptr;
        } else BLK: {
            break :BLK data;
        };

        native.glActiveTexture(native.GL_TEXTURE0);
        native.glBindTexture(native.GL_TEXTURE_2D, this.context.textureHandle);

        native.glPixelStorei(native.GL_UNPACK_ALIGNMENT, 1);

        native.glTexSubImage2D(
            native.GL_TEXTURE_2D,
            0,
            0,
            0,
            @intCast(pixelConfig.width),
            @intCast(pixelConfig.height),
            native.GL_RGBA,
            native.GL_UNSIGNED_BYTE,
            @ptrCast(pixelBuffer),
        );

        native.glBindVertexArray(this.context.vao);
        native.glBindBuffer(native.GL_ARRAY_BUFFER, this.context.vbo);

        native.glUseProgram(this.context.shader);

        native.glUniform1i(@intCast(this.context.textureUniformLocation), 0);
        native.glDrawArrays(native.GL_TRIANGLES, 0, 6);

        native.glUseProgram(0);
        native.glBindVertexArray(0);
        native.glBindTexture(native.GL_TEXTURE_2D, 0);
    }

    pub fn detach(this: *@This(), parent: *gpu, _: u16) anyerror!void {
        native.glDeleteTextures(1, &this.context.textureHandle);
        native.glDeleteProgram(this.context.shader);
        native.glDeleteBuffers(1, &this.context.vbo);
        native.glDeleteVertexArrays(1, &this.context.vao);

        if (this.context.decompressionBuffer) |dbuf| {
            parent.arena.free(dbuf);
        }
        this.context = .{};
    }
};

// Inside PixelBufferLayer
const FullScreenQuad = [_]f32{
    // x,    y,    u,   v
    -1.0, -1.0, 0.0, 0.0,
    1.0,  -1.0, 1.0, 0.0,
    -1.0, 1.0,  0.0, 1.0,

    -1.0, 1.0,  0.0, 1.0,
    1.0,  -1.0, 1.0, 0.0,
    1.0,  1.0,  1.0, 1.0,
};
