const sequences = @import("../data/sequences.zig");
const declarations = @import("../data/declarations.zig");

/// Validate the output count at this position, per cursor/run. Forward up to
/// limit items; consume but never forward the first excess item, then fail with
/// TooManyItems. Exactly limit still waits for end/excess; zero allows only empty
/// input. This is not prefix-taking, retention, or a lossy queue policy.
///
/// Before filter counts input; after it counts matches. Before collection bounds
/// accumulated item count, not arbitrary referent memory or upstream prefetch.
/// Failure discards partial collection/batches but cannot undo prior effects.
pub fn maxItems(limit: usize) MaxItems {
    return .{ .limit = limit };
}

const MaxItems = struct {
    limit: usize,

    pub fn Output(comptime Input: type) type {
        return Bounded(Input);
    }

    pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
        return .{ .source = source, .limit = self.limit };
    }
};

fn Bounded(comptime Source: type) type {
    declarations.requireSource(Source);
    const Element = sequences.Item(Source);
    return struct {
        source: Source,
        limit: usize,
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const Item = Element;
        pub const node_kind = .bounded;
        pub const Requirements = declarations.concat(declarations.requirements(Source), &.{});
    };
}
