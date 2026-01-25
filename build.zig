const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use-llvm", "use llvm default true") orelse false;
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addAnonymousImport("chess_figures", .{
        .root_source_file = b.path("assets/chess_figures.png"),
    });
    const exe = b.addExecutable(.{
        .name = "chessfrontend",
        .root_module = module,
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
        module.linkLibrary(raylib_artifact);
        module.addImport("raylib", raylib);
        module.addImport("raygui", raygui);
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
        .root_module = module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    {
        const test_options = b.addOptions();
        test_options.addOptionPath("engine_path", stockfish.getEmittedBin());
        exe_unit_tests.root_module.addImport("args", test_options.createModule());
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
