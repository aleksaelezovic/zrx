//! The one place that decides which errors are taken: `zrx.failure`.
//!
//! `recover`, `attempt` and `rescue` all ask it. Here it is asked directly,
//! for every combination of what is possible, what is to be taken and what
//! becomes of a cancellation.
const std = @import("std");
const zrx = @import("zrx");
const failure = zrx.failure;

/// What a stage can fail with, written out, and the same as an inferred set.
const Known = error{ Odd, TooBig, Canceled };

fn fails(value: u32) !void {
    switch (value) {
        1 => return error.Odd,
        2 => return error.TooBig,
        3 => return error.Canceled,
        else => {},
    }
}
const Inferred = @typeInfo(@typeInfo(@TypeOf(fails)).@"fn".return_type.?).error_union.error_set;

test "what is left is a set one could write, for every way of taking" {
    // Each row: what is to be taken, what a cancellation does, what is
    // possible, and what must be left of it.
    const rows = .{
        // An error path: a cancellation passes whatever the set says.
        .{ error{Odd}, .passes, Known, error{ TooBig, Canceled } },
        .{ error{ Odd, Canceled }, .passes, Known, error{ TooBig, Canceled } },
        .{ error{ Odd, TooBig }, .passes, Known, error{Canceled} },
        .{ anyerror, .passes, Known, error{Canceled} },
        .{ error{Never}, .passes, Known, error{ Odd, TooBig, Canceled } },
        .{ anyerror, .passes, error{ Odd, TooBig }, error{} },
        // A rescue: a cancellation is taken when the set holds it.
        .{ error{Odd}, .taken, Known, error{ TooBig, Canceled } },
        .{ error{ Odd, Canceled }, .taken, Known, error{TooBig} },
        .{ Known, .taken, Known, error{} },
        .{ anyerror, .taken, Known, error{} },
        // Where anything is possible, only taking everything says what is left.
        .{ anyerror, .passes, anyerror, error{Canceled} },
        .{ anyerror, .taken, anyerror, error{} },
        .{ error{Odd}, .passes, anyerror, anyerror },
        .{ error{Odd}, .taken, anyerror, anyerror },
    };
    inline for (rows) |row| {
        try std.testing.expect(failure.Left(row[0], row[1], row[2]) == row[3]);
        // An inferred set is a type of its own; what is left of it is not.
        if (row[2] == Known) try std.testing.expect(failure.Left(row[0], row[1], Inferred) == row[3]);
    }
    try std.testing.expect(Inferred != Known);
    try std.testing.expect(failure.Named(Inferred) == Known);
    try std.testing.expect(failure.Named(anyerror) == anyerror);
}

/// What `take` made of an error: `T` for taken, `L` for left, then its name.
fn sorted(comptime E: type, comptime cancellation: failure.Cancellation, err: anytype) struct { u8, anyerror } {
    return switch (failure.take(E, cancellation, err)) {
        .taken => |taken| .{ 'T', taken },
        .left => |rest| .{ 'L', rest },
    };
}

test "every error is either taken or left, and never changed" {
    const possible = [_]Known{ error.Odd, error.TooBig, error.Canceled };
    // Each row: what is to be taken, what a cancellation does, and what
    // becomes of Odd, TooBig and Canceled in that order.
    const rows = .{
        .{ error{Odd}, .passes, "TLL" },
        .{ error{ Odd, Canceled }, .passes, "TLL" },
        .{ anyerror, .passes, "TTL" },
        .{ error{Never}, .passes, "LLL" },
        .{ error{Odd}, .taken, "TLL" },
        .{ error{ Odd, Canceled }, .taken, "TLT" },
        .{ anyerror, .taken, "TTT" },
    };
    inline for (rows) |row| {
        for (possible, row[2]) |err, expected| {
            // With the names known, and where anything is possible.
            const known = sorted(row[0], row[1], err);
            const loose = sorted(row[0], row[1], @as(anyerror, err));
            try std.testing.expectEqual(expected, known[0]);
            try std.testing.expectEqual(expected, loose[0]);
            try std.testing.expectEqual(@as(anyerror, err), known[1]);
            try std.testing.expectEqual(@as(anyerror, err), loose[1]);
        }
    }
}

test "a set takes any of what is possible, or it would never be asked" {
    try std.testing.expect(failure.takesAny(error{Odd}, .passes, Known));
    try std.testing.expect(!failure.takesAny(error{Never}, .passes, Known));
    try std.testing.expect(!failure.takesAny(error{Canceled}, .passes, Known));
    try std.testing.expect(failure.takesAny(error{Canceled}, .taken, Known));
    try std.testing.expect(!failure.takesAny(anyerror, .passes, error{Canceled}));
    try std.testing.expect(failure.takesAny(error{Never}, .passes, anyerror));
}
