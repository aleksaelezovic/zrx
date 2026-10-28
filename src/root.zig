const std = @import("std");

// A private tag keeps the first milestone's operator contract deliberately small.
// Named helpers can return map operators without exposing a custom operator ABI.
const OperatorTag = opaque {};

/// Apply a nonempty, flat tuple of map operators in left-to-right order.
/// Operators and transformers are comptime-known; the input may be a runtime value.
/// Uses ordinary Zig calls and coercions, without allocation or implicit error handling.
/// Ownership and lifetimes follow the transformers; borrowed results are not extended.
pub fn pipe(value: anytype, comptime operators: anytype) PipelineOutput(operators) {
    return compose(value, operators, 0);
}

/// Construct an operator from one typed unary function or a nonempty, flat tuple
/// of such functions. Tuple transforms compose left to right, not in parallel.
pub fn map(comptime transforms: anytype) Map(transforms) {
    // The specialized type carries the functions; the operator needs no fields.
    // pipe executes the transformations through that type's apply function.
    return .{};
}

fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

fn Map(comptime transforms: anytype) type {
    const functions = if (isTuple(@TypeOf(transforms))) transforms else .{transforms};
    if (functions.len == 0) @compileError("map: transformer tuple must not be empty");

    for (functions, 1..) |transform, index| {
        const prefix = std.fmt.comptimePrint("map: transformer {d}", .{index});
        if (isTuple(@TypeOf(transform))) {
            @compileError(prefix ++ " is a nested tuple; use a flat tuple or a named helper operator");
        }
        const info = switch (@typeInfo(@TypeOf(transform))) {
            .@"fn" => |info| info,
            else => @compileError(prefix ++ " must be a function"),
        };
        if (info.is_generic or info.attrs.varargs or info.param_types.len != 1 or
            info.param_types[0] == null or info.return_type == null)
        {
            @compileError(prefix ++ " must have one explicitly typed runtime parameter and an explicit return type");
        }
    }

    return struct {
        pub const operator_tag = OperatorTag;
        const Output = @typeInfo(@TypeOf(functions[functions.len - 1])).@"fn".return_type.?;

        fn apply(value: anytype) Output {
            return compose(value, functions, 0);
        }
    };
}

fn PipelineOutput(comptime operators: anytype) type {
    if (!isTuple(@TypeOf(operators))) @compileError("pipe: expected an operator tuple");
    if (operators.len == 0) @compileError("pipe: operator tuple must not be empty");

    for (operators, 1..) |operator, index| {
        const T = @TypeOf(operator);
        const prefix = std.fmt.comptimePrint("pipe: stage {d}", .{index});
        if (isTuple(T)) {
            @compileError(prefix ++ " is a nested tuple; use a flat tuple or a named helper operator");
        }
        if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "operator_tag") or
            T.operator_tag != OperatorTag)
        {
            @compileError(prefix ++ " must be an operator returned by map or a named helper");
        }
    }

    return @TypeOf(operators[operators.len - 1]).Output;
}

fn OutputType(comptime step: anytype) type {
    return switch (@typeInfo(@TypeOf(step))) {
        .@"fn" => |info| info.return_type.?,
        else => @TypeOf(step).Output,
    };
}

fn invoke(value: anytype, comptime step: anytype) OutputType(step) {
    return switch (@typeInfo(@TypeOf(step))) {
        .@"fn" => step(value),
        else => @TypeOf(step).apply(value),
    };
}

// Both map forms and the pipeline share this nonempty sequence rule.
fn compose(value: anytype, comptime steps: anytype, comptime index: usize) OutputType(steps[steps.len - 1]) {
    if (index == steps.len - 1) return invoke(value, steps[index]);
    return compose(invoke(value, steps[index]), steps, index + 1);
}
