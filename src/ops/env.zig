//! The dependency operator: changes what the handlers after it can ask for.
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
