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
//! What "the same instructions" means here: the two functions contain the
//! same multiset of instructions once the names of values and blocks are
//! erased. That is a match of instruction shape. It cannot hide an extra call,
//! load, store, branch or comparison, and it tells a comparison from its
//! negation; it does not check which instruction feeds which, or which
//! successor a branch takes. That both variants compute the same results is
//! `tests/zero_overhead/behavior.zig`'s job, not this tool's.
//!
//! Two spellings the optimizer chooses freely, and which denote the same
//! thing, are made to compare equal: the order of a phi's incoming values,
//! and `x > c` against the identical `x >= c + 1`. Nothing else is.
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
    var body: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (current == null) {
            if (std.mem.startsWith(u8, raw, "define ")) current = definedName(raw);
            continue;
        }
        if (!std.mem.startsWith(u8, raw, "}")) {
            try body.append(arena, raw);
            continue;
        }
        var instructions: std.ArrayList([]const u8) = .empty;
        for (body.items) |line| {
            const normalized = try normalize(arena, line);
            // Block labels end with a colon once their comment is gone.
            if (normalized.len == 0 or normalized[normalized.len - 1] == ':') continue;
            try instructions.append(arena, try canonical(arena, normalized));
        }
        const owned = try instructions.toOwnedSlice(arena);
        std.mem.sort([]const u8, owned, {}, lessThan);
        try functions.append(arena, .{ .name = current.?, .instructions = owned });
        current = null;
        body.clearRetainingCapacity();
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

/// Rewrites a normalized instruction into one spelling among identical ones.
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

/// One rewrite: against a constant, `> c` becomes the identical `>= c + 1`,
/// and `<= c` becomes `< c + 1`, except where `c + 1` does not exist in the
/// operand type. Both forms have the same value for every input.
///
/// A comparison is never matched with its negation (`ult` with `uge`): that
/// would be the same test only if the branch using it had its successors
/// swapped, which this tool cannot check. Predicates related by swapping
/// operands (`ult` and `ugt`) stay distinct for the same reason.
fn canonicalCompare(arena: std.mem.Allocator, line: []const u8, start: usize) ![]const u8 {
    var words = std.mem.tokenizeScalar(u8, line[start..], ' ');
    var predicate: []const u8 = "";
    var operand_type: []const u8 = "";
    var type_and_left: std.ArrayList(u8) = .empty;
    var right: []const u8 = "";
    while (words.next()) |word| {
        if (predicate.len == 0) {
            // Flags such as `samesign` come before the predicate.
            if (isPredicate(word)) predicate = word;
            continue;
        }
        if (operand_type.len == 0) operand_type = word;
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
        if (successor(operand_type, predicate[0] == 's', right)) |next| {
            bound = try std.fmt.allocPrint(arena, "{d}", .{next});
            // `> c` is `>= c + 1`; `<= c` is `< c + 1`.
            predicate = if (predicate[0] == 'u')
                (if (strict_above) "uge" else "ult")
            else
                (if (strict_above) "sge" else "slt");
        }
    }
    return std.fmt.allocPrint(arena, "{s}{s} {s}{s}", .{ line[0..start], predicate, type_and_left.items, bound });
}

/// `constant + 1` when `text` is an integer constant of `operand_type` (`i32`)
/// that is not that type's largest value; null otherwise. LLVM prints
/// constants as signed, so the largest unsigned value reads `-1`.
fn successor(operand_type: []const u8, signed: bool, text: []const u8) ?i128 {
    if (operand_type.len < 2 or operand_type[0] != 'i') return null;
    const bits = std.fmt.parseInt(u16, operand_type[1..], 10) catch return null;
    if (bits == 0 or bits > 127) return null;
    const constant = std.fmt.parseInt(i128, text, 10) catch return null;
    const largest: i128 = if (signed) (@as(i128, 1) << @intCast(bits - 1)) - 1 else -1;
    if (constant == largest) return null;
    return constant + 1;
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

// --- tests ---------------------------------------------------------------------------------------

fn expectSame(expected: bool, comptime a: []const u8, comptime b: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrap = "define void @f(i32 %x, i32 %y) {\n";
    const one = try parse(arena, wrap ++ a ++ "\n}\n");
    const two = try parse(arena, wrap ++ b ++ "\n}\n");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqual(expected, same(one[0].instructions, two[0].instructions));
}

test "names, block order and phi input order do not matter" {
    try expectSame(true,
        \\  %a = add i32 %x, 1
        \\  %p = phi i32 [ %a, %first ], [ 0, %second ]
    ,
        \\  %"other name" = add i32 %x, 1
        \\  %7 = phi i32 [ 0, %b2 ], [ %"other name", %b1 ]
    );
    try expectSame(false, "  %a = add i32 %x, 1", "  %a = add i32 %x, 2");
    try expectSame(false, "  %a = add i32 %x, 1", "  %a = add i32 %x, 1\n  %b = add i32 %a, 1");
}

test "a comparison is never matched with its negation" {
    // Same shape, opposite test, same successors: different results.
    try expectSame(false,
        \\  %c = icmp ult i32 %x, %y
        \\  br i1 %c, label %a, label %b
    ,
        \\  %c = icmp uge i32 %x, %y
        \\  br i1 %c, label %a, label %b
    );
    try expectSame(false,
        \\  %c = icmp ult i32 %x, %y
        \\  ret i1 %c
    ,
        \\  %c = icmp uge i32 %x, %y
        \\  ret i1 %c
    );
    try expectSame(false,
        \\  %c = icmp eq i32 %x, %y
        \\  %s = select i1 %c, i32 %x, i32 %y
    ,
        \\  %c = icmp ne i32 %x, %y
        \\  %s = select i1 %c, i32 %x, i32 %y
    );
    // `x > 9` is `x >= 10`, not `x < 10`.
    try expectSame(false,
        \\  %c = icmp ugt i32 %x, 9
        \\  br i1 %c, label %a, label %b
    ,
        \\  %c = icmp ult i32 %x, 10
        \\  br i1 %c, label %a, label %b
    );
}

test "what it cannot see: the same instructions wired differently" {
    // A match of shape, not of meaning: the successors of a branch are block
    // names, which are erased. `behavior.zig` exists because of this.
    try expectSame(true,
        \\  %c = icmp ult i32 %x, %y
        \\  br i1 %c, label %a, label %b
    ,
        \\  %c = icmp ult i32 %x, %y
        \\  br i1 %c, label %b, label %a
    );
}

test "different predicates on the same operands differ" {
    try expectSame(false,
        \\  %c = icmp ult i32 %x, %y
        \\  br i1 %c, label %a, label %b
    ,
        \\  %c = icmp ule i32 %x, %y
        \\  br i1 %c, label %a, label %b
    );
}

test "the constant rewrite stops at the largest value of the type" {
    // No `c + 1` exists: left as written, and no overflow.
    try expectSame(true, "  %c = icmp sgt i127 %x, 85070591730234615865843651857942052863\n  ret i1 %c", "  %c = icmp sgt i127 %x, 85070591730234615865843651857942052863\n  ret i1 %c");
    try expectSame(true, "  %c = icmp sgt i128 %x, 170141183460469231731687303715884105727\n  ret i1 %c", "  %c = icmp sgt i128 %x, 170141183460469231731687303715884105727\n  ret i1 %c");
    try expectSame(false, "  %c = icmp sgt i8 %x, 127\n  ret i1 %c", "  %c = icmp sge i8 %x, -128\n  ret i1 %c");
    try expectSame(false, "  %c = icmp ugt i8 %x, -1\n  ret i1 %c", "  %c = icmp uge i8 %x, 0\n  ret i1 %c");
    // Below the largest value the rewrite is exact and applies to values too.
    try expectSame(true, "  %c = icmp ugt i8 %x, 9\n  ret i1 %c", "  %c = icmp uge i8 %x, 10\n  ret i1 %c");
    try expectSame(true, "  %c = icmp sle i8 %x, 9\n  ret i1 %c", "  %c = icmp slt i8 %x, 10\n  ret i1 %c");
}
