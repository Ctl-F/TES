const vm = @import("tes_core").vm;
// data members map

pub const MMMap = extern struct {
    gpu: GPUHeader = .{},
    io: IOHeader = .{},

    // static members

    pub const GPUHeader = extern struct {
        enable: u8 = 0,
        screenWidth: u16 = 0,
        screenHeight: u16 = 0,
        screenScale: u8 = 0,
        clearColor: ColorRGB32 = .{ .r = 0, .g = 0, .b = 0, .n = 0 },
        clearEnable: u8 = 0,
        layerEnable: u16 = 0,
        layers: [16]GFXLayerConfig = [_]GFXLayerConfig{.{ .configHigh = 0, .configLow = 0, .dataHigh = 0, .dataLow = 0 }} ** 16,
    };

    pub const STRUCT_LAYER_CONFIG_DISABLED: u8 = 0;
    pub const STRUCT_LAYER_CONFIG_FRAMEBUFFER: u8 = 1;

    pub const IOHeader = extern struct {
        closeSignal: u8 = 0,
    };

    pub const PixelFormat = enum(u8) {
        RGBA32 = 0,
        RGB565 = 1,
        RGB555A1 = 2,
    };

    pub const GFXPixelLayerConfig = extern struct {
        structType: u8,
        format: u8,
        width: u16,
        height: u16,
    };

    pub const GFXLayerConfig = extern struct {
        configHigh: u16,
        configLow: u16,
        dataHigh: u16,
        dataLow: u16,

        pub inline fn getConfigBuffer(this: @This(), tes: *vm.TESVM) ![*]u8 {
            const pageEntry = tes.getPageEntry(@truncate(this.configHigh));

            if (pageEntry.permissions.read == false) {
                return error.PageFault;
            }

            if (pageEntry.buffer) |pageBuffer| {
                const buffer: [*]u8 = @ptrCast(&pageBuffer[this.configLow]);
                return buffer;
            }
            return error.PageFault;
        }

        pub inline fn getDataBuffer(this: @This(), tes: *vm.TESVM) ![*]u8 {
            const pageEntry = tes.getPageEntry(@truncate(this.dataHigh));

            if (pageEntry.permissions.read == false) {
                return error.PageFault;
            }

            if (pageEntry.buffer) |pageBuffer| {
                const buffer: [*]u8 = @ptrCast(&pageBuffer[this.dataLow]);
                return buffer;
            }
            return error.PageFault;
        }
    };
    pub const ColorRGB32 = extern struct {
        r: u8,
        g: u8,
        b: u8,
        n: u8,

        pub fn normalize(this: @This()) ColorFRGB32 {
            return .{
                .r = @as(f32, @floatFromInt(this.r)) / 255.0,
                .g = @as(f32, @floatFromInt(this.g)) / 255.0,
                .b = @as(f32, @floatFromInt(this.b)) / 255.0,
                .a = @as(f32, @floatFromInt(this.n)) / 255.0,
            };
        }
    };

    pub const ColorFRGB32 = struct {
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    };

    pub const ColorRGB565_Mask_R: u16 = 0b1111100000000000;
    pub const ColorRGB565_Mask_G: u16 = 0b0000011111100000;
    pub const ColorRGB565_Mask_B: u16 = 0b0000000000011111;

    pub const ColorRGB565_ShiftToR: u16 = 11;
    pub const ColorRGB565_ShiftToG: u16 = 5;
    pub const ColorRGB565_ShiftToB: u16 = 0;
};
