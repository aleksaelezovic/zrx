//! Terminal operators: where a pipe ends.
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const transform = @import("transform.zig");
const Flow = core.Flow;
const End = core.End;
const lift = core.lift;

/// Ends the pipe by running `handler(deps..., item)` for every item.
pub fn subscribe(comptime handler: anytype) Subscribe(handler) {
    return .{};
}

fn Subscribe(comptime handler: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "subscribe";

        pub fn Out(comptime Env: type, comptime In: type) type {
            transform.expectReturn(name, "handler", di.Bound(name, handler, Env, &.{In}).Return, void);
            return End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, handler, Env, &.{In});
            return struct {
                call: Call,

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    self.call = .init(env);
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    try lift(self.call.call(.{item}));
                    return .more;
                }
            };
        }
    };
}

/// Ends the pipe by discarding every item.
pub fn drain() Drain {
    return .{};
}

const Drain = struct {
    pub const zrx_operator = {};
    pub const name = "drain";

    pub fn Out(comptime _: type, comptime _: type) type {
        return End;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const Drain, _: Env) !void {}

            pub fn push(_: *@This(), _: In, _: anytype) !Flow {
                return .more;
            }
        };
    }
};
