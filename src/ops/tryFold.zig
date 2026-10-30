const Fold = @import("fold.zig").Fold;

/// Eager left fold with fn (A, T) E!A: the success payload exactly matches A,
/// which cannot itself be an outer error union. All fold source, coercion,
/// ordering, shallow-seed, and ownership rules apply, including empty success.
/// An explicit error{}!A reducer is valid.
///
/// Stops at the first reducer error under either executor: failure on item k
/// means k reducer calls and k cursor probes, with no extra upstream evaluation.
/// pipe passes E!A onward as data; tryPipe checks it and skips later stages.
/// Neither inspects optional/error elements or nested state errors automatically.
///
/// Earlier effects remain and the local accumulator is not returned or cleaned
/// up on failure. Keep resources reachable from caller/helper defer scopes.
/// This operator handles reducer errors, not fallible source cursors or graphs.
pub fn tryFold(initial: anytype, comptime reducer: anytype) Fold(reducer, true) {
    return .{ .initial = initial };
}
