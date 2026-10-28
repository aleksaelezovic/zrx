const std = @import("std");
const Allocator = std.mem.Allocator;

// Scoped to the pinned compiler's AArch64 assembly. Keep instructions, register
// choices, operand values, and order exact. Normalize local labels and omit
// known unwind/alignment directives, not arbitrary instructions or semantics.
pub fn normalizedFunction(allocator: Allocator, text: []const u8, symbol: []const u8) ![]const u8 {
    const body = try resolve(text, symbol);
    var labels: std.StringHashMapUnmanaged(usize) = .empty;
    defer labels.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = clean(raw);
        if (std.mem.endsWith(u8, line, ":")) {
            const name = line[0 .. line.len - 1];
            if (labels.contains(name)) return error.DuplicateAssemblyLabel;
            try labels.put(allocator, name, labels.count());
        }
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var instructions: usize = 0;
    lines.reset();
    while (lines.next()) |raw| {
        const line = clean(raw);
        if (line.len == 0) continue;
        if (line[0] == '.' and !std.mem.endsWith(u8, line, ":")) {
            if (std.mem.startsWith(u8, line, ".cfi_") or
                std.mem.startsWith(u8, line, ".seh_") or
                std.mem.startsWith(u8, line, ".p2align") or
                std.mem.startsWith(u8, line, ".size"))
            {
                continue;
            }
            return error.UnsupportedAssemblyDirective;
        }
        if (!std.mem.endsWith(u8, line, ":")) instructions += 1;
        var index: usize = 0;
        while (index < line.len) {
            const start = index;
            while (index < line.len and symbolChar(line[index])) : (index += 1) {}
            if (index == start) {
                try result.append(allocator, line[index]);
                index += 1;
                continue;
            }
            const token = line[start..index];
            if (labels.get(token)) |number| {
                const replacement = try std.fmt.allocPrint(allocator, "BB{d}", .{number});
                defer allocator.free(replacement);
                try result.appendSlice(allocator, replacement);
            } else {
                try result.appendSlice(allocator, token);
            }
        }
        try result.append(allocator, '\n');
    }
    if (instructions == 0) return error.EmptyAssemblyBody;
    return result.toOwnedSlice(allocator);
}

fn clean(line: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, line, "//") orelse line.len;
    return std.mem.trim(u8, line[0..end], " \t\r");
}

fn symbolChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '$';
}

fn resolve(text: []const u8, initial: []const u8) ![]const u8 {
    var symbol = initial;
    for (0..32) |_| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var alias: ?[]const u8 = null;
        while (lines.next()) |raw| {
            const line = clean(raw);
            if (std.mem.indexOfScalar(u8, line, '=')) |equal| {
                if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equal], " \t"), symbol)) continue;
                const target = std.mem.trim(u8, line[equal + 1 ..], " \t");
                if (target.len == 0) return error.UnsupportedAssemblyAlias;
                for (target) |ch| if (!symbolChar(ch)) return error.UnsupportedAssemblyAlias;
                alias = target;
                break;
            }
            if (!std.mem.endsWith(u8, line, ":") or
                !std.mem.eql(u8, line[0 .. line.len - 1], symbol)) continue;
            const start = lines.index.?;
            while (lines.next()) |body_line| {
                const end = clean(body_line);
                if (std.mem.eql(u8, end, ".cfi_endproc") or std.mem.eql(u8, end, ".seh_endproc")) {
                    return text[start .. @intFromPtr(body_line.ptr) - @intFromPtr(text.ptr)];
                }
            }
            return error.UnterminatedAssemblyFunction;
        }
        symbol = alias orelse return error.MissingAssemblyFunction;
    }
    return error.AssemblyAliasCycleOrExcessiveDepth;
}

test "assembly aliases and local labels normalize without hiding instructions" {
    const text =
        \\direct = first
        \\first:
        \\.cfi_startproc
        \\  cbz x0, .LBB1_2
        \\.LBB1_2:
        \\  ret
        \\.cfi_endproc
        \\second:
        \\.seh_proc second
        \\  cbz x0, .LBB9_5
        \\.LBB9_5:
        \\  ret
        \\.seh_endproc
    ;
    const first = try normalizedFunction(std.testing.allocator, text, "direct");
    defer std.testing.allocator.free(first);
    const second = try normalizedFunction(std.testing.allocator, text, "second");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "branch destination changes remain differences" {
    const text =
        \\first:
        \\  cbz x0, .LBB1_1
        \\.LBB1_1:
        \\  mov w0, #1
        \\.LBB1_2:
        \\  ret
        \\.cfi_endproc
        \\second:
        \\  cbz x0, .LBB2_2
        \\.LBB2_1:
        \\  mov w0, #1
        \\.LBB2_2:
        \\  ret
        \\.cfi_endproc
    ;
    const first = try normalizedFunction(std.testing.allocator, text, "first");
    defer std.testing.allocator.free(first);
    const second = try normalizedFunction(std.testing.allocator, text, "second");
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "operand values and register choices remain differences" {
    const first = try normalizedFunction(
        std.testing.allocator,
        "a:\nmov w0, #1\n.cfi_endproc\n",
        "a",
    );
    defer std.testing.allocator.free(first);
    for ([_][]const u8{
        "a:\nmov w0, #2\n.cfi_endproc\n",
        "a:\nmov w1, #1\n.cfi_endproc\n",
    }) |text| {
        const actual = try normalizedFunction(std.testing.allocator, text, "a");
        defer std.testing.allocator.free(actual);
        try std.testing.expect(!std.mem.eql(u8, first, actual));
    }
}

test "unknown directives and missing or cyclic functions fail closed" {
    try std.testing.expectError(error.UnsupportedAssemblyDirective, normalizedFunction(
        std.testing.allocator,
        "first:\n.inst 123\n.cfi_endproc\n",
        "first",
    ));
    try std.testing.expectError(error.MissingAssemblyFunction, resolve("", "missing"));
    try std.testing.expectError(error.AssemblyAliasCycleOrExcessiveDepth, resolve("a = a\n", "a"));
    try std.testing.expectError(error.UnterminatedAssemblyFunction, resolve("a:\nret\n", "a"));
    try std.testing.expectError(error.EmptyAssemblyBody, normalizedFunction(
        std.testing.allocator,
        "a:\n.LBB1_1:\n.cfi_endproc\n",
        "a",
    ));
}
