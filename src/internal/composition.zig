//! Shared declaration composition and type utilities. Execution belongs to run.
const std = @import("std");

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

pub fn PipelineOutput(comptime Input: type, comptime Operators: type) type {
    // Validation of nested typed declarations needs a compiler-only budget.
    @setEvalBranchQuota(15_000);
    if (!isTuple(Operators)) @compileError("pipe: expected an operator tuple");
    const stages = @typeInfo(Operators).@"struct".field_types;
    if (stages.len == 0) @compileError("pipe: operator tuple must not be empty");
    for (stages, 1..) |Stage, index| {
        if (isTuple(Stage))
            @compileError(std.fmt.comptimePrint("pipe: stage {d} is a nested tuple; use a flat tuple or a named helper operator", .{index}));
        if (@typeInfo(Stage) != .@"struct" or !@hasDecl(Stage, "Output") or !@hasDecl(Stage, "apply"))
            invalidStage(index);
        const output = switch (@typeInfo(@TypeOf(Stage.Output))) {
            .@"fn" => |info| info,
            else => invalidStage(index),
        };
        const apply = switch (@typeInfo(@TypeOf(Stage.apply))) {
            .@"fn" => |info| info,
            else => invalidStage(index),
        };
        if (output.param_types.len != 1 or output.param_types[0] != type or output.return_type != type or
            output.attrs.varargs or apply.param_types.len != 2 or apply.param_types[0] != Stage or apply.attrs.varargs)
            invalidStage(index);
    }
    return ComposedOutput(Input, Operators, 0);
}

// Construct diagnostic strings only for invalid stages, not on the successful
// path through every nested pipeline's compile-time validation.
fn invalidStage(comptime index: usize) noreturn {
    @compileError(std.fmt.comptimePrint("pipe: stage {d} must provide Output(comptime Input: type) type and apply(self, value)", .{index}));
}

pub fn ComposedOutput(comptime Input: type, comptime Steps: type, comptime index: usize) type {
    const fields = @typeInfo(Steps).@"struct".field_types;
    const Next = fields[index].Output(Input);
    return if (index == fields.len - 1) Next else ComposedOutput(Next, Steps, index + 1);
}

pub fn compose(source: anytype, steps: anytype, comptime index: usize) ComposedOutput(@TypeOf(source), @TypeOf(steps), index) {
    const next = steps[index].apply(source);
    return if (index == steps.len - 1) next else compose(next, steps, index + 1);
}

pub fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.payload,
        else => T,
    };
}
