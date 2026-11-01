const sequences = @import("../data/sequences.zig");
const kind = @import("../internal/signal_kind.zig");

/// Pair each event with a current shallow snapshot: @Tuple(&.{ Event, State }).
/// Tuple-valued events/state remain nested; nothing is flattened or consumed.
/// State changes alone emit nothing. The selected dependency keeps consuming
/// updates while events are idle, retaining current/candidate state, not history.
///
/// Requests ending completes this flow without waiting for updates. Final state
/// remains sampleable after normal update end, but update failure fails the run
/// even with idle samplers/no observers. Dependencies are run-scoped.
/// Separate input sources have no causal/wall-clock ordering guarantee, and
/// chained samples are separate reads, not a multi-root atomic snapshot.
/// Use an explicit application protocol when a request must see a given update.
pub fn withLatestFrom(signal: anytype) Sample(@TypeOf(signal)) {
    return .{ .signal = signal };
}

fn Sample(comptime Signal: type) type {
    const T = kind.Value(Signal);
    return struct {
        signal: Signal,
        pub fn Output(comptime Input: type) type {
            @import("../data/failures.zig").requireHandledBeforeDropping(sequences.Item(Input));
            const Pair = @Tuple(&.{ sequences.Item(Input), T });
            return struct {
                source: Input,
                signal: Signal,
                pub const signal_sample_tag = kind.SampleTag;
                pub const graph_tag = sequences.GraphTag;
                pub const sequence_tag = sequences.SequenceTag;
                pub const Item = Pair;
            };
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .signal = self.signal };
        }
    };
}
