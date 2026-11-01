const composition = @import("../internal/composition.zig");
const callbacks = @import("../internal/callbacks.zig");
const declarations = @import("../data/declarations.zig");
const sequences = @import("../data/sequences.zig");
const dependencies = @import("../internal/world/dependencies.zig");
const input = @import("../internal/branch.zig").Input;
const CaseTag = opaque {};

/// Ordered case with a typed fn (services..., item) bool predicate. Leading
/// services follow normal injection. Operators are one operator or a flat,
/// nonempty tuple, applied to a persistent substream, not per-item singletons.
pub fn when(comptime predicate: anytype, operators: anytype) Case(predicate, @TypeOf(operators), false) {
    if (callbacks.Info(predicate, 1).Return != bool)
        @compileError("when: predicate must return bool");
    return .{ .operators = normalize(operators) };
}

/// Optional final default case; must be last. No implicit fallback is added.
pub fn otherwise(operators: anytype) Case({}, @TypeOf(operators), true) {
    return .{ .operators = normalize(operators) };
}

/// Route matching pending operation errors to a persistent Failure(E) substream.
/// anyerror matches all operation errors, never cancellation or source failures.
/// Ordinary when/otherwise cases only select successes. Unmatched errors remain
/// pending; selecting an already retired error lane does not swallow the error.
pub fn whenError(comptime E: type, operators: anytype) ErrorCase(E, @TypeOf(operators)) {
    return .{ .operators = normalize(operators) };
}
fn ErrorCase(comptime E: type, comptime Operators: type) type {
    _ = @import("../data/failures.zig").Failure(E);
    return struct {
        pub const case_tag = CaseTag;
        pub const is_default = false;
        pub const is_error = true;
        pub const ErrorSet = E;
        operators: Normalized(Operators),
    };
}

fn Normalized(comptime T: type) type {
    return if (composition.isTuple(T)) T else @Tuple(&.{T});
}
fn normalize(operators: anytype) Normalized(@TypeOf(operators)) {
    return if (comptime composition.isTuple(@TypeOf(operators))) operators else .{operators};
}
fn Case(comptime predicate: anytype, comptime Operators: type, comptime default: bool) type {
    return struct {
        pub const case_tag = CaseTag;
        pub const is_default = default;
        pub const is_error = false;
        pub const condition = predicate;
        operators: Normalized(Operators),
    };
}

pub fn CaseOutput(comptime Item: type, comptime C: type) type {
    if (!C.is_default and !C.is_error) callbacks.validate(C.condition, &.{Item});
    return composition.PipelineOutput(input(CaseItem(Item, C)), @FieldType(C, "operators"));
}
pub fn CaseItem(comptime Item: type, comptime C: type) type {
    return if (C.is_error) @import("../data/failures.zig").Failure(C.ErrorSet) else Item;
}
fn isTerminal(comptime T: type) bool {
    return @hasDecl(T, "world_flow_tag") and T.world_flow_tag == dependencies.FlowTag;
}
fn terminates(comptime Item: type, comptime Cases: type) bool {
    const fields = @typeInfo(Cases).@"struct".field_types;
    const terminal = isTerminal(CaseOutput(Item, fields[0]));
    for (fields[1..]) |C| {
        if (isTerminal(CaseOutput(Item, C)) != terminal)
            @compileError("branch: cases must either all terminate or all produce sequences");
    }
    return terminal;
}
fn requirements(comptime Item: type, comptime Cases: type, comptime index: usize) []const type {
    const fields = @typeInfo(Cases).@"struct".field_types;
    if (index == fields.len) return &.{};
    const C = fields[index];
    const predicate = if (C.is_default or C.is_error) &.{} else &callbacks.Info(C.condition, 1).Services;
    const local = declarations.concat(predicate, declarations.requirements(CaseOutput(Item, C)));
    const rest = declarations.concat(&local, requirements(Item, Cases, index + 1));
    return &rest;
}
fn Result(comptime Item: type, comptime Cases: type) type {
    const fields = @typeInfo(Cases).@"struct".field_types;
    const T = sequences.Item(CaseOutput(Item, fields[0]));
    for (fields[1..]) |C| {
        if (sequences.Item(CaseOutput(Item, C)) != T)
            @compileError("branch: all output cases must have the same item type");
    }
    return T;
}

/// Cold exclusive routing. First matching case wins; predicates short-circuit.
/// All cases produce the same item type (per-case order, unspecified merged
/// interleaving), or all terminate and this is a selected terminal root.
/// Mixed cases fail compilation. Unmatched items and items for retired cases
/// are dropped; prefix completion retires only its case. All cases retired
/// stops the input edge. These drops apply only to success values. Pending
/// errors select whenError cases, or bypass value-producing branches unchanged;
/// an unhandled error at an all-terminal branch fails run. Error lanes wait for
/// callback/terminal acceptance, not mere queue admission. Retiring a selected
/// error lane before acceptance leaves the error pending. Reporting errors are
/// new failures, not recursively routed into the same branch.
///
/// Raw Failure records cannot be filtered, prefixed, retained, nested-routed
/// or used as signal state/events before explicit handling. Map them to reports,
/// handle with effects/reduction, or use discard; error sinks may batch/collect.
pub fn branch(cases: anytype) Branch(@TypeOf(cases)) {
    return .{ .cases = cases };
}
fn Branch(comptime Cases: type) type {
    if (!composition.isTuple(Cases))
        @compileError("branch: expected a nonempty flat tuple of when/otherwise cases");
    const fields = @typeInfo(Cases).@"struct".field_types;
    if (fields.len == 0) @compileError("branch: cases must not be empty");
    for (fields, 0..) |C, i| {
        if (@typeInfo(C) != .@"struct" or !@hasDecl(C, "case_tag") or C.case_tag != CaseTag)
            @compileError("branch: expected when/otherwise cases, not operators or nested tuples");
        if (C.is_default and i != fields.len - 1)
            @compileError("branch: otherwise must be the last case");
    }
    return struct {
        cases: Cases,
        pub fn Output(comptime Source: type) type {
            declarations.requireSource(Source);
            const In = sequences.Item(Source);
            @import("../data/failures.zig").requireHandledBeforeDropping(In);
            const terminal = terminates(In, Cases);
            const Out = comptime if (terminal) void else Result(In, Cases);
            if (terminal) return struct {
                pub const branch_source = true;
                pub const branch_terminal = true;
                pub const world_flow_tag = dependencies.FlowTag;
                pub const Requirements = declarations.concat(declarations.requirements(Source), requirements(In, Cases, 0));
                source: Source,
                cases: Cases,
            };
            return struct {
                pub const branch_source = true;
                pub const branch_terminal = false;
                pub const sequence_tag = sequences.SequenceTag;
                pub const graph_tag = sequences.GraphTag;
                pub const Item = Out;
                pub const Requirements = declarations.concat(declarations.requirements(Source), requirements(In, Cases, 0));
                source: Source,
                cases: Cases,
            };
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .cases = self.cases };
        }
    };
}
