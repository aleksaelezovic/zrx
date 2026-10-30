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
    const runtime_api = b.createModule(.{
        .root_source_file = b.path("src/runtime_test_api.zig"),
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
    const test_step = b.step("test", "Run tests, diagnostics, and noninteractive examples");
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
        .name = "runtime-sequences",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sequences.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = runtime_api }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(sequence_tests).step);
    const reduction_tests = b.addTest(.{
        .name = "reduction",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/reduction.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(reduction_tests).step);
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
    const io_tests = b.addTest(.{
        .name = "io",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/io.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = runtime_api }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(io_tests).step);
    const io_example_test_module = b.createModule(.{
        .root_source_file = b.path("tests/io_examples.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrx", .module = zrx }},
    });
    const io_examples_step = b.step("io-examples", "Build/install opt-in terminal, file, and TCP programs");
    inline for (.{
        .{ .file = "io_cli", .executable = "io-cli" },
        .{ .file = "io_file", .executable = "io-file" },
        .{ .file = "io_tcp", .executable = "io-tcp" },
        .{ .file = "io_tcp_take", .executable = "io-tcp-take" },
    }) |example| {
        const program = b.addExecutable(.{
            .name = example.executable,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ example.file ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zrx", .module = zrx }},
            }),
        });
        io_examples_step.dependOn(&b.addInstallArtifact(program, .{}).step);
        test_step.dependOn(&program.step);
        io_example_test_module.addImport(example.file, program.root_module);
        if (comptime std.mem.eql(u8, example.file, "io_cli")) {
            const smoke = b.addRunArtifact(program);
            smoke.setStdIn(.{ .bytes = "ping\nupper Hello, Zig!\nunknown\n" });
            smoke.expectStdOutEqual("pong\nHELLO, ZIG!\n");
            smoke.expectStdErrEqual("error: expected ping or upper TEXT\n");
            smoke.expectExitCode(0);
            test_step.dependOn(&smoke.step);
        }
    }
    const io_example_tests = b.addTest(.{ .name = "io-examples", .root_module = io_example_test_module });
    test_step.dependOn(&b.addRunArtifact(io_example_tests).step);
    inline for (.{ "streams", "branching", "sharing" }) |name| {
        const runtime_tests = b.addTest(.{
            .name = "runtime-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zrx", .module = runtime_api }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    }
    const declaration_tests = b.addTest(.{
        .name = "declarations",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/declarations.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(declaration_tests).step);
    const terminal_tests = b.addTest(.{
        .name = "terminals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/terminals.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(terminal_tests).step);
    const take_tests = b.addTest(.{
        .name = "take",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/take.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(take_tests).step);
    const retention_tests = b.addTest(.{
        .name = "take-last",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/take_last.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(retention_tests).step);
    const merge_tests = b.addTest(.{
        .name = "merge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/merge.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(merge_tests).step);
    const batch_tests = b.addTest(.{
        .name = "batching",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/batching.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(batch_tests).step);
    const signal_tests = b.addTest(.{
        .name = "signals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/signals.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(signal_tests).step);

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
    const reduction_example = b.addExecutable(.{
        .name = "reduction",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/reduction.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_reduction = b.addRunArtifact(reduction_example);
    example_step.dependOn(&run_reduction.step);
    test_step.dependOn(&run_reduction.step);
    const stream_example = b.addExecutable(.{
        .name = "streams",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/streams.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_streams = b.addRunArtifact(stream_example);
    const streams_step = b.step("example-streams", "Run the bounded stream pipeline example");
    streams_step.dependOn(&run_streams.step);
    example_step.dependOn(&run_streams.step);
    test_step.dependOn(&run_streams.step);
    const branching_example = b.addExecutable(.{
        .name = "branching",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/branching.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_branching = b.addRunArtifact(branching_example);
    const branching_step = b.step("example-branching", "Run independent capacity-one reader pipelines");
    branching_step.dependOn(&run_branching.step);
    example_step.dependOn(&run_branching.step);
    test_step.dependOn(&run_branching.step);
    const pipes_example = b.addExecutable(.{
        .name = "pipes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pipes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_pipes = b.addRunArtifact(pipes_example);
    const pipes_step = b.step("example-pipes", "Run two lazy effect flows over one shared declared pipe");
    pipes_step.dependOn(&run_pipes.step);
    example_step.dependOn(&run_pipes.step);
    test_step.dependOn(&run_pipes.step);
    const retention_example = b.addExecutable(.{
        .name = "retention",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/retention.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_retention = b.addRunArtifact(retention_example);
    const retention_step = b.step("example-retention", "Retain the final 100 of 1000 logs");
    retention_step.dependOn(&run_retention.step);
    example_step.dependOn(&run_retention.step);
    test_step.dependOn(&run_retention.step);
    const merge_example = b.addExecutable(.{
        .name = "merge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/merge.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_merge = b.addRunArtifact(merge_example);
    const merge_step = b.step("example-merge", "Merge two declared inputs into one decision/effect flow");
    merge_step.dependOn(&run_merge.step);
    example_step.dependOn(&run_merge.step);
    test_step.dependOn(&run_merge.step);
    const batch_example = b.addExecutable(.{
        .name = "batching",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/batching.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_batch = b.addRunArtifact(batch_example);
    const batch_step = b.step("example-batching", "Send 1000 logs in batches of 100");
    batch_step.dependOn(&run_batch.step);
    example_step.dependOn(&run_batch.step);
    test_step.dependOn(&run_batch.step);
    const signals_example = b.addExecutable(.{
        .name = "signals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/signals.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }),
    });
    const run_signals = b.addRunArtifact(signals_example);
    const signals_step = b.step("example-signals", "Observe replacement and derived signal values");
    signals_step.dependOn(&run_signals.step);
    example_step.dependOn(&run_signals.step);
    test_step.dependOn(&run_signals.step);

    const failures = .{
        .{ "take_array_value", "sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference" },
        .{ "take_stream_iteration", "stream declarations execute through run; use a terminal effect instead of direct iteration" },
        .{ "take_signal", "signal: use values(signal) for stream operators and terminal effects" },
        .{ "take_limit", "expected type 'usize', found 'bool'" },
        .{ "line_zero", "Line: maxBytes must be positive" },
        .{ "line_sink_item", "line output: expected Line(maxBytes) items" },
        .{ "line_file_path", "expected type '[]const u8', found 'bool'" },
        .{ "line_tcp_address", "expected type 'Io.net.IpAddress', found 'u16'" },
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
        .{ "fold_error_return", "fold: reducer must not return an outer error union; use tryFold" },
        .{ "fold_error_state", "fold: reducer must not return an outer error union; use tryFold" },
        .{ "fold_wrong_result", "fold: reducer result must exactly match the accumulator type" },
        .{ "fold_wrong_arity", "fold: reducer must have two explicitly typed runtime parameters and an explicit return type" },
        .{ "fold_generic", "fold: reducer must have two explicitly typed runtime parameters and an explicit return type" },
        .{ "fold_comptime", "fold: reducer must have two explicitly typed runtime parameters and an explicit return type" },
        .{ "fold_function_pointer", "fold: reducer must be a function" },
        .{ "fold_tuple", "fold: reducer must be a function" },
        .{ "fold_wrong_seed", "expected type 'u32', found 'bool'" },
        .{ "fold_empty_wrong_element", "expected type 'bool', found 'u32'" },
        .{ "fold_array_value", "sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference" },
        .{ "try_fold_wrong_result", "tryFold: reducer must return an error union with the accumulator type as payload" },
        .{ "try_fold_wrong_payload", "tryFold: reducer success payload must exactly match the accumulator type" },
        .{ "try_fold_error_state", "tryFold: accumulator must not be an outer error union; wrap error data in a struct" },
        .{ "try_fold_wrong_arity", "tryFold: reducer must have two explicitly typed runtime parameters and an explicit return type" },
        .{ "try_fold_plain_next", "expected type 'u32', found 'error{Failed}!u32'" },
        .{ "try_fold_empty_wrong_element", "expected type 'bool', found 'u32'" },
        .{ "fold_stream_source", "fold: run-backed sources cannot be reduced eagerly; use a terminal flow" },
        .{ "fold_fallible_cursor", "fold: fallible sequence cursors are not supported; reduce an infallible finite source" },
        .{ "try_fold_fallible_cursor", "tryFold: fallible sequence cursors are not supported; reduce an infallible finite source" },
        .{ "iterator_value", "fromIterator: expected a mutable single-item pointer to an iterator with next(self) returning ?T or E!?T" },
        .{ "iterator_wrong_next", "fromIterator: expected a mutable single-item pointer to an iterator with next(self) returning ?T or E!?T" },
        .{ "iterator_generic", "fromIterator: expected a mutable single-item pointer to an iterator with next(self) returning ?T or E!?T" },
        .{ "iterator_const", "fromIterator: expected a mutable single-item pointer to an iterator with next(self) returning ?T or E!?T" },
        .{ "stream_zero_element", "Stream: zero-sized elements are not supported" },
        .{ "stream_iteration", "stream declarations execute through run; use a terminal effect instead of direct iteration" },
        .{ "take_last_iteration", "stream declarations execute through run; use a terminal effect instead of direct iteration" },
        .{ "take_last_array_value", "sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference" },
        .{ "merge_empty", "merge: input tuple must not be empty" },
        .{ "merge_non_tuple", "merge: expected a nonempty flat tuple of inputs" },
        .{ "merge_nested_tuple", "merge: input 2 is a nested tuple; use a flat tuple or a merge declaration" },
        .{ "merge_item_type", "merge: input 2 must have the same item type as input 1; use each to convert explicitly" },
        .{ "merge_array_value", "sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference" },
        .{ "merge_iteration", "stream declarations execute through run; use a terminal effect instead of direct iteration" },
        .{ "stream_collection", "has no member named 'collectInto'" },
        .{ "run_empty", "run: expected a nonempty flat tuple of terminal effect flows" },
        .{ "run_non_tuple", "run: expected a nonempty flat tuple of terminal effect flows" },
        .{ "run_non_flow", "run: expected a nonempty flat tuple of terminal effect flows" },
        .{ "run_nested", "run: expected a nonempty flat tuple of terminal effect flows" },
        .{ "read_from_invalid", "readFrom: expected a mutable pointer to std.Io.Queue(T); declare stream flows directly" },
        .{ "read_from_const", "readFrom: expected a mutable pointer to std.Io.Queue(T); declare stream flows directly" },
        .{ "read_from_owned", "readFrom: expected a mutable pointer to std.Io.Queue(T); declare stream flows directly" },
        .{ "producer_wrong_return", "Stream.fromProducer: producer must return void or E!void" },
        .{ "producer_wrong_capability", "Stream.fromProducer: producer must accept *Emitter(T)" },
        .{ "producer_generic", "Stream.fromProducer: producer must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "producer_function_pointer", "Stream.fromProducer: producer must be a function" },
        .{ "producer_with_wrong_return", "Stream.fromProducerWith: producer must return void or E!void" },
        .{ "producer_with_wrong_capability", "expected type '*const u32', found '*const bool'" },
        .{ "producer_value_capability", "Stream.fromProducerWith: capability must be a single-item pointer" },
        .{ "producer_with_wrong_arity", "Stream.fromProducerWith: producer must have two explicitly typed runtime parameters and an explicit return type" },
        .{ "producer_with_function_pointer", "Stream.fromProducerWith: producer must be a function" },
        .{ "for_each_wrong_return", "forEach: effect must return void or an error union with void payload" },
        .{ "for_each_generic", "forEach: effect must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "for_each_function_pointer", "forEach: effect must be a function" },
        .{ "for_each_wrong_capability", "expected type 'u32', found 'bool'" },
        .{ "collect_then_wrong_return", "collectThen: effect must return void or an error union with void payload" },
        .{ "collect_then_generic", "collectThen: effect must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "collect_then_function_pointer", "collectThen: effect must be a function" },
        .{ "collect_then_mutable_slice", "collectThen: effect must accept a read-only slice []const T" },
        .{ "collect_then_scalar", "collectThen: effect must accept a read-only slice []const T" },
        .{ "collect_then_element", "expected type '[]const bool', found '[]const u32'" },
        .{ "collect_then_capability", "expected type 'u32', found 'bool'" },
        .{ "batch_then_wrong_return", "batchThen: effect must return void or an error union with void payload" },
        .{ "batch_then_generic", "batchThen: effect must have one explicitly typed runtime parameter and an explicit return type" },
        .{ "batch_then_function_pointer", "batchThen: effect must be a function" },
        .{ "batch_then_mutable_slice", "batchThen: effect must accept a read-only slice []const T" },
        .{ "batch_then_scalar", "batchThen: effect must accept a read-only slice []const T" },
        .{ "batch_then_element", "expected type '[]const bool', found '[]const u32'" },
        .{ "batch_then_capability", "expected type 'u32', found 'bool'" },
        .{ "batch_then_with_arity", "batchThenWith: effect must have two explicitly typed runtime parameters and an explicit return type" },
        .{ "signal_each", "each: use map for signals, or each on values(signal)" },
        .{ "signal_terminal", "signal: use values(signal) for stream operators and terminal effects" },
        .{ "signal_filter", "signal: use values(signal) for stream operators and terminal effects" },
        .{ "signal_initial_type", "expected type 'bool', found 'comptime_int'" },
        .{ "signal_map_input", "expected type 'bool', found 'u32'" },
        .{ "signal_values_input", "signal: expected a signal declaration; use hold(initial) on an update source" },
        .{ "signal_sample_input", "signal: expected a signal declaration; use hold(initial) on an update source" },
        .{ "signal_map_void", "map: signal transforms must return nonzero-sized values; use values and terminal effects" },
        .{ "signal_map_group_void", "map: signal transforms must return nonzero-sized values; use values and terminal effects" },
        .{ "signal_initial_undefined", "hold: initial value must not be undefined" },
        .{ "signal_try_group_unwrap", "expected type 'u32', found 'error{Bad}!u32'" },
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

    inline for (.{
        .{ "collect_const_buffer", "collectInto: expected a mutable slice or pointer-to-array" },
        .{ "collect_wrong_element", "expected type 'u32', found 'bool'" },
        .{ "tee_non_stream", "tee: expected a mutable pointer to Stream(T)" },
        .{ "tee_const_stream", "tee: expected a mutable pointer to Stream(T)" },
        .{ "tee_standard_queue", "tee: expected a mutable pointer to Stream(T)" },
        .{ "share_array_value", "sequence: expected a borrowed slice, pointer-to-array, or zrx view; pass arrays by reference" },
    }) |failure| {
        const check = b.addTest(.{
            .name = failure[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/compile_fail/" ++ failure[0] ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zrx", .module = runtime_api }},
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
            if (!fixture.requires_hosted or cross_target.result.os.tag != .freestanding) {
                const coverage = addCrossObject(
                    b,
                    cross_zrx,
                    cross_target,
                    b.fmt("{s}-{s}", .{ fixture.name, triple }),
                    b.path(fixture.path),
                );
                cross_step.dependOn(&coverage.step);
            }
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
