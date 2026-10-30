const composition = @import("../internal/composition.zig");
const signals = @import("../data/signals.zig");
const signal_kind = @import("../internal/signal_kind.zig");

/// Transform one whole value with a typed unary function or a nonempty flat
/// tuple of functions, composed left to right. Equivalent to consecutive maps
/// under either executor, including type transitions. Generic callbacks,
/// function pointers, and closures are unsupported; normal Zig coercions apply.
///
/// Arrays, slices, and views stay whole values; use each for elements. A signal
/// instead produces a deferred, pure whole-current-value derivation for run.
/// Signal maps preserve error/optional state as data even under tryPipe.
/// Purity is the caller's contract, not a comptime proof.
///
/// No forced inlining or SIMD mode: ordinary optimization and typed @Vector
/// callbacks work without a separate operator. See examples/pipeline.zig and
/// examples/signals.zig.
pub fn map(comptime transforms: anytype) Map(transforms) {
    // Functions live in the specialized type; the operator needs no fields.
    return .{};
}

fn Map(comptime transforms: anytype) type {
    const functions = composition.functions(transforms, "map");
    return struct {
        pub const map_group = composition.MapGroup;
        pub const map_transforms = functions;

        pub fn Output(comptime Input: type) type {
            if (signal_kind.isSignal(Input)) return signals.Mapped(Input, functions);
            return composition.ComposedOutput(Input, @TypeOf(functions), 0);
        }

        pub fn apply(_: @This(), value: anytype) Output(@TypeOf(value)) {
            if (comptime signal_kind.isSignal(@TypeOf(value))) return .{ .source = value };
            return composition.compose(value, functions, 0);
        }
    };
}
