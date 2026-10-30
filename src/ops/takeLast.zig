const sequences = @import("../data/sequences.zig");

/// Describe final-suffix retention; even finite inputs require run rather than
/// direct iteration. Run preallocates a limit-item ring before activation,
/// consumes the full input, then publishes the suffix in source order only on
/// successful end. Short inputs publish all items. Zero still consumes/observes
/// errors but publishes none; an endless source never publishes a final suffix.
///
/// Failure/cancellation discards pending retention. Items are shallow; overwrites
/// infer no destructors, and referents must survive eventual downstream use.
/// The ring is freed after workers join, including preparation/startup failure.
/// It is separate from collectThen storage: no buffer transfer or deep memory
/// bound is promised. Stable references share one retained node per run.
///
/// maxItems before this guards total input; afterward it counts the suffix.
/// After merge this retains the chosen interleaving, not per-input suffixes.
/// Not a live drop-oldest policy. See examples/retention.zig.
pub fn takeLast(limit: usize) TakeLast {
    return .{ .limit = limit };
}

const TakeLast = struct {
    limit: usize,

    pub fn Output(comptime Input: type) type {
        const Element = sequences.Item(Input);
        return struct {
            source: Input,
            limit: usize,
            pub const sequence_tag = sequences.SequenceTag;
            pub const graph_tag = sequences.GraphTag;
            pub const Item = Element;
            pub const declaration_source = Input;
            pub const declaration_kind = .retained;
        };
    }

    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        return .{ .source = source, .limit = self.limit };
    }
};
