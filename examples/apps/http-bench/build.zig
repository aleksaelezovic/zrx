const std = @import("std");
const builtin = @import("builtin");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("http-bench requires exactly Zig " ++ required);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const workers = b.option(usize, "workers", "Connections each server holds at a time (default 16)") orelse 16;
    const zrx = b.dependency("zrx", .{ .target = target, .optimize = optimize }).module("zrx");
    const settings = b.addOptions();
    settings.addOption(usize, "workers", workers);
    const options = settings.createModule();

    const cli = b.createModule(.{ .root_source_file = b.path("src/cli.zig"), .target = target, .optimize = optimize });
    const app = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrx", .module = zrx }},
    });
    const plain = b.createModule(.{ .root_source_file = b.path("src/plain.zig"), .target = target, .optimize = optimize });
    app.addImport("options", options);
    plain.addImport("options", options);
    const exe = addServer(b, "http-bench", "src/main.zig", "app", app, cli);
    const plain_exe = addServer(b, "http-bench-zig", "src/plain_main.zig", "plain", plain, cli);

    // Sends pipelined requests, for `compare.py --pipeline`.
    const load = b.addExecutable(.{
        .name = "http-bench-load",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/load.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(load);

    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zrx", .module = zrx },
            .{ .name = "app", .module = app },
            .{ .name = "plain", .module = plain },
        },
    });
    const executables = b.addOptions();
    executables.addOptionPath("executable", exe.getEmittedBin());
    executables.addOptionPath("plain_executable", plain_exe.getEmittedBin());
    integration_module.addOptions("executables", executables);

    const tests = b.step("test", "Run unit, composition and executable tests");
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli })).step);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = integration_module })).step);
    const check = b.step("check", "Check formatting and run every test");
    check.dependOn(tests);
    check.dependOn(&exe.step);
    check.dependOn(&plain_exe.step);
    check.dependOn(&load.step);
    check.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    }).step);
}

fn addServer(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    import: []const u8,
    server: *std.Build.Module,
    cli: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = server.resolved_target,
            .optimize = server.optimize,
            .imports = &.{ .{ .name = import, .module = server }, .{ .name = "cli", .module = cli } },
        }),
    });
    b.installArtifact(exe);
    return exe;
}
