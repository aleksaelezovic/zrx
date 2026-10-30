const Terminal = @import("../internal/terminal.zig").Terminal;

/// collectThen with fn (C, []const T) void or E!void. Store a coerced capability
/// by value; its borrowed referents must outlive run. To retain the callback's
/// borrowed slice, explicitly copy into application-owned storage through C.
/// Copying the slice header alone neither retains backing storage nor deep-copies
/// item referents. Collection success/failure/cleanup rules are unchanged.
pub fn collectThenWith(capability: anytype, comptime effect: anytype) Terminal(effect, true, .collection) {
    return .{ .capability = capability };
}
