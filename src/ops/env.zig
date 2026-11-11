//! Dependency operators: change what the handlers after them can ask for.
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const Flow = core.Flow;
const lift = core.lift;

/// Makes `value` available, by its type, to every operator after this one.
/// A value of a type that is already provided shadows the earlier one.
pub fn provide(value: anytype) Provide(@TypeOf(value)) {
    return .{ .value = value };
}

fn Provide(comptime T: type) type {
    return struct {
        value: T,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "provide";

        pub fn Out(comptime _: type, comptime In: type) type {
            return In;
        }

        pub fn Provides(comptime Env: type) type {
            return di.Extend(Env, T);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                value: T,

                pub fn init(self: *@This(), op: *const Op, _: Env) !void {
                    self.value = op.value;
                }

                pub fn provide(self: *@This(), env: Env) Provides(Env) {
                    return di.extend(env, self.value);
                }

                pub fn push(_: *@This(), item: In, down: anytype) !Flow {
                    return down.push(item);
                }
            };
        }
    };
}

/// A dependency with a lifetime: `acquire(deps...)` runs once before the first
/// item and its result is provided downstream; `release(deps..., value)` runs
/// once after everything downstream has finished or failed. Pass `null` as
/// `release` when there is nothing to give back.
pub fn resource(comptime acquire: anytype, comptime release: anytype) Resource(acquire, release) {
    return .{};
}

fn Resource(comptime acquire: anytype, comptime release: anytype) type {
    const has_release = @TypeOf(release) != @TypeOf(null);
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "resource";

        fn Value(comptime Env: type) type {
            const T = di.Payload(di.Bound(name ++ " acquire", acquire, Env, &.{}).Return);
            if (T == void) @compileError("resource: acquire must return the value to provide");
            return T;
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (has_release and di.Bound(name ++ " release", release, Env, &.{Value(Env)}).Return != void)
                @compileError("resource: release must return `void`; a release cannot fail");
            return In;
        }

        pub fn Provides(comptime Env: type) type {
            return di.Extend(Env, Value(Env));
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const T = Value(Env);
            const Release = if (has_release) di.Bound(name ++ " release", release, Env, &.{T}) else void;
            return struct {
                value: T,
                release: Release,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    const acquired = di.Bound(name ++ " acquire", acquire, Env, &.{}).init(env);
                    self.value = try lift(acquired.call(.{}));
                    self.release = if (has_release) .init(env) else {};
                }

                pub fn provide(self: *@This(), env: Env) Provides(Env) {
                    return di.extend(env, self.value);
                }

                pub fn push(_: *@This(), item: In, down: anytype) !Flow {
                    return down.push(item);
                }

                pub fn deinit(self: *@This()) void {
                    if (has_release) self.release.call(.{self.value});
                }
            };
        }
    };
}
