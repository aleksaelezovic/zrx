//! Explicit resource recipes and nominal role derivation.
const composition = @import("../composition.zig");
const callbacks = @import("../callbacks.zig");
pub const RecipeTag = opaque {};

pub fn isRecipe(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "world_recipe_tag") and T.world_recipe_tag == RecipeTag;
}

pub fn Service(comptime T: type) type {
    return if (isRecipe(T)) T.Provided else T;
}

/// Cold recipe. Acquire takes (services..., configuration), returning T
/// or E!T. Release takes (services..., T), returning void. Failed acquire
/// owns its partial cleanup. Release must use non-failing, uncancelable cleanup.
/// Use null when the constructed value has no cleanup of its own (for example,
/// derived configuration borrowing another binding). Dependencies still outlive
/// all users; null does not infer destruction or close any referents.
pub fn resource(config: anytype, comptime acquire_fn: anytype, comptime release_fn: anytype) Recipe(@TypeOf(config), acquire_fn, release_fn) {
    return .{ .config = config };
}

fn Recipe(comptime Config: type, comptime acquire_fn: anytype, comptime release_fn: anytype) type {
    const Acquire = callbacks.Info(acquire_fn, 1);
    const has_release = @TypeOf(release_fn) != @TypeOf(null);
    const Release = if (has_release) callbacks.Info(release_fn, 1) else struct {
        pub const Services: [0]type = .{};
    };
    callbacks.validate(acquire_fn, &.{Config});
    const T = composition.Payload(Acquire.Return);
    if (T == void or @typeInfo(T) == .error_set)
        @compileError("world resource: acquire must provide a service value");
    if (has_release) {
        if (Release.Params[Release.Params.len - 1] != T or Release.Return != void)
            @compileError("world resource: release must accept the provided type and return void");
    }
    return struct {
        pub const world_recipe_tag = RecipeTag;
        pub const Provided = T;
        pub const AcquireServices = Acquire.Services;
        pub const ReleaseServices = Release.Services;
        config: Config,

        pub fn acquire(self: @This(), env: anytype) anyerror!T {
            const result = callbacks.invoke(acquire_fn, env, .{self.config});
            return if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
        }

        pub fn release(_: @This(), env: anytype, value: T) void {
            if (comptime has_release) callbacks.invoke(release_fn, env, .{value});
        }
    };
}

/// Derive lifecycle delegation for a nominal, single-field role wrapper.
/// The wrapped recipe is private to this binding, not a second global service.
/// No constructor/destructor is inferred from the field's pointer type.
pub fn deriveResource(comptime Role: type, recipe: anytype) Derived(Role, @TypeOf(recipe)) {
    return .{ .recipe = recipe };
}

fn Derived(comptime Role: type, comptime Inner: type) type {
    if (!isRecipe(Inner)) @compileError("deriveResource: expected a resource recipe");
    if (@typeInfo(Role) != .@"struct" or @typeInfo(Role).@"struct".is_tuple or
        @typeInfo(Role).@"struct".field_types.len != 1 or
        @typeInfo(Role).@"struct".field_types[0] != Inner.Provided)
        @compileError("deriveResource: role must be a single-field struct of the provided type");
    const field = @typeInfo(Role).@"struct".field_names[0];
    return struct {
        pub const world_recipe_tag = RecipeTag;
        pub const Provided = Role;
        pub const AcquireServices = Inner.AcquireServices;
        pub const ReleaseServices = Inner.ReleaseServices;
        recipe: Inner,

        pub fn acquire(self: @This(), env: anytype) anyerror!Role {
            var role: Role = undefined;
            @field(role, field) = try self.recipe.acquire(env);
            return role;
        }

        pub fn release(self: @This(), env: anytype, role: Role) void {
            self.recipe.release(env, @field(role, field));
        }
    };
}
