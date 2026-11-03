const decl = @import("../data/declarations.zig");
const seq = @import("../data/sequences.zig");
const chunks = @import("../data/chunks.zig");

/// Expand each array, slice or Chunk into its elements, in order. Owns a shallow
/// copy of the current chunk: array/Chunk storage does not escape a callback.
/// Slice referents must stay valid/unchanged until that chunk is drained.
/// Empty chunks emit nothing; pending errors pass unchanged. No queue is added.
pub fn flatten() Flatten {
    return .{};
}

const Flatten = struct {
    pub fn Output(comptime Input: type) type {
        decl.requireSource(Input);
        const T = chunks.Element(seq.Item(Input));
        if (@sizeOf(T) == 0) @compileError("flatten: elements must have nonzero size");
        return struct {
            pub const graph_tag = seq.GraphTag;
            pub const sequence_tag = seq.SequenceTag;
            pub const node_kind = .flatten;
            pub const Item = T;
            pub const Requirements = decl.concat(decl.requirements(Input), &.{});
            source: Input,
        };
    }
    pub fn apply(_: @This(), input: anytype) Output(@TypeOf(input)) {
        return .{ .source = input };
    }
};
