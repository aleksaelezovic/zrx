const sequences = @import("../data/sequences.zig");

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
    const Element = sequences.Item(Source);
    return struct {
        source: Source,
        limit: usize,
        pub const sequence_tag = sequences.SequenceTag;
        pub const Item = Element;
        pub const declaration_source = Source;
        pub const declaration_kind = .bounded;
        pub const Iterator = struct {
            input: sequences.Cursor(Source),
            remaining: usize,

            pub fn next(self: *@This()) (sequences.Errors(Source) || error{TooManyItems})!?Element {
                const value = (if (comptime sequences.isFallible(Source)) try self.input.next() else self.input.next()) orelse return null;
                if (self.remaining == 0) return error.TooManyItems;
                self.remaining -= 1;
                return @as(?Element, value);
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .input = sequences.cursor(self.source), .remaining = self.limit };
        }
    };
}
