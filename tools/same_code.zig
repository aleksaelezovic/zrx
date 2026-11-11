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
//! while an extra call, load, store or branch cannot hide. Two more things the
//! optimizer chooses freely are made to compare equal: the order of a phi's
//! incoming values, and a comparison with its negation (`x > 9` and `x < 10`
//! are one test with its two outcomes swapped). See `canonicalCompare`.
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
        try instructions.append(arena, try canonical(arena, line));
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

/// Rewrites a normalized instruction into one spelling among equivalent ones.
fn canonical(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, line, "= phi ")) |at| return canonicalPhi(arena, line, at + "= phi ".len);
    if (std.mem.indexOf(u8, line, "= icmp ")) |at| return canonicalCompare(arena, line, at + "= icmp ".len);
    return line;
}

/// `phi i64 [ %, % ], [ 0, % ]`: sort the incoming `[ value, block ]` pairs.
fn canonicalPhi(arena: std.mem.Allocator, line: []const u8, start: usize) ![]const u8 {
    const first = std.mem.indexOfScalarPos(u8, line, start, '[') orelse return line;
    var pairs: std.ArrayList([]const u8) = .empty;
    var rest = line[first..];
    while (std.mem.indexOfScalar(u8, rest, '[')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, ']') orelse break;
        try pairs.append(arena, rest[open .. close + 1]);
        rest = rest[close + 1 ..];
    }
    std.mem.sort([]const u8, pairs.items, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, line[0..first]);
    for (pairs.items, 0..) |pair, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, pair);
    }
    return out.toOwnedSlice(arena);
}

/// A comparison and its negation compare equal, and nothing else does:
/// `icmp ult` with `icmp uge`, `ugt` with `ule`, `eq` with `ne` (and the signed
/// pairs). The negated form is the same test with its two outcomes swapped,
/// and which outcome a branch takes is something this tool cannot see anyway,
/// since block names are erased; `behavior.zig` is what holds both variants to
/// the same results. Against a constant, `> c` is first rewritten to the
/// identical `>= c + 1` (and `<= c` to `< c + 1`), so that `x > 9` and
/// `x < 10` meet as a negated pair.
///
/// Predicates that are only related by swapping operands (`ult` and `ugt`)
/// stay distinct: with value names erased the swap cannot be checked, and
/// `ult` and `ule` on the same operands are different tests.
fn canonicalCompare(arena: std.mem.Allocator, line: []const u8, start: usize) ![]const u8 {
    var words = std.mem.tokenizeScalar(u8, line[start..], ' ');
    var predicate: []const u8 = "";
    var type_and_left: std.ArrayList(u8) = .empty;
    var right: []const u8 = "";
    while (words.next()) |word| {
        if (predicate.len == 0) {
            // Flags such as `samesign` come before the predicate.
            if (isPredicate(word)) predicate = word;
            continue;
        }
        if (right.len != 0) {
            try type_and_left.appendSlice(arena, right);
            try type_and_left.append(arena, ' ');
        }
        right = word;
    }
    if (predicate.len == 0) return line;

    var bound = right;
    const strict_above = std.mem.eql(u8, predicate, "ugt") or std.mem.eql(u8, predicate, "sgt");
    const at_most = std.mem.eql(u8, predicate, "ule") or std.mem.eql(u8, predicate, "sle");
    if (strict_above or at_most) {
        if (std.fmt.parseInt(i128, right, 10)) |constant| {
            bound = try std.fmt.allocPrint(arena, "{d}", .{constant + 1});
            // `> c` is `>= c + 1`; `<= c` is `< c + 1`.
            predicate = if (predicate[0] == 'u')
                (if (strict_above) "uge" else "ult")
            else
                (if (strict_above) "sge" else "slt");
        } else |_| {}
    }
    const pair: []const u8 = for ([_][2][]const u8{
        .{ "eq", "ne" }, .{ "ult", "uge" }, .{ "ugt", "ule" }, .{ "slt", "sge" }, .{ "sgt", "sle" },
    }) |negated| {
        if (std.mem.eql(u8, predicate, negated[0]) or std.mem.eql(u8, predicate, negated[1]))
            break try std.fmt.allocPrint(arena, "{s}|{s}", .{ negated[0], negated[1] });
    } else predicate;
    return std.fmt.allocPrint(arena, "{s}{s} {s}{s}", .{ line[0..start], pair, type_and_left.items, bound });
}

fn isPredicate(word: []const u8) bool {
    for ([_][]const u8{ "eq", "ne", "ugt", "uge", "ult", "ule", "sgt", "sge", "slt", "sle" }) |known| {
        if (std.mem.eql(u8, word, known)) return true;
    }
    return false;
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
