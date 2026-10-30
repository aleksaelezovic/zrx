const Terminal = @import("../internal/terminal.zig").Terminal;

/// Declare one fn ([]const T) void or E!void callback after successful input end,
/// including one empty-slice callback for empty input. Construction consumes/
/// allocates nothing; only run accumulates shallow items using std.ArrayList.
/// Typed comptime-known callbacks must accept a compatible read-only slice.
///
/// The slice is borrowed only during the callback, and freed afterward even on
/// callback error. Finish/join work using it before returning, or copy into
/// application-owned storage through collectThenWith. No deep copy/destructors
/// are inferred; item referents must survive the eventual callback too.
///
/// Source error, cancellation, or accumulation failure discards pending storage
/// without invoking the callback. Other flows may already have performed effects;
/// no rollback. An open empty source is not end; an endless source never invokes
/// this callback. Capacity does not bound accumulated memory: use maxItems to
/// guard item count or batchThen for incremental bounded processing.
/// Each collecting flow owns a separate buffer; run returns no owned result.
/// See examples/sequences.zig.
pub fn collectThen(comptime effect: anytype) Terminal(effect, false, .collection) {
    return .{ .capability = {} };
}
