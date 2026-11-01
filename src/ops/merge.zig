const std = @import("std");
const composition = @import("../internal/composition.zig");
const sequences = @import("../data/sequences.zig");
const declarations = @import("../data/declarations.zig");
const Tag = opaque {};

/// Describe concurrent fan-in. Run supplies all transport, Io, and allocation.
/// Preserve each input's order; cross-input interleaving is unspecified.
/// Accept a nonempty flat tuple of supported sequence inputs (one is allowed),
/// all with exactly the same item type. No widening, tagging, or unwrapping:
/// use each to convert domain inputs explicitly, e.g. into a tagged event union.
///
/// Each tuple entry is a delivery edge. Repeating &source duplicates delivery,
/// not producer activation. Referencing one stable merge shares its chosen
/// interleaving across consumers; by-value copies are independent descriptions.
/// Unused declarations claim no readers. Inputs/referents must outlive run.
///
/// Run supplies capacity-one output and one independently progressing sequential
/// forwarder per input. Each can hold one in-flight item besides input/output
/// buffers. Admission order is not tuple, timestamp, wall-clock, round-robin,
/// fairness, or deterministic order. An idle input does not block ready peers.
/// Full output backpressures workers. Local startup is gated; failure can return
/// ConcurrencyUnavailable rather than falling back to an inline blocking loop.
///
/// End only after all inputs end normally and accepted output drains. Input
/// failure records the first observed error and cancels/joins forwarders, with
/// no input-index priority or cleanup-error replacement. Other active flows may
/// already have effects; no rollback. Errors/optionals inside items remain data.
/// collectThen after merge waits for all inputs; takeLast/batches follow the
/// chosen interleaving (apply retention before merge for per-input suffixes).
/// No dynamic inputs, zip, or combine-latest is implied.
pub fn merge(inputs: anytype) Description(@TypeOf(inputs)) {
    inline for (@typeInfo(@TypeOf(inputs)).@"struct".field_types) |Input|
        declarations.requireSource(Input);
    var result: Description(@TypeOf(inputs)) = undefined;
    inline for (0..inputs.len) |i| result.inputs[i] = inputs[i];
    return result;
}

pub fn isMerge(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "merge_tag") and T.merge_tag == Tag;
}

// Also used by typed lowering after declaration inputs become bound cursors.
pub fn Description(comptime Inputs: type) type {
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
