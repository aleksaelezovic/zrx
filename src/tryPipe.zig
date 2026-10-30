const composition = @import("internal/composition.zig");

/// Check the input's outer error union, then each eager stage result, returning
/// immediately on the first error. Always returns E!T; E merges input/stage
/// errors (error{} for an infallible pipeline), T is the final success payload.
/// Requires the same nonempty, flat operator tuple and coercions as pipe.
///
/// Grouped ordinary maps behave as consecutive maps: failure skips remaining
/// transforms. Only one outer union is checked at each boundary, as with Zig try.
/// Optional values, sequence-element errors, and errors nested in payloads stay
/// data. Initial bare error values can be transformed into supported payloads;
/// bare error-set stage results are rejected because Zig cannot form E!ErrorSet.
/// Wrap such data in a struct.
///
/// Does not enter custom operators, lazy each loops, or deferred signal state.
/// tryFold supplies its own per-item stopping rule. A named helper using tryPipe
/// can delimit a fail-fast region inside pipe; no stage changes executor policy.
///
/// No rollback, retry, implicit allocation, scheduling, or cleanup of owned
/// intermediates. Keep ownership reachable in caller/helper defer/errdefer scopes;
/// otherwise a later failure can lose the only handle to an earlier allocation.
/// Descriptions still need run. See examples/try_pipe.zig.
pub fn tryPipe(value: anytype, operators: anytype) composition.TryPipelineOutput(@TypeOf(value), @TypeOf(operators)) {
    return composition.tryCompose(value, operators, 0);
}
