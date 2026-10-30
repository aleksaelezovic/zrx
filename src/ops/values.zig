const sequences = @import("../data/sequences.zig");
const kind = @import("../internal/signal_kind.zig");

/// Describe a lossless snapshot stream: initial state once, then every committed
/// replacement, including equal values/equal derived results. No equality or
/// coalescing policy. Run supplies one capacity-one publication buffer per
/// observed signal and independent reader positions for consumers.
///
/// Slow readers backpressure publication. A slot is released after all readers
/// read it, not necessarily after effects finish. Commit precedes notification;
/// samplers can see a new value before an observer renders it. Unselected
/// observations create no hidden reader. Collection/batching count initial state.
/// Normal update end drains/closes observation but leaves the cache sampleable
/// until run cleanup; failure may discard pending notifications.
pub fn values(signal: anytype) Values(@TypeOf(signal)) {
    return .{ .signal = signal };
}

fn Values(comptime Signal: type) type {
    const T = kind.Value(Signal);
    return struct {
        signal: Signal,
        pub const signal_values_tag = kind.ValuesTag;
        pub const graph_tag = sequences.GraphTag;
        pub const sequence_tag = sequences.SequenceTag;
        pub const Item = T;
    };
}
