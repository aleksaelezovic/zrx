const std = @import("std");
const builtin = @import("builtin");

comptime {
    const required = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, builtin.zig_version_string, required))
        @compileError("durable-checkout requires exactly Zig " ++ required);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zrx = b.dependency("zrx", .{ .target = target, .optimize = optimize }).module("zrx");
    const sqlite_source = b.dependency("sqlite", .{});
    const sqlite = b.addLibrary(.{
        .name = "checkout-sqlite",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const sqlite_flags = &.{ "-std=c99", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" };
    sqlite.root_module.addCSourceFile(.{
        .file = sqlite_source.path("sqlite3.c"),
        .flags = sqlite_flags,
    });
    const translate_sqlite = b.addTranslateC(.{
        .root_source_file = sqlite_source.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_sqlite.addCFlags(&.{"-cflags"});
    translate_sqlite.addCFlags(sqlite_flags);
    translate_sqlite.addCFlags(&.{"--"});
    const sqlite_c = translate_sqlite.createModule();
    sqlite_c.linkLibrary(sqlite);
    const app = b.addModule("checkout", .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zrx", .module = zrx },
            .{ .name = "sqlite_c", .module = sqlite_c },
        },
    });
    const exe = b.addExecutable(.{
        .name = "durable-checkout",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "checkout", .module = app }},
        }),
    });
    b.installArtifact(exe);
    const test_step = b.step("test", "Run unit tests and bounded subprocess/database simulations");
    for ([_][]const u8{ "tests/unit.zig", "tests/sqlite.zig", "src/domain/store.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "checkout", .module = app },
                .{ .name = "zrx", .module = zrx },
                .{ .name = "sqlite_c", .module = sqlite_c },
            },
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
    const integration = b.addSystemCommand(&.{"python3"});
    integration.addFileArg(b.path("tests/integration.py"));
    integration.addArtifactArg(exe);
    // Always exercise real new processes and fresh temporary databases.
    integration.has_side_effects = true;
    test_step.dependOn(&integration.step);
    const check = b.step("check", "Check formatting, unit tests and finite executable simulations");
    check.dependOn(test_step);
    check.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    }).step);
}
