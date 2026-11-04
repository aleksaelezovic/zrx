const std = @import("std");
const builtin = @import("builtin");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("http-jobs requires exactly Zig " ++ required);
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
    const exe = b.addExecutable(.{ .name = "http-jobs", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "app", .module = app }},
    }) });
    b.installArtifact(exe);

    const options = b.addOptions();
    options.addOptionPath("executable", exe.getEmittedBin());
    const suite = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = app },
            .{ .name = "zrx", .module = zrx },
            .{ .name = "options", .module = options.createModule() },
        },
    }) });
    const tests = b.step("test", "Run unit, real-graph integration and finite executable simulations");
    tests.dependOn(&b.addRunArtifact(suite).step);
    const check = b.step("check", "Check formatting, build and run all finite tests");
    check.dependOn(tests);
    check.dependOn(b.getInstallStep());
    check.dependOn(&b.addFmt(.{ .paths = &.{
        b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests"),
    }, .check = true }).step);
}
