const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use-llvm", "use llvm default true") orelse false;
    const single_threaded = b.option(bool, "single-threaded", "") orelse false;

    const chess = b.addModule("Chess", .{
        .root_source_file = b.path("src/Chess.zig"),
    });
    const uci = b.addModule("Uci", .{
        .root_source_file = b.path("src/Uci.zig"),
        .imports = &.{
            .{ .name = "Chess", .module = chess },
        },
    });

    const native_exe = b.createModule(.{
        .root_source_file = b.path("src/native/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .imports = &.{
            .{ .name = "Chess", .module = chess },
            .{ .name = "Uci", .module = uci },
        },
    });
    native_exe.addAnonymousImport("chess_figures", .{
        .root_source_file = b.path("assets/chess_figures.png"),
    });

    const exe = b.addExecutable(.{
        .name = "chessfrontend",
        .root_module = native_exe,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const stockfish_dep = b.dependency("Stockfish", .{});
    const stockfish = stockfish_dep.artifact("stockfish");
    const install_stockfish_step = b.addInstallArtifact(stockfish, .{});

    b.getInstallStep().dependOn(&install_stockfish_step.step);

    { // raylib
        const raylib_dep = b.dependency("raylib", .{
            .target = target,
            .optimize = optimize,
        });

        const raylib = raylib_dep.module("raylib"); // main raylib module
        const raygui = raylib_dep.module("raygui"); // raygui module
        const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
        native_exe.linkLibrary(raylib_artifact);
        native_exe.addImport("raylib", raylib);
        native_exe.addImport("raygui", raygui);
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    const exe_unit_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = native_exe,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    {
        const test_options = b.addOptions();
        test_options.addOptionPath("engine_path", stockfish.getEmittedBin());
        exe_unit_tests.root_module.addImport("args", test_options.createModule());
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    const web_mod = b.createModule(.{
        .root_source_file = b.path("src/web/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .imports = &.{
            .{ .name = "Chess", .module = chess },
            .{ .name = "Uci", .module = uci },
        },
    });
    const web_unit_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = web_mod,
    });
    test_step.dependOn(&b.addRunArtifact(web_unit_tests).step);
    const web_exe = b.addExecutable(.{
        .name = "chess_server",
        .root_module = web_mod,
    });
    b.installArtifact(web_exe);
    const run_server_step = b.step("run-server", "run chess server");
    const run_server = b.addRunArtifact(web_exe);
    run_server_step.dependOn(&run_server.step);
    run_server.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_server.addArgs(args);
    }
}
