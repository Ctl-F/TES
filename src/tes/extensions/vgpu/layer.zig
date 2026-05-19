const native = @import("native");
const std = @import("std");
const VGPU = @import("vgpu.zig");
const MMMap = @import("../mmioHeader.zig");
const gpu = VGPU.vGPU;

pub const Layer = union(enum) {
    disabled: PassThroughLayer,
    pixelBuffer: PixelBufferLayer,

    pub fn attach(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        switch (this) {
            .disabled => |d| try d.attach(parent, idx),
            .pixelBuffer => |p| try p.attach(parent, idx),
        }
    }

    pub fn detach(this: @This(), parent: *gpu, idx: u16) anyerror!void {
        switch (this) {
            .disabled => |d| try d.detach(parent, idx),
            .pixelBuffer => |p| try p.detach(parent, idx),
        }
    }

    pub fn present(this: @This(), parent: *gpu, idx: u16) anyerror!void {
        switch (this) {
            .disabled => |d| try d.present(parent, idx),
            .pixelBuffer => |p| try p.present(parent, idx),
        }
    }
};

pub const PassThroughLayer = struct {
    pub fn attach(_: *@This(), _: *gpu, _: u16) anyerror!void {}

    pub fn present(_: *@This(), _: *gpu, _: u16) anyerror!void {}

    pub fn detach(_: *@This(), _: *gpu, _: u16) anyerror!void {}
};

pub const PixelBufferLayer = struct {
    context: struct {
        vao: u32 = 0,
        vbo: u32 = 0,
        shader: u32 = 0,
        textureUniformLocation: u32 = 0,
        textureHandle: u32 = 0,
    } = .{},
    config: *MMMap.GFXPixelLayerConfig,

    const PixelShaderVert = @embedFile("../PixelShader_VTX.glsl");
    const PixelShaderFrag = @embedFile("../PixelShader_VTX.glsl");

    pub fn attach(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        const FullScreenQuad = VGPU.FullScreenQuad;

        const header = parent.getHeader();
        const config = try header.layers[idx].getConfigBuffer(parent.parent);
        const pixelConfig: *MMMap.GFXPixelLayerConfig = @ptrCast(config);

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
            native.glGetUniformLocation(this.context.shader, "PixelBuffer");

        native.glGenTextures(1, &this.context.textureHandle);
        native.glBindTexture(native.GL_TEXTURE_2D, this.context.textureHandle);

        native.glTexImage2D(native.GL_TEXTURE_2D, 0, native.GL_RGBA8, @intCast(pixelConfig.width), @intCast(pixelConfig.height), 0, native.GL_RGBA8, native.GL_UNSIGNED_BYTE, null);

        native.glBindTexture(native.GL_TEXTURE_2D, 0);
    }

    pub fn present(this: *@This(), parent: *gpu, idx: u16) anyerror!void {
        const header = parent.getHeader();
        const config = try header.layers[idx].getConfigBuffer(parent.parent);
        const data = try header.layers[idx].getDataBuffer(parent.parent);
        const pixelConfig: *MMMap.GFXPixelLayerConfig = @ptrCast(config);

        const pixelBuffer = if (pixelConfig.format != @intFromEnum(MMMap.PixelFormat.RGBA32)) CONV: {
            // TODO: convert texture
            break :CONV &.{};
        } else data;

        native.glBindTexture(native.GL_TEXTURE_2D, this.context.textureHandle);
        native.glTexSubImage2D(native.GL_TEXTURE_2D, 0, 0, 0, @intCast(pixelConfig.width), @intCast(pixelConfig.height), native.GL_RGBA8, native.GL_UNSIGNED_BYTE, @ptrCast(pixelBuffer.ptr));

        native.glBindVertexArray(this.context.vao);
        native.glBindBuffer(native.GL_ARRAY_BUFFER, this.context.vbo);

        native.glUseProgram(this.context.shader);
    }

    pub fn detach(_: *@This(), _: *gpu, _: u16) anyerror!void {}
};
