const std = @import("std");
const builtin = @import("builtin");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("multi-file-log-analyzer requires exactly Zig " ++ required);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.dependency("zrx", .{ .target = target, .optimize = optimize }).module("zrx");
    const app = b.addModule("app", .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrx", .module = zrx }},
    });
    const exe = b.addExecutable(.{
        .name = "multi-file-log-analyzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "app", .module = app }},
        }),
    });
    b.installArtifact(exe);

    const unit = b.addTest(.{ .root_module = app });
    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = app },
            .{ .name = "zrx", .module = zrx },
        },
    });
    const options = b.addOptions();
    options.addOptionPath("executable", exe.getEmittedBin());
    integration_module.addOptions("options", options);
    const integration = b.addTest(.{ .root_module = integration_module });

    const tests = b.step("test", "Run unit, composition and executable tests");
    tests.dependOn(&b.addRunArtifact(unit).step);
    tests.dependOn(&b.addRunArtifact(integration).step);
    const check = b.step("check", "Check formatting and run every test");
    check.dependOn(tests);
    check.dependOn(&exe.step);
    check.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    }).step);
}
