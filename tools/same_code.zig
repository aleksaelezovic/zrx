//! same_code ZRX.ll HAND.ll
//!
//! Compares two optimized LLVM IR files function by function. Used by
//! `zig build zero-overhead` to hold zrx pipelines to the code of the
//! hand-written loops in `tests/zero_overhead/cases.zig`.
//!
//! A function named `same_*` must consist of the same instructions in both
//! files. A function named `lean_*` may be shaped differently (the optimizer
//! sometimes picks another loop form for equivalent code), but the zrx variant
//! must not call anything, must keep its state out of memory (no stack slots,
//! no more loads or stores than by hand), and may have at most a quarter more
//! instructions. Any function present in only one file fails: a pipeline stage
//! that was not inlined shows up that way.
//!
//! Instructions are compared as a multiset after erasing value and block names,
//! so two compilations that differ only in naming or block order compare equal
//! while an extra call, load, store or branch cannot hide.
const std = @import("std");

const Function = struct {
    name: []const u8,
    /// Normalized and sorted.
    instructions: [][]const u8,

    fn count(function: Function, comptime opcode: []const u8) usize {
        var total: usize = 0;
        for (function.instructions) |line| {
            if (std.mem.startsWith(u8, line, opcode ++ " ") or std.mem.indexOf(u8, line, "= " ++ opcode ++ " ") != null) total += 1;
        }
        return total;
    }

    /// Calls other than LLVM intrinsics, which are instructions in disguise.
    fn calls(function: Function) usize {
        var total: usize = 0;
        for (function.instructions) |line| {
            const is_call = std.mem.startsWith(u8, line, "call ") or std.mem.startsWith(u8, line, "tail call ") or
                std.mem.indexOf(u8, line, "= call ") != null or std.mem.indexOf(u8, line, "= tail call ") != null;
            if (is_call and std.mem.indexOf(u8, line, "@llvm.") == null) total += 1;
        }
        return total;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: same_code ZRX.ll HAND.ll\n", .{});
        std.process.exit(2);
    }
    const zrx = try parse(arena, try read(init.io, arena, args[1]));
    const hand = try parse(arena, try read(init.io, arena, args[2]));

    var failed = false;
    for (zrx) |function| {
        const other = find(hand, function.name) orelse {
            std.debug.print("FAIL {s}: only the zrx variant has this function, so part of a pipeline was not inlined\n", .{function.name});
            failed = true;
            continue;
        };
        const identical = same(function.instructions, other.instructions);
        const lean = function.calls() == 0 and
            function.count("alloca") <= other.count("alloca") and
            function.count("load") <= other.count("load") and
            function.count("store") <= other.count("store") and
            function.instructions.len <= other.instructions.len + other.instructions.len / 4;
        const must_be_same = std.mem.startsWith(u8, function.name, "same_");
        const must_be_lean = std.mem.startsWith(u8, function.name, "lean_");

        if (identical) {
            std.debug.print("ok   {s}: the same {d} instructions\n", .{ function.name, function.instructions.len });
        } else if (must_be_lean and lean) {
            std.debug.print("ok   {s}: {d} instructions with zrx, {d} by hand; no calls, no extra memory traffic\n", .{
                function.name, function.instructions.len, other.instructions.len,
            });
        } else {
            failed = true;
            std.debug.print("FAIL {s}: {d} instructions with zrx, {d} by hand\n", .{ function.name, function.instructions.len, other.instructions.len });
            if (!must_be_same and !must_be_lean) std.debug.print("  name it same_* or lean_* to say what is expected of it\n", .{});
            report("only with zrx", function.instructions, other.instructions);
            report("only by hand", other.instructions, function.instructions);
        }
    }
    for (hand) |function| {
        if (find(zrx, function.name) == null) {
            std.debug.print("FAIL {s}: only the hand-written variant has this function\n", .{function.name});
            failed = true;
        }
    }
    if (zrx.len == 0) {
        std.debug.print("FAIL: no functions found in {s}\n", .{args[1]});
        failed = true;
    }
    if (failed) std.process.exit(1);
}

fn read(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024));
}

fn find(functions: []const Function, name: []const u8) ?Function {
    for (functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

/// Splits an LLVM IR file into its function definitions.
fn parse(arena: std.mem.Allocator, text: []const u8) ![]Function {
    var functions: std.ArrayList(Function) = .empty;
    var current: ?[]const u8 = null;
    var instructions: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (current == null) {
            if (std.mem.startsWith(u8, raw, "define ")) current = definedName(raw);
            continue;
        }
        if (std.mem.startsWith(u8, raw, "}")) {
            const owned = try instructions.toOwnedSlice(arena);
            std.mem.sort([]const u8, owned, {}, lessThan);
            try functions.append(arena, .{ .name = current.?, .instructions = owned });
            current = null;
            continue;
        }
        const line = try normalize(arena, raw);
        // Block labels end with a colon once their comment is gone.
        if (line.len == 0 or line[line.len - 1] == ':') continue;
        try instructions.append(arena, line);
    }
    return functions.toOwnedSlice(arena);
}

/// `define internal fastcc void @cases.same_route(ptr %0)` is `same_route`.
fn definedName(line: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, line, '@') orelse return line;
    var name = line[at + 1 ..];
    if (name.len != 0 and name[0] == '"') {
        name = name[1..];
        name = name[0 .. std.mem.indexOfScalar(u8, name, '"') orelse name.len];
    } else {
        name = name[0 .. std.mem.indexOfScalar(u8, name, '(') orelse name.len];
    }
    return if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else name;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Erases what may differ between equivalent functions: comments, metadata,
/// attribute groups, whitespace, and the names of values, blocks and constants.
fn normalize(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const char = raw[i];
        switch (char) {
            ';' => break,
            ' ', '\t', '\r' => {
                if (out.items.len != 0 and out.items[out.items.len - 1] != ' ') try out.append(arena, ' ');
                i += 1;
            },
            '%' => {
                try out.append(arena, '%');
                i = skipName(raw, i + 1);
            },
            '@' => {
                const end = skipName(raw, i + 1);
                // Anonymous constants are numbered per compilation; named symbols are kept.
                if (std.mem.indexOf(u8, raw[i..end], "__anon_") != null) {
                    try out.appendSlice(arena, "@anon");
                } else {
                    try out.appendSlice(arena, raw[i..end]);
                }
                i = end;
            },
            '!', '#' => {
                // `!tbaa !12`, `!7`, `#3`: metadata and attribute references.
                i = skipName(raw, i + 1);
                while (out.items.len != 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == ',')) _ = out.pop();
            },
            else => {
                try out.append(arena, char);
                i += 1;
            },
        }
    }
    return std.mem.trim(u8, try out.toOwnedSlice(arena), " ");
}

/// The index just past a bare or quoted identifier starting at `start`.
fn skipName(text: []const u8, start: usize) usize {
    var i = start;
    if (i < text.len and text[i] == '"') {
        i += 1;
        while (i < text.len and text[i] != '"') i += 1;
        return @min(i + 1, text.len);
    }
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.' or text[i] == '$' or text[i] == '-')) i += 1;
    return i;
}

fn same(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Prints the instructions of sorted `a` that sorted `b` lacks.
fn report(title: []const u8, a: []const []const u8, b: []const []const u8) void {
    var j: usize = 0;
    var printed_title = false;
    for (a) |line| {
        while (j < b.len and std.mem.lessThan(u8, b[j], line)) j += 1;
        if (j < b.len and std.mem.eql(u8, b[j], line)) {
            j += 1;
            continue;
        }
        if (!printed_title) {
            std.debug.print("  {s}:\n", .{title});
            printed_title = true;
        }
        std.debug.print("    {s}\n", .{line});
    }
}
