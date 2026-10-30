const composition = @import("../internal/composition.zig");
const sequences = @import("../data/sequences.zig");

/// Describe lazy selection by one typed comptime-known fn (T) bool predicate.
/// Accept borrowed slices/array pointers, views, and stream inputs; never arrays
/// by value. Construction allocates nothing and invokes no predicate.
/// Consumption preserves order, examining only enough input to find the next
/// match; slice iteration reruns it, stream execution belongs to run.
/// Normal coercions apply; optional/error elements stay data. For a scalar ?T
/// result instead of element selection, use keepIf. See examples/sequences.zig.
pub fn filter(comptime predicate: anytype) Filter(predicate) {
    return .{};
}

fn Filter(comptime predicate: anytype) type {
    _ = composition.PredicateInput(predicate, "filter");
    return struct {
        pub fn Output(comptime Input: type) type {
            return Filtered(Input, predicate);
        }

        pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source };
        }
    };
}

fn Filtered(comptime Source: type, comptime predicate: anytype) type {
    const Element = sequences.Item(Source);
    // Check compatibility without executing a lazy callback.
    _ = @TypeOf(predicate(@as(Element, undefined)));
    return struct {
        source: Source,
        pub const sequence_tag = sequences.SequenceTag;
        pub const Item = Element;
        pub const declaration_source = Source;
        pub const declaration_kind = .filtered;
        pub const declaration_predicate = predicate;
        pub const Iterator = struct {
            input: sequences.Cursor(Source),

            pub fn next(self: *@This()) sequences.NextResult(Source, Element) {
                while (if (comptime sequences.isFallible(Source)) try self.input.next() else self.input.next()) |value| {
                    if (predicate(value)) return @as(?Element, value);
                }
                return null;
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .input = sequences.cursor(self.source) };
        }
    };
}
