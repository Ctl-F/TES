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

    pub const IO_CONTROLLER_LEFT: u8 = 0;
    pub const IO_CONTROLLER_RIGHT: u8 = 1;
    pub const IO_CONTROLLER_UP: u8 = 2;
    pub const IO_CONTROLLER_DOWN: u8 = 3;
    pub const IO_CONTROLLER_BTN0: u8 = 4;
    pub const IO_CONTROLLER_BTN1: u8 = 5;
    pub const IO_CONTROLLER_BTN2: u8 = 6;
    pub const IO_CONTROLLER_BTN3: u8 = 7;
    pub const IO_CONTROLLER_MENU: u8 = 8;
    pub const IO_CONTROLLER_START: u8 = 9;
    pub const IO_CONTROLLER_ALT: u8 = 10;
    pub const IO_CONTROLLER_INPUT_COUNT: u8 = 11;

    pub const IO_CURSOR_SOURCE_X: u8 = 0;
    pub const IO_CURSOR_SOURCE_Y: u8 = 1;
    pub const IO_CURSOR_BUTTON_LEFT: u8 = 2;
    pub const IO_CURSOR_BUTTON_RIGHT: u8 = 3;
    pub const IO_CURSOR_BUTTON_MIDDLE: u8 = 4;

    // SCHEMA:
    // SOURCE 0
    // w -> up
    // a -> left
    // s -> down
    // d -> right
    // j -> BTN 0
    // k -> BTN 1
    // l -> BTN 2
    // i -> BNT 3
    // lshift -> BTN ALT
    // escape -> BTN MENU
    // f -> BTN START
    //
    // SOURCE 1
    // Left -> left
    // Right -> right
    // Up -> up
    // Down -> down
    // np 1 -> BTN 0
    // np 2 -> BTN 1
    // NP 3 -> BNT 2
    // np 5 -> BNT 3
    // R ctl -> BTN ALT
    // R shift -> BTN MENU
    // NP enter -> BTN START
    //
    // SOURCE 2 and SOURCE 3
    // actually map to controllers
    pub const IO_SOURCE_DISABLED: u8 = 0;
    pub const IO_SOURCE_CONTROLLER_0: u8 = 1;
    pub const IO_SOURCE_CONTROLLER_1: u8 = 2;
    pub const IO_SOURCE_CONTROLLER_2: u8 = 3;
    pub const IO_SOURCE_CONTROLLER_3: u8 = 4;
    pub const IO_SOURCE_CURSOR: u8 = 5;
    pub const IO_SOURCE_TEXT: u8 = 6;

    pub const IOSource = extern struct {
        source: u8 = 0,
        bufferHigh: u16 = 0,
        bufferLow: u16 = 0,
    };

    pub const IOBufferControllerSource = extern struct {
        sLeft: u8,
        sRight: u8,
        sUp: u8,
        sDown: u8,
        sBtn0: u8,
        sBtn1: u8,
        sBtn2: u8,
        sBtn3: u8,
        sMenu: u8,
        sStart: u8,
        sAlt: u8,
    };

    pub const IOBufferCursorSource = extern struct {
        x: u16,
        y: u16,
        xPrev: u16,
        yPrev: u16,
        xRel: u16,
        yRel: u16,
        sBtnLeft: u8,
        sBtnRight: u8,
        sBtnMiddle: u8,
    };

    pub const IOBufferTextSource = extern struct {
        lastChar: u8,
        control: u8,
        shift: u8,
        alt: u8,
        accum: [32]u8,
        accumCursor: u8,
    };

    pub const IOHeader = extern struct {
        closeSignal: u8 = 0,
        sources: [4]IOSource = [_]IOSource{.{}} ** 4,
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
