const Terminal = @import("../internal/terminal.zig").Terminal;

/// batchThen with fn (C, []const T) void or E!void. Capability coercion, storage,
/// and borrowed lifetimes follow the other With terminals: C is copied, referents
/// remain application-owned and must outlive run. Shared mutable services require
/// synchronization across flows. A retained batch requires an explicit owned copy.
pub fn batchThenWith(size: usize, capability: anytype, comptime effect: anytype) Terminal(effect, true, .batch) {
    return .{ .capability = capability, .batch_size = size };
}
