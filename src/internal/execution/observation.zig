//! Private, typed measurement checkpoints. Not an execution/tracing API.
//! Observers must be non-failing, allocation-free, non-reentrant and bounded.
//! All markers run on the coordinator, outside result/cache locks.
pub const Phase = enum {
    /// Terminal storage/readers and gated terminal/state workers are ready.
    /// Deferred producer/merge workers have not necessarily started.
    prepared,
    /// Resource acquisition/initial signal computation finished, before the gate.
    activation_ready,
    /// The coordinator observed the chosen execution outcome, before joining.
    /// Includes notification/scheduling delay after worker result selection.
    /// Earlier preparation/acquisition errors return without this marker.
    result_observed,
};

/// The normal public executor specializes on this zero-sized observer.
pub const Noop = struct {
    pub fn mark(_: Noop, comptime _: Phase) void {}
};
