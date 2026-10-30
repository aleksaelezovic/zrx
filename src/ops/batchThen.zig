const Terminal = @import("../internal/terminal.zig").Terminal;

/// Declare serial callbacks over successive batches: fn ([]const T) void or
/// E!void. A full batch is delivered while input is open, before reading the next
/// batch. Only successful end flushes a nonempty partial batch; empty input and
/// exact boundaries invoke no extra empty callback. Typed comptime-known callbacks
/// require a compatible read-only slice; generic/pointer/non-void forms fail.
///
/// Size is runtime configuration. Run preallocates one fixed size-item buffer
/// per selected terminal before activation. Zero returns InvalidBatchSize then,
/// not during declaration. Allocation/startup failure frees prepared buffers
/// without callbacks; buffers are freed only after consumer tasks join.
///
/// Every callback borrows the same reusable shallow storage only for that call.
/// Join work using it before returning or retain an application-owned copy via
/// batchThenWith. Referents keep their own lifetimes; no destructors are inferred.
/// Source error/cancellation discards a pending partial batch; callback failure
/// cancels peers without retry, rollback, or another flush.
///
/// A callback blocks this consumer's next read; upstream bounded buffers then
/// backpressure. No per-batch tasks, timer/deadline flush, or batch-valued stream.
/// Endless input can deliver full batches but a partial batch waits indefinitely.
/// maxItems counts items, takeLast delays all output, and merge supplies its
/// chosen interleaving. See examples/batching.zig.
pub fn batchThen(size: usize, comptime effect: anytype) Terminal(effect, false, .batch) {
    return .{ .capability = {}, .batch_size = size };
}
