const std = @import("std");
const builtin = @import("builtin");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("file-integrity-manifest requires exactly Zig " ++ required);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.dependency("zrx", .{ .target = target, .optimize = optimize }).module("zrx");
    // One module: the program, its pipe and `main`.
    const app = b.addModule("app", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zrx", .module = zrx }},
    });
    const exe = b.addExecutable(.{ .name = "file-integrity-manifest", .root_module = app });
    b.installArtifact(exe);

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

    const tests = b.step("test", "Run the pipe with injected output, and the executable");
    tests.dependOn(&b.addRunArtifact(integration).step);
    const check = b.step("check", "Check formatting and run every test");
    check.dependOn(tests);
    check.dependOn(&exe.step);
    check.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    }).step);
}
