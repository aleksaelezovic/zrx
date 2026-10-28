const std = @import("std");
const builtin = @import("builtin");
const codegen = @import("tests/codegen/catalog.zig");

comptime {
    const required_version = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required_version)) {
        @compileError("zrx requires exactly Zig " ++ required_version ++ " (see .zigversion)");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.addModule("zrx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const test_step = b.step("test", "Run unit tests, compile-fail checks, and the example");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const example = b.addExecutable(.{
        .name = "pipeline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_example = b.addRunArtifact(example);
    b.step("example", "Run the synchronous pipeline example").dependOn(&run_example.step);
    test_step.dependOn(&run_example.step);

    const failures = .{
        .{ "empty_pipe", "pipe: operator tuple must not be empty" },
        .{ "empty_map", "map: transformer tuple must not be empty" },
        .{ "nested_pipe", "pipe: stage 2 is a nested tuple; use a flat tuple or a named helper operator" },
        .{ "nested_map", "map: transformer 2 is a nested tuple; use a flat tuple or a named helper operator" },
        .{ "invalid_stage", "pipe: stage 1 must be an operator returned by map or a named helper" },
        .{ "invalid_transformer", "map: transformer 2 must be a function" },
        .{ "wrong_arity", "map: transformer 1 must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "zero_arity", "map: transformer 1 must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "generic_transformer", "map: transformer 1 must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "comptime_parameter", "map: transformer 1 must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "function_pointer", "map: transformer 1 must be a function" },
        .{ "incompatible_input", "expected type 'bool', found 'u32'" },
        .{ "incompatible_transition", "expected type 'bool', found 'u32'" },
        .{ "incompatible_stages", "expected type 'bool', found 'u32'" },
        .{ "implicit_error_unwrap", "expected type 'u32', found 'error{Zero}!u32'" },
        .{ "non_tuple_pipe", "pipe: expected an operator tuple" },
    };
    inline for (failures) |failure| {
        const check = b.addTest(.{
            .name = failure[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/compile_fail/" ++ failure[0] ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zrx", .module = zrx }},
            }),
        });
        check.expect_errors = .{ .contains = failure[1] };
        test_step.dependOn(&check.step);
    }

    const fmt_step = b.step("fmt", "Check Zig formatting");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path("src"),
            b.path("tests"),
            b.path("examples"),
        },
        .check = true,
    }).step);

    const checker_module = b.createModule(.{
        .root_source_file = b.path("tests/codegen/check.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const checker = b.addExecutable(.{
        .name = "check-codegen",
        .root_module = checker_module,
    });
    const checker_tests = b.addTest(.{ .root_module = checker_module });
    test_step.dependOn(&b.addRunArtifact(checker_tests).step);
    const fixture_tests = b.addTest(.{
        .name = "codegen-fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/codegen/cases.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fixture_tests).step);

    const cross_step = b.step("cross", "Compile real pipeline objects for every catalog target");
    const codegen_step = b.step("codegen", "Compare direct and pipeline LLVM IR for every catalog target");
    for (codegen.targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        const cross_target = b.resolveTargetQuery(query);
        const cross_zrx = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
            .optimize = .ReleaseFast,
        });
        const object = b.addObject(.{
            .name = b.fmt("pipelines-{s}", .{triple}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/codegen/cases.zig"),
                .target = cross_target,
                .optimize = .ReleaseFast,
                .strip = true,
                .imports = &.{.{ .name = "zrx", .module = cross_zrx }},
            }),
            .use_llvm = true,
        });
        // Emitting IR alone does not exercise the target object writer.
        _ = object.getEmittedBin();
        cross_step.dependOn(&object.step);
        const comparison = b.addRunArtifact(checker);
        comparison.addArg(triple);
        comparison.addFileArg(object.getEmittedLlvmIr());
        comparison.step.name = b.fmt("compare pipeline codegen {s}", .{triple});
        codegen_step.dependOn(&comparison.step);
    }

    const check_step = b.step("check", "Run formatting, native tests, cross builds, and codegen comparisons");
    check_step.dependOn(fmt_step);
    check_step.dependOn(test_step);
    check_step.dependOn(cross_step);
    check_step.dependOn(codegen_step);
    b.default_step.dependOn(test_step);
}
