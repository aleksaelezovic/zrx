const std = @import("std");
const catalog = @import("catalog.zig");
const assembly = @import("assembly.zig");
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.ExpectedTargetAndLlvmIrAndAssemblyPaths;
    const target = args[1];
    const ir = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], arena, .limited(4 * 1024 * 1024));

    inline for (catalog.cases) |case| {
        const direct = resolve(ir, case ++ "_direct") catch |err| {
            std.debug.print("codegen {s}/{s}/direct: {s}\nIR: {s}\n", .{ target, case, @errorName(err), args[2] });
            return err;
        };
        inline for (.{ "grouped", "separate" }) |form| {
            const actual = resolve(ir, case ++ "_" ++ form) catch |err| {
                std.debug.print("codegen {s}/{s}/{s}: {s}\nIR: {s}\n", .{ target, case, form, @errorName(err), args[2] });
                return err;
            };
            if (!try equivalent(arena, direct, actual)) {
                std.debug.print(
                    "codegen {s}/{s}: {s} differs from direct\nIR: {s}\nDirect:\n{s}\n{s}:\n{s}\n",
                    .{ target, case, form, args[2], direct.body, form, actual.body },
                );
                return error.CodegenMismatch;
            }
        }
        std.debug.print("codegen {s}/{s}: direct = grouped = separate\n", .{ target, case });
    }

    const assembly_text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], arena, .limited(4 * 1024 * 1024));
    inline for (catalog.assembly_cases) |case| {
        if (!std.mem.startsWith(u8, target, case.arch ++ "-")) {
            std.debug.print("codegen {s}/{s}: behavior/cross coverage; assembly comparison scoped to {s}\n", .{ target, case.name, case.arch });
        } else {
            const prefix: []const u8 = if (std.mem.indexOf(u8, target, "-macos") != null) "_" else "";
            const direct_name = try std.fmt.allocPrint(arena, "{s}{s}_direct", .{ prefix, case.name });
            const direct = assembly.normalizedFunction(arena, assembly_text, direct_name) catch |err| {
                std.debug.print("assembly codegen {s}/{s}/direct: {s}\nAssembly: {s}\n", .{ target, case.name, @errorName(err), args[3] });
                return err;
            };
            inline for (.{ "grouped", "separate" }) |form| {
                const name = try std.fmt.allocPrint(arena, "{s}{s}_{s}", .{ prefix, case.name, form });
                const actual = assembly.normalizedFunction(arena, assembly_text, name) catch |err| {
                    std.debug.print("assembly codegen {s}/{s}/{s}: {s}\nAssembly: {s}\n", .{ target, case.name, form, @errorName(err), args[3] });
                    return err;
                };
                if (!std.mem.eql(u8, direct, actual)) {
                    std.debug.print(
                        "assembly codegen {s}/{s}: {s} differs from direct\nAssembly: {s}\nDirect:\n{s}\n{s}:\n{s}\n",
                        .{ target, case.name, form, args[3], direct, form, actual },
                    );
                    return error.AssemblyCodegenMismatch;
                }
            }
            std.debug.print("assembly codegen {s}/{s}: direct = grouped = separate\n", .{ target, case.name });
        }
    }
}

test "assembly checker coverage" {
    _ = assembly;
}

const Function = struct {
    body: []const u8,
};

// This is intentionally a scoped checker for stripped LLVM output from the
// pinned compiler, not an LLVM parser or a proof of semantic equivalence.
// Resolve simple function aliases; unsupported forms fail rather than skip.
fn resolve(ir: []const u8, initial_symbol: []const u8) !Function {
    var symbol = initial_symbol;
    for (0..32) |_| {
        var lines = std.mem.splitScalar(u8, ir, '\n');
        var alias: ?[]const u8 = null;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "@")) {
                const name = try symbolAt(line, 0);
                if (!std.mem.eql(u8, name, symbol)) continue;
                if (std.mem.indexOf(u8, line, " alias ") == null) return error.UnsupportedGlobal;
                const at = std.mem.lastIndexOfScalar(u8, line, '@') orelse return error.MalformedAlias;
                if (at == 0) return error.MalformedAlias;
                alias = try symbolAt(line, at);
                break;
            }
            if (!std.mem.startsWith(u8, line, "define ")) continue;
            const at = std.mem.indexOfScalar(u8, line, '@') orelse return error.MalformedDefinition;
            if (!std.mem.eql(u8, try symbolAt(line, at), symbol)) continue;
            if (!std.mem.endsWith(u8, line, "{")) return error.UnsupportedDefinition;
            const start = lines.index.?;
            while (lines.next()) |body_line| {
                if (std.mem.eql(u8, std.mem.trim(u8, body_line, " \t\r"), "}")) {
                    const end = @intFromPtr(body_line.ptr) - @intFromPtr(ir.ptr);
                    const body = ir[start..end];
                    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return error.EmptyDefinition;
                    return .{ .body = body };
                }
            }
            return error.UnterminatedDefinition;
        }
        symbol = alias orelse return error.MissingDefinition;
    }
    return error.AliasCycleOrExcessiveDepth;
}

fn symbolAt(line: []const u8, at: usize) ![]const u8 {
    var end = at + 1;
    while (end < line.len) : (end += 1) {
        const ch = line[end];
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '$' and ch != '-') break;
    }
    if (end == at + 1) return error.UnsupportedSymbol;
    return line[at + 1 .. end];
}

fn normalized(allocator: Allocator, body: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
    }
    return result.toOwnedSlice(allocator);
}

fn equivalent(allocator: Allocator, expected: Function, actual: Function) !bool {
    const left = try normalized(allocator, expected.body);
    defer allocator.free(left);
    const right = try normalized(allocator, actual.body);
    defer allocator.free(right);
    return std.mem.eql(u8, left, right);
}

test "function aliases and whitespace normalize to the same body" {
    const ir =
        \\@grouped = alias i32 (i32), ptr @forward
        \\@forward = alias i32 (i32), ptr @direct
        \\define i32 @direct(i32 %0) {
        \\  %2 = add i32 %0, 1
        \\  ret i32 %2
        \\}
        \\define i32 @separate(i32 %0) {
        \\; irrelevant comment
        \\    %2 = add i32 %0, 1
        \\
        \\    ret i32 %2
        \\}
    ;
    const direct = try resolve(ir, "direct");
    try std.testing.expect(try equivalent(std.testing.allocator, direct, try resolve(ir, "grouped")));
    try std.testing.expect(try equivalent(std.testing.allocator, direct, try resolve(ir, "separate")));
}

test "changed instructions do not compare equal" {
    const expected: Function = .{ .body = "ret i32 7\n" };
    const actual: Function = .{ .body = "ret i32 8\n" };
    try std.testing.expect(!try equivalent(std.testing.allocator, expected, actual));
}

test "missing symbols and alias targets fail closed" {
    try std.testing.expectError(error.MissingDefinition, resolve("", "missing"));
    try std.testing.expectError(error.MissingDefinition, resolve("@alias = alias i32 (), ptr @missing", "alias"));
}

test "alias cycles and unsupported symbols fail closed" {
    try std.testing.expectError(error.AliasCycleOrExcessiveDepth, resolve("@a = alias i32 (), ptr @a", "a"));
    try std.testing.expectError(error.UnsupportedSymbol, resolve("@\"a\" = alias i32 (), ptr @b", "a"));
}

test "empty or incomplete definitions fail closed" {
    try std.testing.expectError(error.EmptyDefinition, resolve("define void @a() {\n}\n", "a"));
    try std.testing.expectError(error.UnterminatedDefinition, resolve("define void @a() {\nret void\n", "a"));
}
