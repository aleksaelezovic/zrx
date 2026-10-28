const std = @import("std");

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

pub fn UnaryInput(comptime callback: anytype, comptime prefix: []const u8) type {
    const info = switch (@typeInfo(@TypeOf(callback))) {
        .@"fn" => |info| info,
        else => @compileError(prefix ++ " must be a function"),
    };
    if (info.is_generic or info.attrs.varargs or info.param_types.len != 1 or
        info.param_types[0] == null or info.return_type == null)
    {
        @compileError(prefix ++ " must have one explicitly typed runtime parameter and an explicit return type");
    }
    return info.param_types[0].?;
}

pub fn PredicateInput(comptime predicate: anytype, comptime name: []const u8) type {
    const Input = UnaryInput(predicate, name ++ ": predicate");
    if (@typeInfo(@TypeOf(predicate)).@"fn".return_type.? != bool) {
        @compileError(name ++ ": predicate must return bool");
    }
    return Input;
}

pub fn functions(comptime transforms: anytype, comptime name: []const u8) if (isTuple(@TypeOf(transforms))) @TypeOf(transforms) else @TypeOf(.{transforms}) {
    const result = if (isTuple(@TypeOf(transforms))) transforms else .{transforms};
    if (result.len == 0) @compileError(name ++ ": transformer tuple must not be empty");
    for (result, 1..) |transform, index| {
        const prefix = std.fmt.comptimePrint("{s}: transformer {d}", .{ name, index });
        if (isTuple(@TypeOf(transform))) {
            @compileError(prefix ++ " is a nested tuple; use a flat tuple or a named helper operator");
        }
        _ = UnaryInput(transform, prefix);
    }
    return result;
}

pub fn PipelineOutput(comptime Input: type, comptime Operators: type) type {
    if (!isTuple(Operators)) @compileError("pipe: expected an operator tuple");
    const stages = @typeInfo(Operators).@"struct".field_types;
    if (stages.len == 0) @compileError("pipe: operator tuple must not be empty");
    for (stages, 1..) |Stage, index| {
        const prefix = std.fmt.comptimePrint("pipe: stage {d}", .{index});
        if (isTuple(Stage)) {
            @compileError(prefix ++ " is a nested tuple; use a flat tuple or a named helper operator");
        }
        const contract = prefix ++ " must provide Output(comptime Input: type) type and apply(self, value)";
        if (@typeInfo(Stage) != .@"struct" or !@hasDecl(Stage, "Output") or !@hasDecl(Stage, "apply")) {
            @compileError(contract);
        }
        const output = switch (@typeInfo(@TypeOf(Stage.Output))) {
            .@"fn" => |info| info,
            else => @compileError(contract),
        };
        const apply = switch (@typeInfo(@TypeOf(Stage.apply))) {
            .@"fn" => |info| info,
            else => @compileError(contract),
        };
        if (output.param_types.len != 1 or output.param_types[0] != type or output.return_type != type or
            output.attrs.varargs or apply.param_types.len != 2 or apply.param_types[0] != Stage or apply.attrs.varargs)
        {
            @compileError(contract);
        }
    }
    return ComposedOutput(Input, Operators, 0);
}

fn StepOutput(comptime Input: type, comptime Step: type) type {
    return switch (@typeInfo(Step)) {
        .@"fn" => |info| info.return_type.?,
        else => Step.Output(Input),
    };
}

pub fn ComposedOutput(comptime Input: type, comptime Steps: type, comptime index: usize) type {
    const fields = @typeInfo(Steps).@"struct".field_types;
    const Next = StepOutput(Input, fields[index]);
    if (index == fields.len - 1) return Next;
    return ComposedOutput(Next, Steps, index + 1);
}

fn invoke(value: anytype, step: anytype) StepOutput(@TypeOf(value), @TypeOf(step)) {
    return switch (@typeInfo(@TypeOf(step))) {
        .@"fn" => step(value),
        else => step.apply(value),
    };
}

// One sequence rule handles whole-value maps, elementwise maps, and pipelines.
// Callback values live in their tuple types; operator instances may carry state.
pub fn compose(value: anytype, steps: anytype, comptime index: usize) ComposedOutput(@TypeOf(value), @TypeOf(steps), index) {
    if (index == steps.len - 1) return invoke(value, steps[index]);
    return compose(invoke(value, steps[index]), steps, index + 1);
}
