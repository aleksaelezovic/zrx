const composition = @import("../internal/composition.zig");
const sequences = @import("../data/sequences.zig");
const signal_kind = @import("../internal/signal_kind.zig");

/// Map sequence elements lazily with one typed comptime-known unary function
/// or a nonempty flat tuple. Compose left to right with normal coercions and
/// type transitions. No allocation/callbacks on construction; source order and
/// optional/error-valued elements are preserved during consumption.
/// Slice views are repeatable; stream views execute through run. This is not
/// an effect-only traversal: use forEach for terminal effects, map for whole
/// values/current signal state, or each on values(signal) for snapshots.
/// Ordinary optimization may fuse/vectorize loops, but no SIMD guarantee is made.
pub fn each(comptime transforms: anytype) Each(transforms) {
    return .{};
}

fn Each(comptime transforms: anytype) type {
    const functions = composition.functions(transforms, "each");
    return struct {
        pub fn Output(comptime Input: type) type {
            if (signal_kind.isSignal(Input)) @compileError("each: use map for signals, or each on values(signal)");
            return Mapped(Input, functions);
        }

        pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source };
        }
    };
}

fn Mapped(comptime Source: type, comptime functions: anytype) type {
    const Element = block: {
        var Current = sequences.Item(Source);
        for (functions) |transform| Current = @TypeOf(transform(@as(Current, undefined)));
        break :block Current;
    };
    return struct {
        source: Source,
        pub const sequence_tag = sequences.SequenceTag;
        pub const Item = Element;
        pub const declaration_source = Source;
        pub const declaration_kind = .mapped;
        pub const declaration_functions = functions;
        pub const Iterator = struct {
            input: sequences.Cursor(Source),

            pub fn next(self: *@This()) sequences.NextResult(Source, Element) {
                const value = (if (comptime sequences.isFallible(Source)) try self.input.next() else self.input.next()) orelse return null;
                // The optional boundary keeps element errors/nulls inside the item.
                return @as(?Element, composition.compose(value, functions, 0));
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .input = sequences.cursor(self.source) };
        }
    };
}
