const std = @import("std");
const decl = @import("../data/declarations.zig");
const seq = @import("../data/sequences.zig");
const chunks = @import("../data/chunks.zig");
const cb = @import("../internal/callbacks.zig");
pub const SplitOptions = @import("../internal/framing.zig").Options;

/// Frame arrays/slices/Chunks across input boundaries into owned bounded Chunks.
/// separator is a comptime delimiter value, pure typed fn(services..., T) bool,
/// or pure all/any predicate composition.
/// Delimiters are excluded. Defaults preserve empty delimited items and emit a
/// nonempty unfinished item only at normal end (no extra item after a delimiter).
/// Use empty=.skip for delimiter runs, e.g. an ASCII whitespace predicate.
/// Multi-element delimiter sequences/quoting/encoding are not inferred.
///
/// First upstream operation error discards unfinished state, forwards the pending
/// error and ends without another probe. Excess length emits pending FrameTooLong
/// then ends. Source/cancellation failures remain control and never flush state.
/// Raw Failure records must be handled before framing; no task/queue is added.
pub fn splitBy(comptime separator: anytype, comptime options: SplitOptions) Split(separator, options) {
    return .{};
}

fn Split(comptime separator: anytype, comptime options: SplitOptions) type {
    if (options.max_items == 0) @compileError("splitBy: max_items must be positive");
    return struct {
        pub fn Output(comptime Input: type) type {
            decl.requireSource(Input);
            const T = chunks.Element(seq.Item(Input));
            @import("../data/failures.zig").requireHandledBeforeDropping(T);
            const predicate = cb.isCallback(separator);
            if (predicate) {
                cb.validate(separator, &.{T});
                if (cb.Info(separator, 1).Return != bool)
                    @compileError("splitBy: predicate must return bool non-fallibly");
            } else {
                const delimiter: T = separator;
                _ = delimiter;
            }
            return struct {
                pub const graph_tag = seq.GraphTag;
                pub const sequence_tag = seq.SequenceTag;
                pub const node_kind = .split;
                pub const Item = chunks.Chunk(T, options.max_items);
                pub const split_options = options;
                pub const Requirements = decl.concat(decl.requirements(Input), if (predicate) &cb.Info(separator, 1).Services else &.{});
                source: Input,

                pub fn matches(env: anytype, element: T) bool {
                    return if (comptime predicate) cb.invoke(separator, env, .{element}) else std.meta.eql(element, @as(T, separator));
                }
            };
        }
        pub fn apply(_: @This(), input: anytype) Output(@TypeOf(input)) {
            return .{ .source = input };
        }
    };
}
