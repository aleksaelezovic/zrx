const std = @import("std");
const builtin = @import("builtin");
const compile_fail = @import("tests/compile_fail.zig");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("zrx requires exactly Zig " ++ required ++ " (see .zigversion)");
}

/// Behavior suites in `tests/`, each importing only the public `zrx` module.
const suites = .{ "di", "operators", "programs", "extending" };

/// Runnable examples and the exact output they must produce.
const examples = .{
    .{ .name = "quickstart", .stdout = "total: 14\n", .stderr = "" },
    .{
        .name = "dependencies",
        .stdout =
        \\[log] transforming 5
        \\[log] saved 50 to measurements
        \\[log] transforming 12
        \\[log] saved 120 to measurements
        \\[log] transforming 19
        \\[log] saved 190 to measurements
        \\[log] 3 rows
        \\
        ,
        .stderr = "",
    },
};

/// Targets whose optimized code the zero-overhead check compares. Fixed, so
/// the result does not depend on the machine running the build.
const code_targets = .{ "aarch64-linux", "x86_64-linux" };

/// Targets the library must at least compile for, with and without an
/// operating system: nothing in it needs one.
const cross_targets = .{
    "x86_64-linux",
    "aarch64-linux",
    "aarch64-macos",
    "x86_64-windows",
    "riscv64-linux",
    "wasm32-freestanding",
    "thumb-freestanding-eabi",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.addModule("zrx", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    const test_step = b.step("test", "Run every check that does not need another target's toolchain");
    const unit = b.step("unit", "Run the behavior suites");
    const contracts = b.step("contracts", "Check that misuse fails to compile with the intended message");
    const example = b.step("example", "Run the examples and check their output");
    const zero_overhead = b.step("zero-overhead", "Compare the optimized code of pipelines with hand-written loops");
    const fmt = b.step("fmt", "Check formatting");
    const cross = b.step("cross", "Compile for every target in the catalog");
    const check = b.step("check", "fmt, test and cross");
    test_step.dependOn(unit);
    test_step.dependOn(contracts);
    test_step.dependOn(example);
    test_step.dependOn(zero_overhead);
    check.dependOn(fmt);
    check.dependOn(test_step);
    check.dependOn(cross);
    b.default_step.dependOn(test_step);

    // --- behavior suites ---------------------------------------------------
    inline for (suites) |name| {
        const suite = b.addTest(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path("tests/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }) });
        const run = b.addRunArtifact(suite);
        unit.dependOn(&run.step);
        b.step("test-" ++ name, "Run the " ++ name ++ " suite").dependOn(&run.step);
    }

    // --- compile-error contracts -------------------------------------------
    inline for (compile_fail.cases) |case| {
        const invalid = b.addTest(.{ .name = case[0], .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compile_fail/" ++ case[0] ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }) });
        invalid.expect_errors = .{ .contains = case[1] };
        contracts.dependOn(&invalid.step);
    }

    // --- examples ------------------------------------------------------------
    inline for (examples) |entry| {
        const exe = exampleExecutable(b, zrx, entry.name, target, optimize);
        const run = b.addRunArtifact(exe);
        run.expectStdOutEqual(entry.stdout);
        run.expectStdErrEqual(entry.stderr);
        example.dependOn(&run.step);
        b.step("example-" ++ entry.name, "Run the " ++ entry.name ++ " example").dependOn(&run.step);
    }
    // --- zero overhead -------------------------------------------------------
    const same_code = b.addExecutable(.{ .name = "same_code", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/same_code.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    // The comparison itself is code that can be wrong: it has tests of its own.
    const same_code_tests = b.addTest(.{ .name = "same_code", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/same_code.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    zero_overhead.dependOn(&b.addRunArtifact(same_code_tests).step);
    inline for (code_targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple, .cpu_features = "baseline" }) catch unreachable);
        const compare = b.addRunArtifact(same_code);
        compare.setName("same code on " ++ triple);
        inline for (.{ true, false }) |with_zrx| {
            const object = b.addObject(.{
                .name = "cases-" ++ triple ++ (if (with_zrx) "-zrx" else "-hand"),
                .root_module = casesModule(b, resolved, .ReleaseFast, with_zrx),
                .use_llvm = true,
            });
            compare.addFileArg(object.getEmittedLlvmIr());
        }
        zero_overhead.dependOn(&compare.step);
    }
    const behavior = b.addTest(.{ .name = "zero-overhead-behavior", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/zero_overhead/behavior.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cases", .module = casesModule(b, target, optimize, true) }},
    }) });
    zero_overhead.dependOn(&b.addRunArtifact(behavior).step);

    // --- formatting ------------------------------------------------------------
    fmt.dependOn(&b.addFmt(.{ .paths = &.{
        b.path("build.zig"), b.path("build.zig.zon"), b.path("src"),
        b.path("tests"),     b.path("examples"),      b.path("benchmarks"),
        b.path("tools"),
    }, .check = true }).step);

    // --- cross compilation -------------------------------------------------------
    inline for (cross_targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
        const core = b.addObject(.{
            .name = "core-" ++ triple,
            .root_module = casesModule(b, resolved, .ReleaseFast, true),
        });
        _ = core.getEmittedBin();
        cross.dependOn(&core.step);
    }

    // --- benchmark ---------------------------------------------------------------
    const benchmark = b.addExecutable(.{ .name = "throughput", .root_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/throughput.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "zrx", .module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }) }},
    }) });
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.has_side_effects = true;
    b.step("benchmark", "Measure pipeline throughput against a hand-written loop").dependOn(&run_benchmark.step);
}

fn exampleExecutable(
    b: *std.Build,
    zrx: *std.Build.Module,
    comptime name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("examples/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrx", .module = zrx }},
    }) });
}

/// The zero-overhead fixtures, compiled as their zrx or their hand-written variant.
fn casesModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    with_zrx: bool,
) *std.Build.Module {
    const variant = b.addOptions();
    variant.addOption(bool, "with_zrx", with_zrx);
    return b.createModule(.{
        .root_source_file = b.path("tests/zero_overhead/cases.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        .imports = &.{
            .{ .name = "zrx", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
            }) },
            .{ .name = "variant", .module = variant.createModule() },
        },
    });
}
