const std = @import("std");
const builtin = @import("builtin");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("one-billion-rows requires exactly Zig " ++ required);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.dependency("zrx", .{ .target = target, .optimize = optimize }).module("zrx");
    const domain = b.createModule(.{
        .root_source_file = b.path("src/domain.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "domain", .module = domain }, .{ .name = "zrx", .module = zrx } },
    });
    const plain = b.createModule(.{
        .root_source_file = b.path("src/plain.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "domain", .module = domain }},
    });
    const exe = addCli(b, "one-billion-rows", app, domain);
    const plain_exe = addCli(b, "one-billion-rows-zig", plain, domain);
    const unit = b.addTest(.{ .root_module = domain });
    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain },
            .{ .name = "app", .module = app },
            .{ .name = "plain", .module = plain },
        },
    });
    const options = b.addOptions();
    options.addOptionPath("executable", exe.getEmittedBin());
    options.addOptionPath("plain_executable", plain_exe.getEmittedBin());
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

fn addCli(b: *std.Build, name: []const u8, app: *std.Build.Module, domain: *std.Build.Module) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = app.resolved_target,
            .optimize = app.optimize,
            .imports = &.{ .{ .name = "app", .module = app }, .{ .name = "domain", .module = domain } },
        }),
    });
    b.installArtifact(exe);
    return exe;
}
