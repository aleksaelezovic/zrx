//! Shared typed configuration-provider plumbing for managed I/O recipes.
const recipes = @import("resources.zig");
const callbacks = @import("../callbacks.zig");
const composition = @import("../composition.zig");
const declarations = @import("../../data/declarations.zig");

pub fn Configured(comptime Config: type, comptime config: anytype, comptime acquire_fn: anytype, comptime release_fn: anytype) type {
    const Base = @TypeOf(recipes.resource(@as(Config, undefined), acquire_fn, release_fn));
    if (@typeInfo(@TypeOf(config)) != .@"fn") return Base;
    const Meta = callbacks.Info(config, 0);
    if (composition.Payload(Meta.Return) != Config)
        @compileError("I/O configuration provider must return " ++ @typeName(Config) ++ " or E!" ++ @typeName(Config));
    return struct {
        pub const world_recipe_tag = recipes.RecipeTag;
        pub const Provided = Base.Provided;
        pub const AcquireServices = declarations.concat(&Base.AcquireServices, &Meta.Services);
        pub const ReleaseServices = Base.ReleaseServices;

        pub fn acquire(_: @This(), env: anytype) anyerror!Provided {
            const selected = callbacks.invoke(config, env, .{});
            const value = if (@typeInfo(Meta.Return) == .error_union) try selected else selected;
            return recipes.resource(value, acquire_fn, release_fn).acquire(env);
        }
        pub fn release(_: @This(), env: anytype, value: Provided) void {
            callbacks.invoke(release_fn, env, .{value});
        }
    };
}

pub fn configured(comptime Config: type, config: anytype, comptime acquire: anytype, comptime release: anytype) Configured(Config, if (@typeInfo(@TypeOf(config)) == .@"fn") config else {}, acquire, release) {
    if (comptime @typeInfo(@TypeOf(config)) == .@"fn") return .{};
    if (comptime @typeInfo(@TypeOf(config)) == .pointer and @typeInfo(@typeInfo(@TypeOf(config)).pointer.child) == .@"fn")
        @compileError("I/O configuration provider must be a comptime-known function, not a function pointer");
    return recipes.resource(configuration(Config, config), acquire, release);
}

// Restore the destination type of anonymous configuration/union literals.
fn configuration(comptime Config: type, value: anytype) Config {
    const T = @TypeOf(value);
    if (T == Config) return value;
    if (comptime @typeInfo(Config) == .@"union" and @typeInfo(T) == .@"struct") {
        const fields = @typeInfo(T).@"struct".field_names;
        if (fields.len != 1 or !@hasField(Config, fields[0]))
            @compileError("I/O resource: expected configuration or a comptime-known configuration provider");
        return @unionInit(Config, fields[0], configuration(@FieldType(Config, fields[0]), @field(value, fields[0])));
    }
    if (comptime @typeInfo(Config) == .@"struct" and @typeInfo(T) == .@"struct") {
        const info = @typeInfo(Config).@"struct";
        inline for (@typeInfo(T).@"struct".field_names) |name| {
            if (!@hasField(Config, name)) @compileError("I/O configuration: unknown field " ++ name);
        }
        var result: Config = undefined;
        inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
            @field(result, name) = if (@hasField(T, name))
                configuration(Field, @field(value, name))
            else if (attrs.defaultValue(Field)) |default|
                default
            else
                @compileError("I/O configuration: missing field " ++ name);
        }
        return result;
    }
    return value;
}
