//! Operation failures travel with items. Outer errors remain execution control.
const std = @import("std");

pub fn Outcome(comptime T: type) type {
    return union(enum) { value: T, failure: anyerror };
}

pub fn matches(comptime E: type, err: anyerror) bool {
    if (@typeInfo(E) != .error_set) @compileError("error handler: expected an error set");
    const members = @typeInfo(E).error_set.error_names orelse return true;
    inline for (members) |member| {
        if (err == @field(anyerror, member)) return true;
    }
    return false;
}

pub fn failed(comptime T: type, err: anyerror) std.Io.Cancelable!Outcome(T) {
    if (err == error.Canceled) return error.Canceled;
    return .{ .failure = err };
}

pub fn unwrap(comptime T: type, item: ?Outcome(T)) anyerror!?T {
    const outcome = item orelse return null;
    return switch (outcome) {
        .value => |value| @as(?T, value),
        .failure => |err| err,
    };
}

pub fn next(comptime T: type, cursor: anytype) anyerror!?Outcome(T) {
    if (@hasDecl(@typeInfo(@TypeOf(cursor)).pointer.child, "nextOutcome"))
        return cursor.nextOutcome();
    const result = cursor.next();
    const value = (if (@typeInfo(@TypeOf(result)) == .error_union) try result else result) orelse return null;
    return .{ .value = value };
}
