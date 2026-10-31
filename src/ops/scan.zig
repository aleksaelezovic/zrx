const composition = @import("../internal/composition.zig");
const sequences = @import("../data/sequences.zig");

/// Describe a seeded serial accumulation stream. The reducer is one pure
/// comptime-known fn (A, T) A with explicitly typed runtime parameters and an
/// exact state result. A must be nonzero-sized and not an outer error union.
/// Seed/item arguments coerce normally; literal undefined seeds and fallible
/// reducers are rejected. Accept borrowed slices, array pointers, zrx sequence/
/// iterator views, and streams. Reject arrays by value and direct signals.
/// Output is a run-backed sequence declaration with item type A.
///
/// Always deferred through run, including for finite inputs. Construction
/// stores a shallow seed without traversal/allocation/callbacks. Each run starts
/// fresh, reduces in input order, and publishes one shallow A per processed
/// item, including equal results. Seed is not emitted; empty input emits none.
/// There is no extra final result. Eager finite fold remains a separate API.
///
/// Reducers must not perform effects, mutate borrowed referents, or return
/// pointers into temporary accumulator storage. Output copies A, not a pointer
/// to live state. Pointer/slice referents must stay valid and unchanged for older
/// queued/retained/sampled values too. No clone, destructor, or rollback is
/// inferred. Purity and referent safety are caller obligations.
///
/// Stable pointer references share one recurrence per run. Last-reader
/// retirement stops unused inputs; prefetch can process beyond a delivered take
/// prefix. Source errors/cancellation use normal run failure/join semantics;
/// optional/error-valued items stay data. Use hold(seed) for sampleable current
/// state and values for initial plus every replacement. See examples/scan.zig.
pub fn scan(initial: anytype, comptime reducer: anytype) Scan(reducer) {
    if (@TypeOf(initial) == @TypeOf(undefined))
        @compileError("scan: initial value must not be undefined");
    return .{ .initial = initial };
}

fn Scan(comptime reducer: anytype) type {
    const info = composition.callbackInfo(reducer, "scan: reducer", 2);
    const State = info.param_types[0].?;
    if (@typeInfo(State) == .error_union)
        @compileError("scan: accumulator must not be an outer error union; wrap error data in a struct");
    if (@typeInfo(info.return_type.?) == .error_union)
        @compileError("scan: fallible reducers are not supported");
    if (info.return_type.? != State)
        @compileError("scan: reducer result must exactly match the accumulator type");
    if (@sizeOf(State) == 0)
        @compileError("scan: zero-sized accumulator values are not supported");
    return struct {
        initial: State,

        pub fn Output(comptime Input: type) type {
            // Validate element coercion even for empty sources, without calling.
            _ = @TypeOf(reducer(@as(State, undefined), @as(sequences.Item(Input), undefined)));
            return struct {
                source: Input,
                initial: State,
                pub const sequence_tag = sequences.SequenceTag;
                pub const graph_tag = sequences.GraphTag;
                pub const Item = State;
                pub const declaration_source = Input;
                pub const declaration_kind = .scanned;
                pub const declaration_reducer = reducer;
            };
        }

        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .initial = self.initial };
        }
    };
}
