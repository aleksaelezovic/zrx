const composition = @import("composition.zig");
const sequences = @import("sequences.zig");

pub const filter = sequences.filter;
pub const each = sequences.each;
pub const collectInto = sequences.collectInto;
pub const collectAlloc = sequences.collectAlloc;

/// Apply a nonempty, flat tuple of operators from left to right.
/// Types and callbacks specialize at comptime; operator instances may carry
/// runtime capabilities. Errors/optionals are values, not implicit control flow.
/// Borrowed results retain their source's lifetime requirements.
pub fn pipe(value: anytype, operators: anytype) composition.PipelineOutput(@TypeOf(value), @TypeOf(operators)) {
    return composition.compose(value, operators, 0);
}

/// Construct an operator from one typed unary function or a nonempty, flat tuple
/// of such functions. Tuple transforms compose left to right, not in parallel.
pub fn map(comptime transforms: anytype) Map(transforms) {
    // Functions live in the specialized type; the operator needs no fields.
    return .{};
}

fn Map(comptime transforms: anytype) type {
    const functions = composition.functions(transforms, "map");
    return struct {
        pub fn Output(comptime Input: type) type {
            return composition.ComposedOutput(Input, @TypeOf(functions), 0);
        }

        pub fn apply(_: @This(), value: anytype) Output(@TypeOf(value)) {
            return composition.compose(value, functions, 0);
        }
    };
}

/// Keep one value as ?T when its typed predicate matches; otherwise return null.
/// This does not skip subsequent stages or unwrap an existing optional.
pub fn keepIf(comptime predicate: anytype) KeepIf(predicate) {
    return .{};
}

fn KeepIf(comptime predicate: anytype) type {
    const Input = composition.PredicateInput(predicate, "keepIf");
    return struct {
        pub fn Output(comptime _: type) type {
            return ?Input;
        }

        pub fn apply(_: @This(), value: Input) ?Input {
            // Explicit returns avoid an optional-expression temporary observed
            // in the pinned LLVM output; no forced inlining is needed.
            if (predicate(value)) return value;
            return null;
        }
    };
}
