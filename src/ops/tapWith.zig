const Effect = @import("tap.zig").Effect;

/// tap with an explicit capability before the value: fn (C, T) void or E!void.
/// Forward the coerced T (or E!T), with the same whole-value/error/ownership
/// rules as tap. C is stored by value and need not be a pointer: use standard
/// writers, Io, or caller-owned state directly, without a universal context.
/// Borrowed referents must outlive use; no implicit close/free/flush occurs.
pub fn tapWith(capability: anytype, comptime effect: anytype) Effect(effect, true) {
    return .{ .capability = capability };
}
