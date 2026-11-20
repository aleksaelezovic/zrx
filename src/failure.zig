//! Failures as values: the item an error path is given, and the one place
//! that decides which errors something that takes failures takes.
//!
//! `recover`, `attempt` and `rescue` all do the same thing with an error:
//! take it if it is one of theirs, and otherwise let it go on, under a type
//! that says exactly what can still go on. That is written here once.
//! `Left` is that type and `take` is that decision; neither is inferred,
//! so an error that should not be left over does not compile.
const std = @import("std");

/// A failure as an item: the error, and the item it failed for as it was
/// where the failure was caught.
pub fn Failed(comptime E: type, comptime Item: type) type {
    return struct { err: E, item: Item };
}

/// What becomes of `error.Canceled` where failures are taken.
pub const Cancellation = enum {
    /// It is nobody's failure: an error path lets it pass, whatever its
    /// error set says. A cancellation is not an item's.
    passes,
    /// It is taken like any error the set holds: a rescue is where the run
    /// ends, and a cancellation ends it.
    taken,
};

const cancellation_name = "Canceled";

/// Whether something that takes the errors in `E` (an error set, or
/// `anyerror`) takes the error of this name.
pub fn takes(comptime E: type, comptime cancellation: Cancellation, comptime error_name: []const u8) bool {
    if (cancellation == .passes and std.mem.eql(u8, error_name, cancellation_name)) return false;
    const names = @typeInfo(E).error_set.error_names orelse return true; // anyerror
    for (names) |have| if (std.mem.eql(u8, have, error_name)) return true;
    return false;
}

/// The errors of `Possible` that are left when `E` has been taken from them,
/// as a set one could write: an inferred error set is a type of its own,
/// which nobody could name or switch over.
///
/// Where `Possible` is `anyerror`, nothing is known about what is left
/// unless `E` is `anyerror` too: then it is a cancellation, or nothing.
pub fn Left(comptime E: type, comptime cancellation: Cancellation, comptime Possible: type) type {
    const possible = @typeInfo(Possible).error_set.error_names orelse {
        if (@typeInfo(E).error_set.error_names != null) return anyerror;
        return if (cancellation == .passes) error{Canceled} else error{};
    };
    var Rest = error{};
    for (possible) |error_name| {
        if (!takes(E, cancellation, error_name)) Rest = Rest || @TypeOf(@field(anyerror, error_name));
    }
    return Rest;
}

/// `Possible` as one would write it.
pub fn Named(comptime Possible: type) type {
    return Left(error{}, .taken, Possible);
}

/// Whether `E` takes at least one error that `Possible` holds. Where
/// `Possible` is `anyerror`, that is whether `E` takes anything at all: a
/// set of nothing but a cancellation takes nothing where one passes.
pub fn takesAny(comptime E: type, comptime cancellation: Cancellation, comptime Possible: type) bool {
    const possible = @typeInfo(Possible).error_set.error_names orelse {
        const own = @typeInfo(E).error_set.error_names orelse return true; // anyerror
        inline for (own) |error_name| {
            if (comptime takes(E, cancellation, error_name)) return true;
        }
        return false;
    };
    inline for (possible) |error_name| {
        if (comptime takes(E, cancellation, error_name)) return true;
    }
    return false;
}

/// What `take` makes of an error: one that is taken, as the `E` it is, or
/// one that is left. A value and not an error union on purpose: an error
/// union whose payload is itself an error leaves it to coercion which of
/// the two a returned error is.
pub fn Taken(comptime E: type, comptime cancellation: Cancellation, comptime Possible: type) type {
    return union(enum) {
        taken: E,
        left: Left(E, cancellation, Possible),
    };
}

/// Sorts `err` into taken or left. An error that is left is given by its
/// name where the names are known, so that its type says exactly what is
/// left; return it and that is what the caller can still fail with.
pub fn take(comptime E: type, comptime cancellation: Cancellation, err: anytype) Taken(E, cancellation, @TypeOf(err)) {
    const any: anyerror = err;
    if (comptime @typeInfo(@TypeOf(err)).error_set.error_names) |possible| {
        inline for (possible) |error_name| {
            if (any == @field(anyerror, error_name)) {
                if (comptime !takes(E, cancellation, error_name)) return .{ .left = @field(anyerror, error_name) };
                return .{ .taken = @errorCast(any) };
            }
        }
        unreachable;
    }
    // Any error is possible.
    if (comptime @typeInfo(E).error_set.error_names) |names| {
        inline for (names) |error_name| {
            if (comptime takes(E, cancellation, error_name)) {
                if (any == @field(anyerror, error_name)) return .{ .taken = @errorCast(any) };
            }
        }
        return .{ .left = err };
    }
    if (comptime cancellation == .passes) {
        if (any == error.Canceled) return .{ .left = error.Canceled };
    }
    return .{ .taken = any };
}
