const composition = @import("../internal/composition.zig");
const sequences = @import("../data/sequences.zig");

/// Eager seeded left fold over a finite infallible cursor. Reducer is one
/// comptime-known fn (A, T) A with typed runtime parameters; the result must
/// exactly match A, which cannot be an outer error union. Seed/element use
/// normal coercions; seed is stored as A at construction, without traversal.
/// Use tryFold for a reducer returning E!A.
///
/// Each application starts a fresh cursor and shallow seed copy, not the last
/// result. Empty/all-filtered input returns that seed without reducer calls.
/// n yielded items mean n reducer calls and n+1 probes on normal completion;
/// filters can examine more underlying items. No reassociation or parallelism.
/// Slice views replay; fromIterator resumes its shared position.
///
/// No allocation, clone, cleanup, or rollback. Seed pointers keep aliasing their
/// referents; capabilities can live in accumulator fields, without a foldWith.
/// Keep ownership in caller/helper scopes and never return pointers to temporary
/// accumulator storage. Large states may copy; no copy-elision guarantee.
/// Run-backed/fallible source cursors are rejected; reduce a collectThen callback
/// slice when needed. See examples/reduction.zig.
pub fn fold(initial: anytype, comptime reducer: anytype) Fold(reducer, false) {
    return .{ .initial = initial };
}

// Shared specialization for fold/tryFold, not an additional public operator.
pub fn Fold(comptime reducer: anytype, comptime fallible: bool) type {
    const name = if (fallible) "tryFold" else "fold";
    const info = composition.callbackInfo(reducer, name ++ ": reducer", 2);
    const State = info.param_types[0].?;
    const Result = info.return_type.?;
    if (!fallible and @typeInfo(Result) == .error_union) {
        @compileError("fold: reducer must not return an outer error union; use tryFold");
    }
    if (@typeInfo(State) == .error_union) {
        @compileError(name ++ ": accumulator must not be an outer error union; wrap error data in a struct");
    }
    if (fallible) {
        if (@typeInfo(Result) != .error_union) {
            @compileError("tryFold: reducer must return an error union with the accumulator type as payload");
        }
        if (@typeInfo(Result).error_union.payload != State) {
            @compileError("tryFold: reducer success payload must exactly match the accumulator type");
        }
    } else if (Result != State) {
        @compileError("fold: reducer result must exactly match the accumulator type");
    }
    return struct {
        initial: State,

        pub fn Output(comptime Input: type) type {
            if (sequences.isGraph(Input)) {
                @compileError(name ++ ": run-backed sources cannot be reduced eagerly; use a terminal flow");
            }
            if (sequences.isFallible(Input)) {
                @compileError(name ++ ": fallible sequence cursors are not supported; reduce an infallible finite source");
            }
            // Check even empty sources, without running callbacks.
            _ = @TypeOf(reducer(@as(State, undefined), @as(sequences.Item(Input), undefined)));
            return Result;
        }

        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            var state = self.initial;
            var input = sequences.cursor(source);
            while (input.next()) |value| {
                state = if (comptime fallible) try reducer(state, value) else reducer(state, value);
            }
            return state;
        }
    };
}
