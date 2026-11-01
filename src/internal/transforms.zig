//! One typed callback-composition rule for synchronous mapping and effects.
const cb = @import("callbacks.zig");
const composition = @import("composition.zig");

pub fn Output(comptime functions: anytype, comptime Input: type, comptime index: usize) type {
    cb.validate(functions[index], &.{Input});
    const Next = composition.Payload(cb.Info(functions[index], 1).Return);
    return if (index + 1 == functions.len) Next else Output(functions, Next, index + 1);
}

pub fn Errors(comptime functions: anytype) type {
    var result: type = error{};
    for (functions) |function| {
        const R = cb.Info(function, 1).Return;
        if (@typeInfo(R) == .error_union) result = result || @typeInfo(R).error_union.error_set;
    }
    return result;
}

pub fn map(comptime functions: anytype, env: anytype, value: anytype, comptime index: usize) Errors(functions)!Output(functions, @TypeOf(value), index) {
    const result = cb.invoke(functions[index], env, .{value});
    const next = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
    return if (index + 1 == functions.len) next else try map(functions, env, next, index + 1);
}

pub fn tap(comptime functions: anytype, env: anytype, value: anytype) Errors(functions)!@TypeOf(value) {
    inline for (functions) |effect| {
        const result = cb.invoke(effect, env, .{value});
        if (@typeInfo(@TypeOf(result)) == .error_union) try result;
    }
    return value;
}
