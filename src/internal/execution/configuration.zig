//! Validate built-in runtime configuration without acquiring resources or
//! invoking callbacks. Also used for case pipelines constructed during lowering.
pub fn validate(input: anytype) !void {
    const T = @TypeOf(input);
    if (comptime @typeInfo(T) == .pointer) return validate(input.*);
    if (comptime @typeInfo(T) != .@"struct") return;
    if (comptime @hasDecl(T, "node_kind") and T.node_kind == .retry)
        try T.retry_meta.validate(input.policy);
    if (comptime @hasField(T, "source")) try validate(input.source);
    if (comptime @hasField(T, "signal")) try validate(input.signal);
    if (comptime @hasField(T, "inputs")) inline for (input.inputs) |source| try validate(source);
    if (comptime @hasField(T, "cases")) try validate(input.cases);
    if (comptime @hasField(T, "operators")) try validate(input.operators);
    if (comptime @typeInfo(T).@"struct".is_tuple) inline for (input) |item| try validate(item);
}
