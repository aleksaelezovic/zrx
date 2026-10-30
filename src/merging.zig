const std = @import("std");
const composition = @import("composition.zig");
const sequences = @import("sequences.zig");
const Tag = opaque {};

/// Describe concurrent fan-in. Run supplies all transport, Io, and allocation.
/// Preserve each input's order; cross-input interleaving is unspecified.
pub fn merge(inputs: anytype) Merged(@TypeOf(inputs)) {
    var result: Merged(@TypeOf(inputs)) = undefined;
    inline for (0..inputs.len) |i| result.inputs[i] = inputs[i];
    return result;
}

pub fn isMerge(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "merge_tag") and T.merge_tag == Tag;
}

fn Merged(comptime Inputs: type) type {
    if (comptime !composition.isTuple(Inputs))
        @compileError("merge: expected a nonempty flat tuple of inputs");
    const fields = @typeInfo(Inputs).@"struct".field_types;
    if (fields.len == 0) @compileError("merge: input tuple must not be empty");
    for (fields, 1..) |Input, index| {
        if (composition.isTuple(Input))
            @compileError(std.fmt.comptimePrint("merge: input {d} is a nested tuple; use a flat tuple or a merge declaration", .{index}));
    }
    const Element = sequences.Item(fields[0]);
    for (fields, 1..) |Input, index| {
        if (sequences.Item(Input) != Element)
            @compileError(std.fmt.comptimePrint("merge: input {d} must have the same item type as input 1; use each to convert explicitly", .{index}));
    }
    return struct {
        // Literal tuples can have comptime-only fields. Store ordinary fields so
        // run can take stable runtime addresses, including for by-value inputs.
        inputs: @Tuple(fields),
        pub const merge_tag = Tag;
        pub const graph_tag = sequences.GraphTag;
        pub const sequence_tag = sequences.SequenceTag;
        pub const Item = Element;
    };
}
