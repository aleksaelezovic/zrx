//! Signal declarations describe run-owned current state, never live refs.
//! Infer their types from hold/map: no public owning Signal(T), getter/setter,
//! allocator, Io, or deinit is needed at declaration time.
//!
//! Only reachable state is instantiated. Stable pointer references share caches/
//! derivations within a run; by-value descriptions are independent. A new run
//! starts from declared initial state, not prior history or reset external state.
//!
//! Values/snapshots copy T shallowly, not pointers to mutable cache slots.
//! Replacement does not destroy referents. Pointer/slice referents must remain
//! stable for older queued, batched, or collected snapshots too. Mutating a pointee
//! is not an implicit update. Prefer value records or stable immutable storage.
//! See docs/state.md for coherence, observation, and completion across operators.
const kind = @import("../internal/signal_kind.zig");

pub fn Mapped(comptime Source: type, comptime functions: anytype) type {
    const U = block: {
        var Current = kind.Value(Source);
        for (functions) |transform| {
            Current = @TypeOf(transform(@as(Current, undefined)));
            // Every boundary must also be valid as a separate signal map.
            if (@sizeOf(Current) == 0)
                @compileError("map: signal transforms must return nonzero-sized values; use values and terminal effects");
        }
        break :block Current;
    };
    return struct {
        source: Source,
        pub const signal_tag = kind.Tag;
        pub const signal_kind = .mapped;
        pub const signal_functions = functions;
        pub const Value = U;
    };
}
