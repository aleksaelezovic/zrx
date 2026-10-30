const Terminal = @import("../internal/terminal.zig").Terminal;

/// forEach with fn (C, T) void or E!void, storing an explicit coerced capability
/// by value. Referenced resources remain caller-owned and must outlive run;
/// shared mutable referents need application synchronization.
pub fn forEachWith(capability: anytype, comptime effect: anytype) Terminal(effect, true, .each) {
    return .{ .capability = capability };
}
