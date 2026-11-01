const sequences = @import("../data/sequences.zig");
const declarations = @import("../data/declarations.zig");

/// Forward at most limit items in order, then end successfully without another
/// input probe. Short input ends normally; zero never calls the input cursor.
/// Counts items at this position: after filter counts matches, before it counts
/// input. Optional/error-valued elements stay data. Observed cursor errors
/// propagate; errors beyond the prefix are not probed for.
///
/// All inputs are cold declarations executed by run. Finite storage declared
/// with fromSlice replays; borrowed consuming iterators resume their position.
///
/// In run, completing a prefix detaches only its input edge. Shared siblings
/// continue; nodes without remaining stream demand stop and retire their own
/// input edges. Signal caches/updaters stay run-scoped. Upstream buffering/work
/// may get ahead: this does not guarantee exactly limit producer/callback calls
/// or roll back effects. Another branch or active signal can still fail the run.
///
/// Normal terminal completion includes flushing/final partial batches/suffixes.
/// Zero still follows run's selected-resource acquisition rules. Cleanup joins
/// workers before freeing resources; arbitrary noncooperative callbacks cannot
/// be forcibly stopped. This is neither maxItems validation nor takeLast.
pub fn take(limit: usize) Take {
    return .{ .limit = limit };
}

const Take = struct {
    limit: usize,

    pub fn Output(comptime Input: type) type {
        return Prefix(Input);
    }

    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        return .{ .source = source, .limit = self.limit };
    }
};

fn Prefix(comptime Source: type) type {
    declarations.requireSource(Source);
    const Element = sequences.Item(Source);
    return struct {
        source: Source,
        limit: usize,
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const Item = Element;
        pub const node_kind = .take;
        pub const Requirements = declarations.concat(declarations.requirements(Source), &.{});
    };
}
