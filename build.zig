const std = @import("std");
const builtin = @import("builtin");
const targets = @import("tests/targets.zig");
const contracts = @import("tests/contracts.zig");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("zrx requires exactly Zig " ++ required ++ " (see .zigversion)");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.addModule("zrx", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const test_step = b.step("test", "Run current API tests, diagnostics and finite examples");
    const public_tests = b.step("declarative-test", "Test declarations, dependencies, operators and I/O");
    const lifecycle = b.step("lifecycle-test", "Test lifetime, alias and producer join/retirement schedules");
    const measurement = b.step("measurement-test", "Test accounting and private measurement checkpoints");
    const examples = b.step("example", "Run finite public API examples");
    test_step.dependOn(public_tests);
    test_step.dependOn(lifecycle);
    test_step.dependOn(measurement);
    test_step.dependOn(examples);

    var demos: [7]*std.Build.Step.Compile = undefined;
    inline for (.{ "resources", "streams", "signals", "scan", "cases", "checkout", "errors" }, 0..) |name, i| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zrx", .module = zrx }},
            }),
        });
        demos[i] = exe;
        const run = b.addRunArtifact(exe);
        if (comptime std.mem.eql(u8, name, "resources"))
            run.expectStdErrEqual("Resources: primary=6 audit=12 acquired=2 released=2\n");
        if (comptime std.mem.eql(u8, name, "streams"))
            run.expectStdErrEqual("Stream total: 14\n");
        if (comptime std.mem.eql(u8, name, "signals"))
            run.expectStdErrEqual("Signal state: 21\nSignal state: 24\nSignal state: 19\n");
        if (comptime std.mem.eql(u8, name, "cases"))
            run.expectStdOutEqual("negative=2 nonnegative=3\n");
        if (comptime std.mem.eql(u8, name, "checkout"))
            run.expectStdErrEqual("Checkout 42: shipment 99; payment calls=3 charges=1 order calls=3 orders=1 shipping calls=3 shipments=1\n");
        if (comptime std.mem.eql(u8, name, "errors")) {
            run.expectStdOutEqual("result: 4\nresult: 6\n");
            run.expectStdErrEqual("error: Invalid\nerror: Unavailable\n");
        }
        examples.dependOn(&run.step);
        b.step("example-" ++ name, "Run the " ++ name ++ " example").dependOn(&run.step);
    }
    const file = b.addExecutable(.{ .name = "copy-lines", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/io_file.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrx", .module = zrx }},
    }) });
    b.step("io-examples", "Build/install the opt-in file program").dependOn(&b.addInstallArtifact(file, .{}).step);
    public_tests.dependOn(&file.step);
    const http = b.addExecutable(.{ .name = "http-echo", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/http_echo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrx", .module = zrx }},
    }) });
    b.step("http-example", "Build/install the opt-in HTTP server").dependOn(&b.addInstallArtifact(http, .{}).step);
    const http_smoke = b.addRunArtifact(http);
    http_smoke.addArgs(&.{ "0", "0" });
    http_smoke.expectExitCode(0);
    public_tests.dependOn(&http_smoke.step);

    const metrics = measurementModules(b, target, optimize);
    const transport = b.createModule(.{ .root_source_file = b.path("src/transport_test_api.zig"), .target = target, .optimize = optimize });
    inline for (.{
        .{ "resources", "tests/world.zig" },
        .{ "service-io", "tests/service_io.zig" },
        .{ "managed-reader", "tests/managed_reader.zig" },
        .{ "byte-streams", "tests/byte_streams.zig" },
        .{ "flat-map", "tests/flat_map.zig" },
        .{ "graphs", "tests/declarative_graphs.zig" },
        .{ "scan", "tests/declarative_scan.zig" },
        .{ "retry", "tests/retryPipe.zig" },
        .{ "errors", "tests/errors.zig" },
        .{ "scan-example", "tests/scan_example.zig" },
        .{ "operators", "tests/operators.zig" },
        .{ "branch", "tests/branch.zig" },
        .{ "http", "tests/http.zig" },
        .{ "lifecycle", "tests/lifecycle_hardening.zig" },
        .{ "join-retirement", "tests/join_retirement.zig" },
        .{ "error-lifecycle", "tests/error_lifecycle.zig" },
        .{ "measurement", "tests/measurement.zig" },
    }) |item| {
        const suite = b.addTest(.{ .name = item[0], .root_module = b.createModule(.{
            .root_source_file = b.path(item[1]),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrx", .module = zrx },
                .{ .name = "world_example", .module = demos[0].root_module },
                .{ .name = "scan_example", .module = demos[3].root_module },
                .{ .name = "cases_example", .module = demos[4].root_module },
                .{ .name = "checkout_example", .module = demos[5].root_module },
                .{ .name = "errors_example", .module = demos[6].root_module },
                .{ .name = "io_example", .module = file.root_module },
                .{ .name = "http_echo", .module = http.root_module },
                .{ .name = "runtime", .module = transport },
                .{ .name = "api", .module = metrics.api },
                .{ .name = "meter", .module = metrics.meter },
                .{ .name = "spans", .module = metrics.spans },
                .{ .name = "phases", .module = metrics.phases },
                .{ .name = "workloads", .module = metrics.workloads },
            },
        }) });
        const run = b.addRunArtifact(suite);
        if (comptime std.mem.eql(u8, item[0], "measurement")) {
            measurement.dependOn(&run.step);
        } else if (comptime std.mem.eql(u8, item[0], "join-retirement") or std.mem.eql(u8, item[0], "error-lifecycle")) {
            lifecycle.dependOn(&run.step);
        } else {
            public_tests.dependOn(&run.step);
            if (comptime std.mem.eql(u8, item[0], "lifecycle")) lifecycle.dependOn(&run.step);
        }
        if (comptime std.mem.eql(u8, item[0], "branch") or std.mem.eql(u8, item[0], "http") or std.mem.eql(u8, item[0], "retry") or std.mem.eql(u8, item[0], "errors") or std.mem.eql(u8, item[0], "error-lifecycle"))
            b.step("test-" ++ item[0], "Run the " ++ item[0] ++ " suite").dependOn(&run.step);
    }
    inline for (contracts.failures) |failure| {
        const invalid = b.addTest(.{ .name = failure[0], .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compile_fail/" ++ failure[0] ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrx", .module = zrx }},
        }) });
        invalid.expect_errors = .{ .contains = failure[1] };
        public_tests.dependOn(&invalid.step);
    }

    const fmt = b.step("fmt", "Check Zig formatting");
    fmt.dependOn(&b.addFmt(.{ .paths = &.{
        b.path("build.zig"), b.path("build.zig.zon"), b.path("src"),
        b.path("tests"),     b.path("examples"),      b.path("benchmarks"),
    }, .check = true }).step);
    const cross = b.step("cross", "Compile current API objects for every catalog target");
    for (targets.targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
        const module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = resolved, .optimize = .ReleaseFast });
        for (targets.fixtures) |fixture| {
            if (fixture.requires_hosted and resolved.result.os.tag == .freestanding) continue;
            const object = b.addObject(.{
                .name = b.fmt("{s}-{s}", .{ fixture.name, triple }),
                .root_module = b.createModule(.{
                    .root_source_file = b.path(fixture.path),
                    .target = resolved,
                    .optimize = .ReleaseFast,
                    .strip = true,
                    .imports = &.{.{ .name = "zrx", .module = module }},
                }),
                .use_llvm = true,
            });
            _ = object.getEmittedBin();
            cross.dependOn(&object.step);
        }
    }
    const check = b.step("check", "Run formatting, current tests and cross builds");
    check.dependOn(fmt);
    check.dependOn(test_step);
    check.dependOn(cross);
    b.default_step.dependOn(test_step);
    addBenchmarks(b);
}

const Measurements = struct {
    api: *std.Build.Module,
    workloads: *std.Build.Module,
    meter: *std.Build.Module,
    spans: *std.Build.Module,
    phases: *std.Build.Module,
};
fn measurementModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Measurements {
    const api = b.createModule(.{ .root_source_file = b.path("src/benchmark_api.zig"), .target = target, .optimize = optimize });
    return .{
        .api = api,
        .workloads = b.createModule(.{
            .root_source_file = b.path("benchmarks/graphs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "api", .module = api }},
        }),
        .meter = b.createModule(.{ .root_source_file = b.path("benchmarks/tracking_allocator.zig"), .target = target, .optimize = optimize }),
        .spans = b.createModule(.{ .root_source_file = b.path("benchmarks/callback_spans.zig"), .target = target, .optimize = optimize }),
        .phases = b.createModule(.{
            .root_source_file = b.path("benchmarks/executor_phases.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "api", .module = api }},
        }),
    };
}
fn addBenchmarks(b: *std.Build) void {
    const modules = measurementModules(b, b.graph.host, .ReleaseFast);
    var values: [4]usize = undefined;
    inline for (.{
        .{ "bench-items", "Finite producer item count", 4096 },
        .{ "bench-warmups", "Unreported warmups per variant", 2 },
        .{ "bench-trials", "Reported trials per variant", 7 },
        .{ "bench-capacity", "Source and inherited transport capacity", 16 },
    }, 0..) |option, i| values[i] = b.option(usize, option[0], option[1]) orelse option[2];
    const elapsed = b.addExecutable(.{ .name = "graph-benchmark", .root_module = modules.workloads, .use_llvm = true });
    const run = b.addRunArtifact(elapsed);
    for (values) |value| run.addArg(b.fmt("{d}", .{value}));
    run.has_side_effects = true;
    b.step("benchmark", "Measure direct and pipeline workloads in LLVM ReleaseFast").dependOn(&run.step);
    const costs = b.addExecutable(.{ .name = "graph-costs", .root_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/costs.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "api", .module = modules.api },
            .{ .name = "workloads", .module = modules.workloads },
            .{ .name = "meter", .module = modules.meter },
            .{ .name = "spans", .module = modules.spans },
            .{ .name = "phases", .module = modules.phases },
        },
    }), .use_llvm = true });
    inline for (.{
        .{ "benchmark-costs", "allocations" },
        .{ "benchmark-spans", "activity" },
        .{ "benchmark-phases", "phases" },
    }) |mode| {
        const instrumented = b.addRunArtifact(costs);
        instrumented.addArg(mode[1]);
        for (values) |value| instrumented.addArg(b.fmt("{d}", .{value}));
        instrumented.has_side_effects = true;
        b.step(mode[0], "Run the " ++ mode[1] ++ " measurement pass").dependOn(&instrumented.step);
    }
}
