const native = @import("native");
const std = @import("std");
const tes = @import("tes_core").vm;
const mmMap = @import("mmioHeader.zig").MMMap;
const vGPU = @import("vgpu/vgpu.zig");
const Layers = @import("vgpu/layer.zig");

pub const pool: tes.PoolID = 1;

const Context = struct {
    gpu: vGPU.vGPU,
};

var singletonIsInitialized: bool = false;
var singleton: Context = undefined;

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

fn initializeSingleton(vm: *tes.TESVM) void {
    singleton = .{
        .gpu = .initialize(vm, vm.allocator),
    };
    singletonIsInitialized = true;
}

fn handle(vm: *tes.TESVM, evCode: tes.EventID) tes.EventResult {
    if (!singletonIsInitialized) {
        initializeSingleton(vm);
    }

    switch (@as(EventCodes, @enumFromInt(evCode))) {
        .GraphicsSync => {
            syncGraphicsState() catch {
                return .{
                    .fail = .{
                        .code = @intFromEnum(ErrorCodes.EnableError),
                        .message = "Failed to syncronize graphics state",
                        .panic = false,
                    },
                };
            };
            return .ok;
        },
        .GraphicsPresent => {
            presentGraphics() catch {
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
    const header = getHeader(page).gpu;
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
        header.layerEnable,

        singletonIsInitialized,
        if (singleton.gpu.context.window) |_| "allocated" else "null",
        if (singleton.gpu.context.context) |_| "allocated" else "null",
    });
}

fn getHeader(page: tes.PageBuffer) *mmMap {
    const header: *mmMap = @ptrCast(@alignCast(&page[0]));
    return header;
}

pub fn presentGraphics() !void {
    if (!singletonIsInitialized) {
        std.debug.print("Graphics not initialized\n", .{});
        return;
    }
    try singleton.gpu.present();
}

fn syncGraphicsState() !void {
    const header = getHeader(singleton.gpu.parent.getPageMMIO());

    if (header.gpu.enable != @intFromBool(singleton.gpu.enabled)) {
        try syncGPUEnable(header, &singleton.gpu);
    }

    for (0..header.gpu.layers.len) |layerID| {
        try syncGPULayer(header, @truncate(layerID), &singleton.gpu);
    }
}

fn syncGPUEnable(header: *mmMap, gpu: *vGPU.vGPU) !void {
    if (header.gpu.enable == 0) {
        try gpu.disable();
        std.debug.print("GPU Disabled\n", .{});
    } else {
        try gpu.enable();
        std.debug.print("GPU Enabled\n", .{});
    }
}

fn syncGPULayer(header: *mmMap, layerID: u16, gpu: *vGPU.vGPU) !void {
    const mask = @as(u16, 1) << @as(u4, @truncate(layerID));
    const gpuLayerIsEnabled = 0 != (gpu.layerMask & mask);
    const headerLayerIsEnabled = 0 != (header.gpu.layerEnable & mask);

    const headerLayerConfig = try header.gpu.layers[layerID].getConfigBuffer(gpu.parent);
    const headerLayerData = try header.gpu.layers[layerID].getDataBuffer(gpu.parent);

    const structType = headerLayerConfig[0];
    const layerType = switch (gpu.layers[layerID]) {
        .disabled => mmMap.STRUCT_LAYER_CONFIG_DISABLED,
        .pixelBuffer => mmMap.STRUCT_LAYER_CONFIG_FRAMEBUFFER,
    };

    std.debug.print("Syncing layer {}: structType={} layerType={} gpuLayerIsEnabled={} headerLayerIsEnabled={}\n", .{ layerID, structType, layerType, gpuLayerIsEnabled, headerLayerIsEnabled });

    // if they are both enabled or disabled and of the same type
    // we sync the data and exit
    if (structType == layerType and gpuLayerIsEnabled == headerLayerIsEnabled) {
        if (gpuLayerIsEnabled) {
            try syncGPULayerData(gpu, layerID, headerLayerData);
            std.debug.print("Synced layer data only {}\n", .{layerID});
        }
        return;
    }

    // if we are freshly enabling or freshly disabling the layer we
    // do so
    if (gpuLayerIsEnabled != headerLayerIsEnabled) {
        if (!headerLayerIsEnabled) {
            std.debug.print("Disabling layer {}\n", .{layerID});
            try disableGPULayer(gpu, layerID);
            return;
        } else {
            std.debug.print("Enabling layer {}\n", .{layerID});
            try enableGPULayer(gpu, structType, layerID, header);
            return;
        }
    }

    // here they are both in the "enabled" or "disabled" status
    // so if it's disabled in the header then we know that both modes are disabled
    // and we can just exit
    if (!headerLayerIsEnabled) {
        return;
    }

    // by here we know that the header is enabled, the gpu is also enabled
    // but the header type !== layer type so we need to disable the layer and then
    // enable it to the correct type
    std.debug.print("Layer type mismatch: header={} layer={}\n", .{ headerLayerIsEnabled, gpuLayerIsEnabled });
    try disableGPULayer(gpu, layerID);
    std.debug.print("Enabling layer {}\n", .{layerID});
    try enableGPULayer(gpu, structType, layerID, header);
}

fn disableGPULayer(gpu: *vGPU.vGPU, layerID: u16) !void {
    try gpu.setLayer(layerID, .{ .disabled = .{} });

    // set layer bit
    const mask: u16 = @as(u16, 1) << @as(u4, @truncate(layerID));
    const invMask = ~mask;
    gpu.layerMask &= invMask;
}

fn enableGPULayer(gpu: *vGPU.vGPU, layerType: u8, layerID: u16, header: *mmMap) !void {
    const layer = try buildGPULayer(gpu, layerType, layerID, header);

    std.debug.print("Enabling layer {}, type: {}\n", .{ layerID, layerType });

    try gpu.setLayer(layerID, layer);

    // set layer bit
    const mask: u16 = @as(u16, 1) << @as(u4, @truncate(layerID));
    gpu.layerMask |= mask;

    std.debug.print("[egpu] Layer Mask: {b}\n", .{gpu.layerMask});
}

fn buildGPULayer(gpu: *vGPU.vGPU, layerType: u8, layerID: u16, header: *mmMap) !Layers.Layer {
    std.debug.print("[egpu] Building layer: {}, type: {}\n", .{ layerID, layerType });
    switch (layerType) {
        mmMap.STRUCT_LAYER_CONFIG_DISABLED => {
            return .{ .disabled = .{} };
        },
        mmMap.STRUCT_LAYER_CONFIG_FRAMEBUFFER => {
            const config = try header.gpu.layers[layerID].getConfigBuffer(
                gpu.parent,
            );

            const pixelConfig: *mmMap.GFXPixelLayerConfig = @ptrCast(@alignCast(config));
            std.debug.print("[egpu] Building pixel buffer layer, config: {}, {}\n", .{ layerID, pixelConfig });

            return .{
                .pixelBuffer = .{
                    .config = pixelConfig,
                    .context = .{},
                },
            };
        },
        else => return .{ .disabled = .{} },
    }
}
fn syncGPULayerData(gpu: *vGPU.vGPU, layerID: u16, layerData: [*]u8) !void {
    _ = gpu;
    _ = layerID;
    _ = layerData;
}
