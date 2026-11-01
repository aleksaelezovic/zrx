//! Typed leading service parameters and operator-defined trailing data arguments.
const std = @import("std");

pub fn Info(comptime callback: anytype, comptime trailing: usize) type {
    const info = switch (@typeInfo(@TypeOf(callback))) {
        .@"fn" => |info| info,
        else => @compileError("callback must be a comptime-known function"),
    };
    if (info.is_generic or info.attrs.varargs or info.return_type == null or info.param_types.len < trailing)
        @compileError("callback must have explicitly typed runtime parameters, trailing data arguments, and an explicit return type");
    for (info.param_types) |T| if (T == null)
        @compileError("callback parameters must have explicit types");
    return struct {
        pub const Return = info.return_type.?;
        pub const Params = block: {
            var types: [info.param_types.len]type = undefined;
            for (info.param_types, 0..) |T, i| types[i] = T.?;
            break :block types;
        };
        pub const Services = Params[0 .. Params.len - trailing].*;
    };
}

pub fn validate(comptime callback: anytype, comptime inputs: []const type) void {
    const Meta = Info(callback, inputs.len);
    for (inputs, Meta.Services.len..) |Input, i|
        _ = @TypeOf(@as(Meta.Params[i], @as(Input, undefined)));
}

pub fn invoke(comptime callback: anytype, env: anytype, inputs: anytype) Info(callback, inputs.len).Return {
    const Meta = Info(callback, inputs.len);
    var args: @Tuple(&Meta.Params) = undefined;
    inline for (Meta.Services, 0..) |Service, i| args[i] = env.get(Service);
    inline for (0..inputs.len) |i| args[Meta.Services.len + i] = inputs[i];
    return @call(.auto, callback, args);
}

pub fn functions(comptime input: anytype, comptime trailing: usize) if (@typeInfo(@TypeOf(input)) == .@"struct" and @typeInfo(@TypeOf(input)).@"struct".is_tuple) @TypeOf(input) else @TypeOf(.{input}) {
    const result = if (@typeInfo(@TypeOf(input)) == .@"struct" and @typeInfo(@TypeOf(input)).@"struct".is_tuple) input else .{input};
    if (result.len == 0) @compileError("callback tuple must not be empty");
    for (result) |callback| {
        if (@typeInfo(@TypeOf(callback)) == .@"struct" and @typeInfo(@TypeOf(callback)).@"struct".is_tuple)
            @compileError("callback tuple must be flat; use a named helper");
        _ = Info(callback, trailing);
    }
    return result;
}
