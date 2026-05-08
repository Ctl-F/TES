const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target and optimization options for native builds
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glad = b.addTranslateC(.{
        .root_source_file = b.path("src/extern/src/glad.c"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    glad.addIncludePath(b.path("src/extern/include/"));

    // 1. native-tes: Native version of tes
    // Depends on SDL3 and GLAD
    const native_tes = buildTES(b, "native-tes", glad.createModule(), target, optimize);
    native_tes.root_module.linkSystemLibrary("sdl3", .{});

    //native_tes.linkSystemLibrary("sdl3");
    //native_tes.linkLibC();
    //native_tes.addCSourceFile(.{ .file = b.path("src/extern/src/glad.c") });
    //native_tes.addIncludePath(b.path("src/extern/include/"));

    b.installArtifact(native_tes);

    // 2. web-tes: Web version of tes (Wasm)
    // Targets wasm32-freestanding for web deployment
    //const web_target = b.resolveTargetQuery(.{
    //    .cpu_arch = .wasm32,
    //    .os_tag = .freestanding,
    //});
    //const web_tes = buildTES(b, "web-tes", null, web_target, optimize);

    // Web-specific configuration:
    // entry = .disabled because we often use custom start logic or exported functions
    // rdynamic = true to ensure symbols are exported to JS
    //web_tes.entry = .disabled;
    //web_tes.rdynamic = true;

    // Install web assets
    //b.getInstallStep().dependOn(&b.addInstallFile(b.path("src/web/index.html"), "index.html").step);
    //b.getInstallStep().dependOn(&b.addInstallFile(b.path("src/web/glue.js"), "glue.js").step);

    //b.installArtifact(web_tes);

    // 3. native-xBEEF: Native version of xBEEF
    const native_xBEEF = b.addExecutable(.{
        .name = "native-xBEEF",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xBEEF/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(native_xBEEF);

    // --- Steps ---

    // Run step for native-tes
    const run_tes_cmd = b.addRunArtifact(native_tes);
    run_tes_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_tes_cmd.addArgs(args);
    }
    const run_tes_step = b.step("run-tes", "Run native-tes");
    run_tes_step.dependOn(&run_tes_cmd.step);

    // Run step for native-xBEEF
    const run_xBEEF_cmd = b.addRunArtifact(native_xBEEF);
    run_xBEEF_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_xBEEF_cmd.addArgs(args);
    }
    const run_xBEEF_step = b.step("run-xBEEF", "Run native-xBEEF");
    run_xBEEF_step.dependOn(&run_xBEEF_cmd.step);

    // Serve step for web version (server only)
    const serve_cmd = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory", "zig-out" });
    const serve_step = b.step("serve", "Run a local HTTP server for the web version (port 8000)");
    serve_step.dependOn(b.getInstallStep());
    serve_step.dependOn(&serve_cmd.step);

    // Run-web step: start server and launch browser
    const run_web_cmd = b.addSystemCommand(&.{ "sh", "-c", "sleep 1 && firefox http://localhost:8000 & python3 -m http.server 8000 --directory zig-out" });
    const run_web_step = b.step("run-web", "Build, serve and launch the web version in Firefox");
    run_web_step.dependOn(b.getInstallStep());
    run_web_step.dependOn(&run_web_cmd.step);

    // --- Test Step ---
    const test_step = b.step("test", "Run unit tests");

    // 1. Tests for tes_core module
    // We create a test artifact for the module itself
    const tes_core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tes_core/tes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tes_core_tests = b.addRunArtifact(tes_core_tests);
    test_step.dependOn(&run_tes_core_tests.step);

    // 2. Tests for native-tes
    // Reuse the root_module from the native_tes artifact
    const native_tes_tests = b.addTest(.{
        .root_module = native_tes.root_module,
    });
    // Note: linkSystemLibrary and linkLibC are already inherited from the root_module if configured there,
    // but for tests we often need to ensure they are linked to the test runner.
    const run_native_tes_tests = b.addRunArtifact(native_tes_tests);
    test_step.dependOn(&run_native_tes_tests.step);

    // 3. Tests for native-xBEEF
    const native_xBEEF_tests = b.addTest(.{
        .root_module = native_xBEEF.root_module,
    });
    const run_native_xBEEF_tests = b.addRunArtifact(native_xBEEF_tests);
    test_step.dependOn(&run_native_xBEEF_tests.step);

    // 4. Tests for web-tes
    // Since web-tes is wasm32-freestanding, running tests on the host target
    // for the same source code is usually what is desired for unit testing.
    // However, to strictly have "tests for all three artifacts", we could
    // add a test that builds for wasm, though it wouldn't run without a runner.
    // For now, we assume testing the source logic via native-tes covers web-tes logic.
}

/// Helper to create a TES executable (native or web) with the tes_core module
fn buildTES(b: *std.Build, name: []const u8, glad: ?*std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const tes_core = b.createModule(.{
        .root_source_file = b.path("src/tes_core/tes.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tes/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tes_core", .module = tes_core },
                //.{ .name = "glad", .module = glad },
            },
        }),
    });

    if (glad) |gm| {
        exe.root_module.addImport("glad", gm);
    }

    return exe;
}
