//! Bound branch descriptions used only by the graph coordinator. Public case
//! validation/dependency inference lives in ops/branch.zig; callbacks are bound
//! by execution/bind.zig before activation.
const sequences = @import("../data/sequences.zig");
const execution = @import("graph_run.zig");
const BranchTag = opaque {};
const InputTag = opaque {};

pub fn CaseOutput(comptime _: type, comptime C: type) type {
    return C.Pipeline;
}
pub fn Terminates(comptime Item: type, comptime Cases: type) bool {
    return execution.isFlowType(CaseOutput(Item, @typeInfo(Cases).@"struct".field_types[0]));
}

/// Only value-producing branches reach graph resolution. All-terminating cases
/// are represented directly by graph_run.BranchFlow.
pub fn Descriptor(comptime Source: type, comptime Cases: type) type {
    return struct {
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const branch_tag = BranchTag;
        pub const Item = sequences.Item(CaseOutput(sequences.Item(Source), @typeInfo(Cases).@"struct".field_types[0]));
        source: Source,
        cases: Cases,
    };
}
pub fn isBranch(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "branch_tag") and T.branch_tag == BranchTag;
}

// Each case starts from a run-owned outlet, not from a temporary singleton.
pub fn Input(comptime T: type) type {
    return struct {
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const input_tag = InputTag;
        pub const Item = T;
        node: *anyopaque,
    };
}
pub fn isInput(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "input_tag") and T.input_tag == InputTag;
}
