const std = @import("std");
const signal_kind = @import("signal_kind.zig");

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

pub fn UnaryInput(comptime callback: anytype, comptime prefix: []const u8) type {
    return callbackInfo(callback, prefix, 1).param_types[0].?;
}

pub fn callbackInfo(comptime callback: anytype, comptime prefix: []const u8, comptime arity: usize) std.lang.Type.Fn {
    const info = switch (@typeInfo(@TypeOf(callback))) {
        .@"fn" => |info| info,
        else => @compileError(prefix ++ " must be a function"),
    };
    const contract = prefix ++ (if (arity == 1)
        " must have one explicitly typed runtime parameter and an explicit return type"
    else
        " must have two explicitly typed runtime parameters and an explicit return type");
    if (info.is_generic or info.attrs.varargs or info.param_types.len != arity or info.return_type == null) {
        @compileError(contract);
    }
    for (info.param_types) |parameter| if (parameter == null) @compileError(contract);
    return info;
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
    validateOperators(Operators, "pipe");
    return ComposedOutput(Input, Operators, 0);
}

pub fn TryPipelineOutput(comptime Input: type, comptime Operators: type) type {
    validateOperators(Operators, "tryPipe");
    return TryComposedOutput(Input, Operators, 0);
}

fn validateOperators(comptime Operators: type, comptime name: []const u8) void {
    if (!isTuple(Operators)) @compileError(name ++ ": expected an operator tuple");
    const stages = @typeInfo(Operators).@"struct".field_types;
    if (stages.len == 0) @compileError(name ++ ": operator tuple must not be empty");
    for (stages, 1..) |Stage, index| {
        const prefix = std.fmt.comptimePrint("{s}: stage {d}", .{ name, index });
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

// Internal normalization metadata, not an additional custom-operator protocol.
// Expanding whole-value map tuples preserves their equivalence to separate
// map stages when the executor selects error short-circuiting.
pub const MapGroup = opaque {};

fn isMapGroup(comptime Step: type) bool {
    return @typeInfo(Step) == .@"struct" and @hasDecl(Step, "map_group") and
        Step.map_group == MapGroup;
}

pub fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.payload,
        else => T,
    };
}

fn Errors(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.error_set,
        else => error{},
    };
}

fn TryStepResult(comptime Input: type, comptime Step: type) type {
    if (isMapGroup(Step) and !signal_kind.isSignal(Input)) return TryValueOutput(Input, @TypeOf(Step.map_transforms), 0);
    const Result = StepOutput(Input, Step);
    if (@typeInfo(Result) == .error_set) {
        @compileError("tryPipe: bare error-set stage results are not supported; wrap error data in a struct");
    }
    return Result;
}

fn TryComposedOutput(comptime Input: type, comptime Steps: type, comptime index: usize) type {
    const Result = TryValueOutput(Payload(Input), Steps, index);
    return (Errors(Input) || Errors(Result))!Payload(Result);
}

fn TryValueOutput(comptime Input: type, comptime Steps: type, comptime index: usize) type {
    const fields = @typeInfo(Steps).@"struct".field_types;
    const Next = TryStepResult(Input, fields[index]);
    if (index == fields.len - 1) return Errors(Next)!Payload(Next);
    const Rest = TryValueOutput(Payload(Next), Steps, index + 1);
    return (Errors(Next) || Errors(Rest))!Payload(Rest);
}

pub fn tryCompose(value: anytype, steps: anytype, comptime index: usize) TryComposedOutput(@TypeOf(value), @TypeOf(steps), index) {
    const input = if (comptime @typeInfo(@TypeOf(value)) == .error_union) try value else value;
    return tryComposeValue(input, steps, index);
}

// Only this executor unwraps results. Its input has already crossed the previous
// boundary: a nested payload error union is data, not another automatic try.
fn tryComposeValue(value: anytype, steps: anytype, comptime index: usize) TryValueOutput(@TypeOf(value), @TypeOf(steps), index) {
    const Step = @TypeOf(steps[index]);
    const result = if (comptime isMapGroup(Step) and !signal_kind.isSignal(@TypeOf(value)))
        tryComposeValue(value, Step.map_transforms, 0)
    else
        invoke(value, steps[index]);
    const next = if (comptime @typeInfo(@TypeOf(result)) == .error_union) try result else result;
    if (index == steps.len - 1) return next;
    return tryComposeValue(next, steps, index + 1);
}
