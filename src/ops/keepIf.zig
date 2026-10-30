const composition = @import("../internal/composition.zig");

/// Call one typed comptime-known fn (T) bool predicate once. Return its coerced
/// input as ?T on a match, otherwise null. The next stage still receives that
/// optional: absence does not skip stages or unwrap an existing optional.
/// For selecting sequence elements instead, use filter.
pub fn keepIf(comptime predicate: anytype) KeepIf(predicate) {
    return .{};
}

fn KeepIf(comptime predicate: anytype) type {
    const Input = composition.PredicateInput(predicate, "keepIf");
    return struct {
        pub fn Output(comptime _: type) type {
            return ?Input;
        }

        pub fn apply(_: @This(), value: Input) ?Input {
            // Explicit returns avoid an optional-expression temporary observed
            // in the pinned LLVM output; no forced inlining is needed.
            if (predicate(value)) return value;
            return null;
        }
    };
}
