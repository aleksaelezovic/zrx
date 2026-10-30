const Terminal = @import("../internal/terminal.zig").Terminal;

/// Declare serial per-item effects: fn (T) void or E!void, with ordinary
/// coercions. Only run consumes input/calls effects, for finite inputs too.
/// Empty input calls none. Callback/source failure cancels peers without
/// undoing earlier effects; optional/error-valued items remain data.
/// Callbacks must be typed comptime-known functions, not generic functions,
/// closures, or caller-supplied pointers. Non-void payloads are rejected.
/// Independent flows can run concurrently; no tuple-order effect guarantee.
pub fn forEach(comptime effect: anytype) Terminal(effect, false, .each) {
    return .{ .capability = {} };
}
