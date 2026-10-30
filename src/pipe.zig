const composition = @import("internal/composition.zig");

/// Apply a nonempty, flat operator tuple left to right, using ordinary Zig
/// argument coercions. Empty/nested tuples and incompatible stages fail at comptime.
/// Errors and optionals remain values; use tryPipe for explicit fail-fast flow.
///
/// Operators are structs exposing Output(comptime Input: type) type and
/// apply(self: Self, value), with a result coercible to Output. Instances and self
/// are passed by value; runtime fields can carry explicit borrowed capabilities.
/// Named factories keep this protocol outside user-facing pipeline expressions.
///
/// This executor allocates, schedules, and cleans up nothing. Value stages run
/// now; a graph/terminal stage returns a description for run, not deferred
/// execution of arbitrary preceding effects. Borrowed results keep their source
/// lifetimes. See examples/pipeline.zig and examples/sequences.zig.
pub fn pipe(value: anytype, operators: anytype) composition.PipelineOutput(@TypeOf(value), @TypeOf(operators)) {
    return composition.compose(value, operators, 0);
}
