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
    const try_pipe_tests = b.addTest(.{
        .name = "try-pipe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/try_pipe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(try_pipe_tests).step);
    const sequence_tests = b.addTest(.{
        .name = "sequences",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sequences.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(sequence_tests).step);
    const effect_tests = b.addTest(.{
        .name = "effects",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/effects.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(effect_tests).step);

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
    const example_step = b.step("example", "Run executable examples");
    example_step.dependOn(&run_example.step);
    test_step.dependOn(&run_example.step);
    const try_pipe_example = b.addExecutable(.{
        .name = "try-pipe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/try_pipe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_try_pipe = b.addRunArtifact(try_pipe_example);
    example_step.dependOn(&run_try_pipe.step);
    test_step.dependOn(&run_try_pipe.step);
    const sequence_example = b.addExecutable(.{
        .name = "sequences",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/sequences.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_sequences = b.addRunArtifact(sequence_example);
    example_step.dependOn(&run_sequences.step);
    test_step.dependOn(&run_sequences.step);
    const effect_example = b.addExecutable(.{
        .name = "effects",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/effects.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_effects = b.addRunArtifact(effect_example);
    example_step.dependOn(&run_effects.step);
    test_step.dependOn(&run_effects.step);

    const failures = .{
        .{ "empty_pipe", "pipe: operator tuple must not be empty" },
        .{ "empty_map", "map: transformer tuple must not be empty" },
        .{ "nested_pipe", "pipe: stage 2 is a nested tuple; use a flat tuple or a named helper operator" },
        .{ "nested_map", "map: transformer 2 is a nested tuple; use a flat tuple or a named helper operator" },
        .{ "invalid_stage", "pipe: stage 1 must provide Output(comptime Input: type) type and apply(self, value)" },
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
        .{ "keep_if_non_bool", "keepIf: predicate must return bool" },
        .{ "filter_non_bool", "filter: predicate must return bool" },
        .{ "filter_array_value", "sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference" },
        .{ "filter_incompatible_input", "expected type 'bool', found 'u32'" },
        .{ "each_empty", "each: transformer tuple must not be empty" },
        .{ "each_nested", "each: transformer 1 is a nested tuple; use a flat tuple or a named helper operator" },
        .{ "each_incompatible_input", "expected type 'bool', found 'u32'" },
        .{ "collect_const_buffer", "collectInto: expected a mutable slice or pointer-to-array" },
        .{ "collect_wrong_element", "expected type 'u32', found 'bool'" },
        .{ "keep_if_implicit_unwrap", "expected type 'u32', found '?u32'" },
        .{ "invalid_operator_output", "expected type 'bool', found 'u32'" },
        .{ "tap_wrong_return", "tap: effect must return void or an error union with void payload" },
        .{ "tap_wrong_arity", "tap: effect must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "tap_generic", "tap: effect must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "tap_function_pointer", "tap: effect must be a function" },
        .{ "tap_with_wrong_arity", "tapWith: effect must have two explicitly typed runtime parameters and an explicit return type" },
        .{ "tap_with_wrong_payload", "tapWith: effect must return void or an error union with void payload" },
        .{ "tap_wrong_capability", "expected type 'u32', found 'bool'" },
        .{ "tap_error_plain_next", "expected type 'u32', found 'error{Failed}!u32'" },
        .{ "tap_tuple", "tap: effect must be a function" },
        .{ "try_pipe_empty", "tryPipe: operator tuple must not be empty" },
        .{ "try_pipe_nested", "tryPipe: stage 1 is a nested tuple; use a flat tuple or a named helper operator" },
        .{ "try_pipe_invalid_stage", "tryPipe: stage 1 must provide Output(comptime Input: type) type and apply(self, value)" },
        .{ "try_pipe_input_type", "expected type 'bool', found 'u32'" },
        .{ "try_pipe_null_unwrap", "expected type 'u32', found '?u32'" },
        .{ "try_pipe_bare_error_result", "tryPipe: bare error-set stage results are not supported; wrap error data in a struct" },
        .{ "tap_bare_error_payload", "tap: fallible effects cannot forward bare error-set inputs; wrap error data in a struct" },
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
    const codegen_step = b.step("codegen", "Compare selected direct and pipeline IR/assembly across the target matrix");
    for (codegen.targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        const cross_target = b.resolveTargetQuery(query);
        const cross_zrx = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
            .optimize = .ReleaseFast,
        });
        const object = addCrossObject(
            b,
            cross_zrx,
            cross_target,
            b.fmt("pipelines-{s}", .{triple}),
            b.path("tests/codegen/cases.zig"),
        );
        cross_step.dependOn(&object.step);
        inline for (codegen.cross_only) |fixture| {
            const coverage = addCrossObject(
                b,
                cross_zrx,
                cross_target,
                b.fmt("{s}-{s}", .{ fixture.name, triple }),
                b.path(fixture.path),
            );
            cross_step.dependOn(&coverage.step);
        }
        const comparison = b.addRunArtifact(checker);
        comparison.addArg(triple);
        comparison.addFileArg(object.getEmittedLlvmIr());
        comparison.addFileArg(object.getEmittedAsm());
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

fn addCrossObject(
    b: *std.Build,
    zrx: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    source: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const object = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
        .use_llvm = true,
    });
    // Emitting IR alone does not exercise the target object writer.
    _ = object.getEmittedBin();
    return object;
}
